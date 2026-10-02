-- The block world as BeamNG sees it.
--
-- Minecraft owns the blocks. It streams block changes plus, once per block state,
-- that state's baked model (quads with UVs into atlas pages it has written to the
-- userfolder). We keep every block we have been told about, mesh each 16^3 section
-- into a ProceduralMesh, and rebuild static collision so vehicles hit what you build.

local coords = require('beamcraft/coords')

local M = {}

-- tunables
M.rebuildBudgetMs = 4         -- max milliseconds of meshing per frame
M.collisionDelay = 0.15       -- coalesce collision rebuilds (seconds)
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

local knownMaterials = {}     -- [name] = true once registered
local pendingMaterials = {}   -- [name] = definition, written in one batch per frame

local function ensureMaterial(page, layer, ground)
  local name = materialName(page, layer, ground)
  if knownMaterials[name] or pendingMaterials[name] then return name end
  local def = {
    name = name, mapTo = name, class = 'Material', version = 1.5,
    Stages = {
      { baseColorMap = string.format('%s/%s_%d.png', atlas.dir, atlas.hash, page),
        roughnessFactor = 0.92, metallicFactor = 0 },
      {}, {}, {},
    },
    groundType = ground or 'ROCK',
    materialTag0 = 'beamcraft',
    castShadows = true,
  }
  if layer == 1 then
    def.alphaTest = true
    def.alphaRef = 110
    def.doubleSided = true
  elseif layer == 2 then
    def.translucent = true
    def.translucentBlendOp = 'LerpAlpha'
    def.translucentZWrite = false
    def.doubleSided = true
  end
  pendingMaterials[name] = def
  return name
end

local function flushMaterials()
  if next(pendingMaterials) == nil then return end
  local all = {}
  for name in pairs(knownMaterials) do all[name] = knownMaterials[name] end
  for name, def in pairs(pendingMaterials) do all[name] = def end
  local path = '/beamcraft/generated/' .. atlas.hash .. '.materials.json'
  jsonWriteFile(path, all, true)
  loadJsonMaterialsFile(path)
  for name, def in pairs(pendingMaterials) do knownMaterials[name] = def end
  pendingMaterials = {}
end

------------------------------------------------------------------------------
-- protocol handlers
------------------------------------------------------------------------------

function M.setAtlas(msg)
  local changed = not atlas or atlas.hash ~= msg.hash
  atlas = { dir = msg.dir or '/beamcraft/atlas', hash = msg.hash, pages = msg.pages }
  materialsReady = true
  if changed then
    knownMaterials, pendingMaterials = {}, {}
    for key in pairs(sections) do markDirty(key) end
  else
    -- same atlas re-announced (e.g. pages just got written): re-read the textures
    for name in pairs(knownMaterials) do
      local mat = scenetree.findObject(name)
      if mat then pcall(function() mat:reload() end) end
    end
  end
  log('I', 'beamcraft.world', string.format('atlas %s: %d page(s)', tostring(msg.hash), msg.pages or -1))
end

-- msg.d = array of { i=id, o=opaque, c=collides, g=groundType, q=flat quad array }
function M.defineStates(msg)
  for _, d in ipairs(msg.d or {}) do
    states[d.i] = { opaque = d.o == 1, collide = d.c == 1, ground = d.g or 'ROCK', quads = d.q or {} }
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
      local cflag = st.collide and 1 or 0
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
  return groups, missing
end

local function rebuildSection(key)
  local sec = sections[key]
  if not sec then return false end
  if sec.count <= 0 then
    deleteObjs(sec)
    sections[key] = nil
    collisionPending = true
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
        if cflag == 0 then pcall(function() obj:setField('collisionType', 0, 'None') end) end
        scenetree.MissionGroup:add(obj.obj)
        sec.objs[cflag] = obj
      end
      obj:createMesh({ list })
    end
  end
  collisionPending = true
  return true
end

function M.update(dt)
  if not materialsReady then return end
  local t = hptimer()
  local budget = M.rebuildBudgetMs
  while #dirtyQueue > 0 do
    local key = table.remove(dirtyQueue, 1)
    dirtySet[key] = nil
    if sections[key] then rebuildSection(key) end
    if t:stop() > budget then break end
  end

  if collisionPending then
    collisionTimer = collisionTimer + dt
    if collisionTimer >= M.collisionDelay and #dirtyQueue == 0 then
      collisionPending = false
      collisionTimer = 0
      local ct = hptimer()
      be:reloadCollision()
      M.lastCollisionMs = ct:stop()
      M.collisionReloads = M.collisionReloads + 1
      if M.onCollisionReloaded then M.onCollisionReloaded() end
    end
  end
end

return M
