-- The block world as BeamNG sees it.
--
-- Minecraft owns the blocks. It streams block changes plus, once per block state,
-- that state's baked model (quads with UVs into atlas pages it has written to the
-- userfolder). We keep every block we have been told about, mesh each 16^3 section
-- into a ProceduralMesh, and rebuild static collision so vehicles hit what you build.

local coords = require('beamcraft/coords')
local mu = require('beamcraft/meshutil')

local M = {}

-- tunables
M.rebuildBudgetMs = 4         -- max milliseconds of meshing per frame
M.collisionDelay = 0.15       -- coalesce collision rebuilds (seconds)
M.minRebuildInterval = 0.35    -- never rebuild more often than this, unless forced
-- Static collision acceleration must be rebuilt after mesh changes. Coalesce it
-- with a bounded delay; per-object disabling prevents obsolete shapes from being hit.
M.flipWinding = true          -- MC quads are CCW-from-outside; Torque wants CW
M.lastCollisionMs = nil       -- measured cost of the latest reloadCollision
M.collisionReloads = 0

-- state
local states = {}             -- [stateId] = { opaque=bool, collide=bool, ground=str, quads={...} }
local sections = {}           -- [sectionKey] = { blocks = {[localIdx]=stateId}, count=n, objs = {}, dirty=bool }
local dirtyQueue = {}         -- array of section keys to rebuild
local dirtySet = {}
local collisionPending = false
local collisionTimer = 0
local sinceRebuild = 1e9
local dirtyCentres = {}       -- BeamNG positions of sections changed since the last rebuild
local atlas                   -- { dir=, hash=, pages= }
local materialsReady = false
local objCounter = 0
local totalBlocks = 0

M.getTotalBlocks = function() return totalBlocks end
M.getSectionCount = function() local n = 0 for _ in pairs(sections) do n = n + 1 end return n end
M.getDirtyCount = function() return #dirtyQueue end
M.getStateCount = function() local n = 0 for _ in pairs(states) do n = n + 1 end return n end

-- MC Direction ordinal -> neighbour offset (DOWN, UP, NORTH, SOUTH, WEST, EAST)
local DIR = {
  [0] = { 0, -1, 0 }, [1] = { 0, 1, 0 }, [2] = { 0, 0, -1 },
  [3] = { 0, 0, 1 },  [4] = { -1, 0, 0 }, [5] = { 1, 0, 0 },
}
local LAYER_NAMES = { [0] = 'solid', [1] = 'cutout', [2] = 'translucent' }

local floor = math.floor

local function localIndex(lx, ly, lz) return (ly * 16 + lz) * 16 + lx end

local function markDirty(key)
  if not dirtySet[key] then
    dirtySet[key] = true
    dirtyQueue[#dirtyQueue + 1] = key
  end
end

-- block lookup across sections (for face culling)
local function getState(x, y, z)
  local sx, sy, sz = floor(x / 16), floor(y / 16), floor(z / 16)
  local sec = sections[coords.sectionKey(sx, sy, sz)]
  if not sec then return 0 end
  return sec.blocks[localIndex(x - sx * 16, y - sy * 16, z - sz * 16)] or 0
end
M.getState = getState

------------------------------------------------------------------------------
-- materials
------------------------------------------------------------------------------

local function materialName(page, layer, ground)
  return string.format('bc_%s_p%d_%s_%s', atlas.hash, page, LAYER_NAMES[layer] or 'solid', ground or 'ROCK')
end

local KIND = { [0] = 'solid', [1] = 'cutout', [2] = 'translucent' }

local function ensureMaterial(page, layer, ground)
  local name = materialName(page, layer, ground)
  return mu.textureMaterial(name, string.format('%s/%s_%d.png', atlas.dir, atlas.hash, page), KIND[layer] or 'solid', ground)
end

local function flushMaterials() mu.flushMaterials() end

-- for held items / dropped blocks: the quads of a state and a material picker
function M.getStateQuads(id)
  local st = states[id]
  return st and st.quads or nil
end

function M.matFor(page, layer)
  if not atlas then return nil end
  return ensureMaterial(page, layer, 'ROCK')
end

function M.hasAtlas() return atlas ~= nil end

------------------------------------------------------------------------------
-- protocol handlers
------------------------------------------------------------------------------

function M.setAtlas(msg)
  local changed = not atlas or atlas.hash ~= msg.hash
  atlas = { dir = msg.dir or '/beamcraft/atlas', hash = msg.hash, pages = msg.pages }
  materialsReady = true
  if changed then
    for key in pairs(sections) do markDirty(key) end
  else
    -- same atlas re-announced (e.g. pages just got written): re-read the textures
    mu.reloadMaterials('bc_' .. atlas.hash)
  end
  log('I', 'beamcraft.world', string.format('atlas %s: %d page(s)', tostring(msg.hash), msg.pages or -1))
end

-- msg.d = array of { i=id, o=opaque, c=collides, g=groundType, q=flat quad array }
function M.defineStates(msg)
  for _, d in ipairs(msg.d or {}) do
    states[d.i] = { opaque = d.o == 1, collide = d.c == 1, ground = d.g or 'ROCK', quads = d.q or {}, boxes = d.a or {} }
  end
  -- sections waiting on these definitions can now mesh
  for key, sec in pairs(sections) do
    if sec.missing then sec.missing = nil markDirty(key) end
  end
end

-- msg.l = flat array x,y,z,id,...  (id 0 = air)
function M.setBlocks(msg)
  local l = msg.l
  if not l then return end
  for n = 1, #l, 4 do
    local x, y, z, id = l[n], l[n + 1], l[n + 2], l[n + 3]
    local sx, sy, sz = floor(x / 16), floor(y / 16), floor(z / 16)
    local key = coords.sectionKey(sx, sy, sz)
    local sec = sections[key]
    if id ~= 0 and not sec then
      sec = { blocks = {}, count = 0, objs = {}, sx = sx, sy = sy, sz = sz }
      sections[key] = sec
    end
    if sec then
      local lx, ly, lz = x - sx * 16, y - sy * 16, z - sz * 16
      local idx = localIndex(lx, ly, lz)
      local old = sec.blocks[idx]
      if id == 0 then id = nil end
      if old ~= id then
        if old and not id then sec.count = sec.count - 1 totalBlocks = totalBlocks - 1 end
        if id and not old then sec.count = sec.count + 1 totalBlocks = totalBlocks + 1 end
        -- Disable the previous collision immediately; never raycast or drive on
        -- triangles for a state which Minecraft has already removed/changed.
        if sec.objs[1] then sec.objs[1]:disableCollision() sec.disabled = true end
        sec.blocks[idx] = id
        markDirty(key)
        -- faces of neighbours across a section boundary may change visibility
        if lx == 0 then markDirty(coords.sectionKey(sx - 1, sy, sz)) end
        if lx == 15 then markDirty(coords.sectionKey(sx + 1, sy, sz)) end
        if ly == 0 then markDirty(coords.sectionKey(sx, sy - 1, sz)) end
        if ly == 15 then markDirty(coords.sectionKey(sx, sy + 1, sz)) end
        if lz == 0 then markDirty(coords.sectionKey(sx, sy, sz - 1)) end
        if lz == 15 then markDirty(coords.sectionKey(sx, sy, sz + 1)) end
        if M.onBlockChanged then M.onBlockChanged(x, y, z) end
      end
    end
  end
end

local function deleteObjs(sec)
  for _, obj in pairs(sec.objs) do
    if obj then pcall(function() obj:delete() end) end
  end
  sec.objs = {}
end

function M.hasPendingCollision() return collisionPending end

local rebuildSection
local carNearEdits

-- rebuild BeamNG's collision now if anything changed (e.g. when you get back in a car)
function M.rebuildCollisionNow()
  if materialsReady then
    while #dirtyQueue > 0 do
      local key=table.remove(dirtyQueue,1) dirtySet[key]=nil
      if sections[key] then rebuildSection(key) end
    end
  end
  if not collisionPending then return end
  collisionPending = false
  collisionTimer = 0
  sinceRebuild = 0
  dirtyCentres = {}
  for _,sec in pairs(sections) do if sec.objs[1] then sec.objs[1]:enableCollision() sec.disabled=nil end end
  local ct = hptimer()
  be:reloadCollision()
  M.lastCollisionMs = ct:stop()
  M.collisionReloads = M.collisionReloads + 1
  if M.onCollisionReloaded then M.onCollisionReloaded() end
end

function M.clear()
  for _, sec in pairs(sections) do deleteObjs(sec) end
  sections, dirtyQueue, dirtySet = {}, {}, {}
  states = {}
  totalBlocks = 0
  collisionPending = true
  collisionTimer = 0
end

------------------------------------------------------------------------------
-- meshing
------------------------------------------------------------------------------

-- Build {[group] = mesh} for one section. Groups split by collision so plants and
-- water can live in a separate object from solid geometry.
local function buildSection(sec)
  local groups = {}   -- [collideFlag] = { [matName] = {verts,uvs,normals,faces} }
  local missing = false
  local ox, oy, oz = sec.sx * 16, sec.sy * 16, sec.sz * 16
  local flip = M.flipWinding

  for idx, id in pairs(sec.blocks) do
    local st = states[id]
    if not st then
      missing = true
    elseif #st.quads > 0 then
      local lx = idx % 16
      local lz = floor(idx / 16) % 16
      local ly = floor(idx / 256)
      local wx, wy, wz = ox + lx, oy + ly, oz + lz
      local q = st.quads
      local cflag = 0 -- visual quads never supply physics geometry
      local mats = groups[cflag]
      if not mats then mats = {} groups[cflag] = mats end
      for base = 1, #q, 24 do
        local cull = q[base]
        local visible = true
        if cull >= 0 then
          local d = DIR[cull]
          local nid = getState(wx + d[1], wy + d[2], wz + d[3])
          local ns = nid ~= 0 and states[nid]
          if ns and ns.opaque then visible = false end
        end
        if visible then
          local dir, layer, page = q[base + 1], q[base + 2], q[base + 3]
          local name = ensureMaterial(page, layer, st.ground)
          local m = mats[name]
          if not m then
            m = { verts = {}, uvs = {}, normals = {}, faces = {}, material = name }
            mats[name] = m
          end
          local verts, uvs, normals, faces = m.verts, m.uvs, m.normals, m.faces
          local v0 = #verts
          for k = 0, 3 do
            local px = q[base + 4 + k * 3]
            local py = q[base + 5 + k * 3]
            local pz = q[base + 6 + k * 3]
            -- section-relative, MC -> BeamNG axes
            verts[v0 + k + 1] = { x = lx + px, y = -(lz + pz), z = ly + py }
            uvs[v0 + k + 1] = { u = q[base + 16 + k * 2], v = q[base + 17 + k * 2] }
          end
          local dv = DIR[dir] or DIR[1]
          local n0 = #normals
          normals[n0 + 1] = { x = dv[1], y = -dv[3], z = dv[2] }
          local a, b, c, e = v0, v0 + 1, v0 + 2, v0 + 3
          local f = #faces
          if flip then
            faces[f + 1] = { v = a, n = n0, u = a }
            faces[f + 2] = { v = c, n = n0, u = c }
            faces[f + 3] = { v = b, n = n0, u = b }
            faces[f + 4] = { v = a, n = n0, u = a }
            faces[f + 5] = { v = e, n = n0, u = e }
            faces[f + 6] = { v = c, n = n0, u = c }
          else
            faces[f + 1] = { v = a, n = n0, u = a }
            faces[f + 2] = { v = b, n = n0, u = b }
            faces[f + 3] = { v = c, n = n0, u = c }
            faces[f + 4] = { v = a, n = n0, u = a }
            faces[f + 5] = { v = c, n = n0, u = c }
            faces[f + 6] = { v = e, n = n0, u = e }
          end
        end
      end
    end
  end
  -- Collision uses Minecraft VoxelShapes, including open doors, stairs, slabs
  -- and fences. Rendering quads can be decorative and are not collision boxes.
  local collision = {} groups[1] = collision
  for idx,id in pairs(sec.blocks) do
    local st=states[id]
    if st then
      local lx,lz,ly=idx%16,floor(idx/16)%16,floor(idx/256)
      for _,a in ipairs(st.boxes) do
        local mat=mu.material('bc_collision_'..st.ground, {
          Stages={{baseColorFactor={1,1,1,0},opacityFactor=0,roughnessFactor=1},{},{},{}},
          translucent=true,translucentBlendOp='LerpAlpha',translucentZWrite=false,castShadows=false,groundType=st.ground,
        })
        local m=collision[mat] if not m then m=mu.newMesh(mat) collision[mat]=m end
        mu.addUvBox(m,lx+a[1],-(lz+a[6]),ly+a[2],lx+a[4],-(lz+a[3]),ly+a[5],0,0,1,1,1,4,4)
      end
    end
  end
  return groups, missing
end

rebuildSection = function(key)
  local sec = sections[key]
  if not sec then return false end
  if sec.count <= 0 then
    deleteObjs(sec)
    sections[key] = nil
    collisionPending = true
    local bx, by, bz = coords.mcToBng(sec.sx * 16 + 8, sec.sy * 16 + 8, sec.sz * 16 + 8)
    dirtyCentres[#dirtyCentres + 1] = vec3(bx, by, bz)
    return true
  end
  if not atlas then return false end

  local groups, missing = buildSection(sec)
  sec.missing = missing or nil
  flushMaterials()

  local ox, oy, oz = sec.sx * 16, sec.sy * 16, sec.sz * 16
  local bx, by, bz = coords.mcToBng(ox, oy, oz)
  for cflag = 0, 1 do
    local mats = groups[cflag]
    local list = {}
    if mats then for _, m in pairs(mats) do list[#list + 1] = m end end
    local obj = sec.objs[cflag]
    if #list == 0 then
      if obj then pcall(function() obj:delete() end) sec.objs[cflag] = nil end
    else
      if not obj then
        objCounter = objCounter + 1
        obj = createObject('ProceduralMesh')
        obj:setPosition(vec3(bx, by, bz))
        obj.canSave = false
        obj:registerObject(string.format('beamcraft_s%d_%d', objCounter, cflag))
        scenetree.MissionGroup:add(obj.obj)
        sec.objs[cflag] = obj
      end
      obj:createMesh({ list })
      if cflag == 0 then obj:enableCollision() end
      if cflag == 1 then sec.disabled=true end
    end
  end
  collisionPending = true
  dirtyCentres[#dirtyCentres + 1] = vec3(bx + 8, by - 8, bz + 8)
  return true
end

-- a moving car close to something built since the last collision rebuild
M.carCheckRadius = 40
carNearEdits = function()
  if #dirtyCentres == 0 then return false end
  for _, veh in ipairs(getAllVehicles()) do
    if veh:getJBeamFilename() ~= 'unicycle' and veh:getVelocity():length() > 1 then
      local p = veh:getPosition()
      for _, c in ipairs(dirtyCentres) do
        if (p - c):length() < M.carCheckRadius + 12 then return true end
      end
    end
  end
  return false
end

function M.update(dt)
  if not materialsReady then
    if collisionPending then M.rebuildCollisionNow() end
    return
  end
  local t = hptimer()
  local budget = M.rebuildBudgetMs
  while #dirtyQueue > 0 do
    local key = table.remove(dirtyQueue, 1)
    dirtySet[key] = nil
    if sections[key] then rebuildSection(key) end
    if t:stop() > budget then break end
  end

  sinceRebuild = sinceRebuild + dt
  if collisionPending then
    collisionTimer = collisionTimer + dt
    -- A rebuild freezes the game for ~0.3 s and only cars care about it: building
    -- with nobody driving around stays smooth. Getting into a car rebuilds anyway.
    if collisionTimer >= M.collisionDelay and #dirtyQueue == 0 and sinceRebuild >= M.minRebuildInterval
        and carNearEdits() then
      M.rebuildCollisionNow()
    end
  end
end

-- Terrain belongs to BeamNG alone; sampling MC blocks into the terrain columns
-- duplicates their collision in Minecraft, leaving phantom floors after removal.
function M.withoutCollision(fn)
  local enabled={}
  for _,sec in pairs(sections) do
    if sec.objs[1] and not sec.disabled then sec.objs[1]:disableCollision() enabled[#enabled+1]=sec.objs[1] end
  end
  local ok,result=pcall(fn)
  for _,obj in ipairs(enabled) do obj:enableCollision() end
  if not ok then error(result) end
  return result
end

function M.obstacleDistance(veh,reach)
  local bb=veh:getSpawnWorldOOBB() local c=bb:getCenter() local he=bb:getHalfExtents()
  local forward=veh:getDirectionVector() forward.z=0 forward:normalize()
  local velocity=veh:getVelocity() velocity.z=0
  if velocity:length()>1 and velocity:dot(forward)<0 then forward=-forward end
  local side=vec3(-forward.y,forward.x,0)
  local front=math.abs(bb:getAxis(0):dot(forward))*he.x+math.abs(bb:getAxis(1):dot(forward))*he.y
  local width=math.abs(bb:getAxis(0):dot(side))*he.x+math.abs(bb:getAxis(1):dot(side))*he.y+0.2
  local bottom=c.z-he.z local top=c.z+he.z local nearest
  for _,sec in pairs(sections) do
    local sx,sy,sz=coords.mcToBng(sec.sx*16+8,sec.sy*16+8,sec.sz*16+8)
    if (vec3(sx,sy,sz)-c):length()<reach+30 then
      for idx,id in pairs(sec.blocks) do
        local st=states[id]
        if st then
          local x=sec.sx*16+idx%16 local z=sec.sy*16+floor(idx/256) local y=-(sec.sz*16+floor(idx/16)%16)
          for _,a in ipairs(st.boxes) do
            local low,high=z+a[2],z+a[5]
            if high>bottom+0.3 and low<top then
              local center=vec3(x+(a[1]+a[4])/2,y-(a[3]+a[6])/2,(low+high)/2)-c
              local hx,hy=(a[4]-a[1])/2,(a[6]-a[3])/2
              local lateral=math.abs(center:dot(side))-(math.abs(side.x)*hx+math.abs(side.y)*hy)
              local longitudinal=center:dot(forward)-(math.abs(forward.x)*hx+math.abs(forward.y)*hy)-front
              if lateral<width and longitudinal>=-0.5 and longitudinal<reach then nearest=math.min(nearest or reach,math.max(0,longitudinal)) end
            end
          end
        end
      end
    end
  end
  return nearest
end

return M
