-- Minecraft entities near Steve, drawn in BeamNG: dropped items (spinning mini
-- blocks or flat icons), falling sand / primed TNT (full blocks), xp orbs, and mobs.
-- Minecraft sends a snapshot every tick; we interpolate.
--
-- Mobs are their real Minecraft models: the hidden client sends each model's geometry
-- once ('mobModel': per part, quads in part-local blocks) and then, per mob and tick,
-- every visible part's transform relative to the mob's feet, straight out of vanilla's
-- renderer (setupAnim, setupRotations, scale). One ProceduralMesh per part.

local coords = require('beamcraft/coords')
local mu = require('beamcraft/meshutil')

local M = {}

local ents = {}      -- id -> { obj, key, kind, prev={x,y,z}, cur={x,y,z}, at, seen, w, h, label }
local stamp = 0
local pi = math.pi
local HIDE = -100000
M.showOwn = false
local models = {}    -- model key -> { parts = { quads... } }

-- geometry of one Minecraft entity model (sent once per model)
function M.defineModel(msg)
  models[msg.k] = { parts = msg.parts }
end
function M.forgetModels() models = {} end

-- MC (x, y, z) -> BeamNG (x, -z, y), for vertices, normals and quaternion axes
local function partMesh(quads, material)
  local m = mu.newMesh(material)
  local verts, uvs, normals, faces = m.verts, m.uvs, m.normals, m.faces
  for base = 1, #quads, 23 do
    local b = #verts
    for k = 0, 3 do
      local o = base + k * 5
      verts[b + k + 1] = { x = quads[o], y = -quads[o + 2], z = quads[o + 1] }
      uvs[b + k + 1] = { u = quads[o + 3], v = quads[o + 4] }
    end
    local n = #normals
    normals[n + 1] = { x = quads[base + 20], y = -quads[base + 22], z = quads[base + 21] }
    local f = #faces
    faces[f + 1] = { v = b, n = n, u = b }
    faces[f + 2] = { v = b + 2, n = n, u = b + 2 }
    faces[f + 3] = { v = b + 1, n = n, u = b + 1 }
    faces[f + 4] = { v = b, n = n, u = b }
    faces[f + 5] = { v = b + 3, n = n, u = b + 3 }
    faces[f + 6] = { v = b + 2, n = n, u = b + 2 }
  end
  return m
end

-- Part objects of mobs that died or changed layers wait here for the next mob of the
-- same look: making one costs ~0.7 ms (a zombie in armour is 20+ objects), so fights
-- that spawn and kill mobs constantly used to hitch on every spawn.
local spare = {}       -- layer key -> { { parts = {...}, at = time }, ... }
local SPARE_MAX = 6    -- kept per look
local SPARE_TTL = 60   -- seconds an unused set is kept
-- new part objects per frame; mobs over budget appear a tick or two later
M.createBudgetMs = 3.0
local frameNow, createdMs = -1, 0
local createTimer = hptimer()

local function hideParts(parts)
  for _, o in pairs(parts) do mu.setXform(o, 0, 0, HIDE, mu.IDENTITY) end
end
local function setParked(parts, parked)
  for _, o in pairs(parts) do if parked then mu.park(o) else mu.unpark(o) end end
end

local function releaseLayer(layer, now)
  if not layer.lkey or not layer.parts then return end
  hideParts(layer.parts)
  local list = spare[layer.lkey]
  if not list then list = {} spare[layer.lkey] = list end
  if #list >= SPARE_MAX then
    for _, o in pairs(layer.parts) do mu.deleteObject(o) end
  else
    setParked(layer.parts, true)
    list[#list + 1] = { parts = layer.parts, at = now or 0 }
  end
  layer.parts = nil
end

local function trimSpare(now)
  for key, list in pairs(spare) do
    for i = #list, 1, -1 do
      if now - list[i].at > SPARE_TTL then
        for _, o in pairs(list[i].parts) do mu.deleteObject(o) end
        table.remove(list, i)
      end
    end
    if #list == 0 then spare[key] = nil end
  end
end

local function layerKey(info) return info.k .. '|' .. info.tx end

-- one model layer (body, wool, armour...) -> { [partIndex] = ProceduralMesh }, or nil
-- (no geometry yet, or over this frame's budget)
local function layerObjects(info, now)
  local list = spare[layerKey(info)]
  if list and #list > 0 then
    local parts = table.remove(list).parts
    setParked(parts, false)
    return parts
  end
  local model = models[info.k]
  if not model then return nil end
  if frameNow ~= now then frameNow, createdMs = now, 0 end
  if createdMs >= M.createBudgetMs then return nil end
  local t0 = createTimer:stop()
  local mat = mu.textureMaterial('bc_mob_' .. info.tx:gsub('[^%w]', '_'), info.tx, 'cutout', nil, info.mk, true)
  mu.flushMaterials()
  local parts = {}
  for i, quads in ipairs(model.parts) do
    if #quads > 0 then
      local o = mu.newObject('beamcraft_mob', { partMesh(quads, mat) })
      mu.setXform(o, 0, 0, HIDE, mu.IDENTITY)
      parts[i - 1] = o
    end
  end
  createdMs = createdMs + (createTimer:stop() - t0)
  return parts
end

-- pose list -> { [partIndex] = { tx,ty,tz, qx,qy,qz,qw, s } }
local function parsePose(p)
  local out = {}
  for i = 1, #(p or {}), 9 do
    out[p[i]] = { p[i + 1], p[i + 2], p[i + 3], p[i + 4], p[i + 5], p[i + 6], p[i + 7], p[i + 8] }
  end
  return out
end

-- msg.l = { {id, kind, x, y, z, yaw, w, h, extra}, ... }
function M.snapshot(msg, now, ctx)
  stamp = stamp + 1
  for _, e in ipairs(msg.l or {}) do
    local id, kind = e[1], e[2]
    local ent = ents[id]
    -- 'w' = what Steve wears (elytra), shown only while his body is (M.showOwn)
    local mob = (kind == 'm' or kind == 'w') and type(e[9]) == 'table' and e[9].L or nil
    local orb = kind == 'x' and type(e[9]) == 'table' and e[9] or nil
    local key
    if mob then
      local ks = {}
      for i, l in ipairs(mob) do ks[i] = l.k .. ':' .. l.tx end
      key = 'm:' .. table.concat(ks, '|')
    elseif orb then
      key = 'x:' .. orb.i
    else
      key = kind .. ':' .. tostring(e[9])
    end
    if ent and ent.key ~= key then
      if mob and ent.layers then
        -- same mob, layers changed (armour on/off, wither armour, sheared...): keep
        -- the layers that are still there
        ent.key = key
      else
        M.deleteEnt(ent, now)
        ent = nil
      end
    end
    if not ent then
      ent = { kind = kind, key = key, extra = e[9], cur = { e[3], e[4], e[5] } }
      ents[id] = ent
    end
    if mob then
      local old = ent.layers or {}
      local layers = {}
      for i, l in ipairs(mob) do
        local lk = layerKey(l)
        local layer
        for j, o in pairs(old) do
          if o.lkey == lk then layer = o old[j] = nil break end
        end
        if not layer then layer = { lkey = lk } end
        if not layer.parts then layer.parts = layerObjects(l, now) end
        layer.prev = layer.parts and layer.pose or nil
        layer.pose = parsePose(l.p)
        layers[i] = layer
      end
      for _, o in pairs(old) do releaseLayer(o, now) end
      ent.layers = layers
    elseif not ent.obj then
      ent.obj = M.makeObject(kind, e[9], ctx)
    end
    ent.prev = ent.cur
    ent.cur = { e[3], e[4], e[5] }
    ent.yaw = e[6]
    ent.w, ent.h = e[7], e[8]
    ent.at = now
    ent.seen = stamp
  end
  for id, ent in pairs(ents) do
    if ent.seen ~= stamp then
      M.deleteEnt(ent, now)
      ents[id] = nil
    end
  end
  trimSpare(now)
end

-- now = keep mob parts for reuse; nil = really delete them (clear)
function M.deleteEnt(ent, now)
  mu.deleteObject(ent.obj)
  for _, layer in pairs(ent.layers or {}) do
    if now then releaseLayer(layer, now)
    elseif layer.parts then
      for _, o in pairs(layer.parts) do mu.deleteObject(o) end
    end
  end
  ent.obj, ent.layers = nil, nil
end

local function placeParts(layer, a, x, y, z)
  if not layer.parts then return end
  local pose, prev = layer.pose or {}, layer.prev or layer.pose or {}
  for idx, obj in pairs(layer.parts) do
    local c = pose[idx]
    if not c then
      mu.setXform(obj, 0, 0, HIDE, mu.IDENTITY)
    else
      local p = prev[idx] or c
      local tx, ty, tz = p[1] + (c[1] - p[1]) * a, p[2] + (c[2] - p[2]) * a, p[3] + (c[3] - p[3]) * a
      -- nlerp, shortest way round
      local dot = p[4] * c[4] + p[5] * c[5] + p[6] * c[6] + p[7] * c[7]
      local sg = dot < 0 and -1 or 1
      local qx, qy, qz, qw = p[4] * sg + (c[4] - p[4] * sg) * a, p[5] * sg + (c[5] - p[5] * sg) * a,
        p[6] * sg + (c[6] - p[6] * sg) * a, p[7] * sg + (c[7] - p[7] * sg) * a
      local len = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
      if len < 1e-6 then qx, qy, qz, qw, len = 0, 0, 0, 1, 1 end
      local s = p[8] + (c[8] - p[8]) * a
      local bx, by, bz = coords.mcToBng(x + tx, y + ty, z + tz)
      mu.setXform(obj, bx, by, bz, { qx / len, -qz / len, qy / len, qw / len })
      obj:setScale(vec3(s, s, s))
    end
  end
end

function M.makeObject(kind, extra, ctx)
  local meshes
  if kind == 'b' and ctx.world.getStateQuads(extra) then
    meshes = mu.blockMeshes(ctx.world.getStateQuads(extra), 1.0, ctx.world.matFor)
  elseif kind == 'i' then
    return extra and ctx.items.object(extra, 'beamcraft_ent_item') or nil
  elseif kind == 'x' then
    -- the orb sprite: icon i of the 4x4 grid on experience_orb.png
    if type(extra) ~= 'table' then return nil end
    local m = mu.newMesh(mu.textureMaterial('bc_xporb', extra.tx, 'cutout', nil, extra.mk, true))
    local u0, v0 = (extra.i % 4) / 4, math.floor(extra.i / 4) / 4
    local h = 0.15
    mu.addQuad(m, { -h, 0, h }, { h, 0, h }, { h, 0, -h }, { -h, 0, -h }, u0, v0, u0 + 0.25, v0 + 0.25, 0, -1, 0)
    meshes = { m }
  else
    return nil -- mobs: debug-drawn boxes for now
  end
  mu.flushMaterials()
  return mu.newObject('beamcraft_ent', meshes)
end

local white = ColorF(1, 1, 1, 0.8)
local red = ColorF(0.9, 0.3, 0.2, 0.8)

local EDGES = { {1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8} }
-- depthTest: hide the lines behind geometry (the block outline); debug boxes leave it off
local function boxLines(x0, y0, z0, x1, y1, z1, color, depthTest)
  local c = {
    vec3(x0, y0, z0), vec3(x1, y0, z0), vec3(x1, y1, z0), vec3(x0, y1, z0),
    vec3(x0, y0, z1), vec3(x1, y0, z1), vec3(x1, y1, z1), vec3(x0, y1, z1),
  }
  for _, e in ipairs(EDGES) do debugDrawer:drawLine(c[e[1]], c[e[2]], color, depthTest == true) end
end
M.boxLines = boxLines

function M.update(now, camPos)
  for id, ent in pairs(ents) do
    local a = math.min(1, (now - (ent.at or now)) / 0.05)
    local p, c = ent.prev or ent.cur, ent.cur
    local x = p[1] + (c[1] - p[1]) * a
    local y = p[2] + (c[2] - p[2]) * a
    local z = p[3] + (c[3] - p[3]) * a
    local bx, by, bz = coords.mcToBng(x, y, z)
    if ent.layers then
      local show = ent.kind ~= 'w' or M.showOwn
      for _, layer in ipairs(ent.layers) do
        if show then placeParts(layer, a, x, y, z)
        elseif layer.parts then hideParts(layer.parts) end
      end
    elseif ent.obj then
      if ent.kind == 'x' then
        -- vanilla orbs always face the camera
        local cam = getCameraPosition()
        local dx, dy, dz = cam.x - bx, cam.y - by, cam.z - (bz + 0.2)
        local yaw = math.atan2(dx, -dy)
        local pitch = math.atan2(dz, math.sqrt(dx * dx + dy * dy))
        mu.setXform(ent.obj, bx, by, bz + 0.2, mu.qmul(mu.qaxis(0, 0, 1, yaw), mu.qaxis(1, 0, 0, -pitch)))
      elseif ent.kind == 'i' then
        -- spin and bob like a dropped item
        local spin = (now * 1.6 + id * 0.37) % (2 * pi)
        local bob = 0.1 + math.sin(now * 2.5 + id) * 0.05
        mu.setXform(ent.obj, bx, by, bz + bob, mu.qaxis(0, 0, 1, spin))
      else
        -- full block, centred on its feet position
        mu.setXform(ent.obj, bx, by, bz + 0.5, mu.IDENTITY)
      end
    elseif ent.kind == 'm' then
      local hw, h = (ent.w or 0.6) / 2, ent.h or 1.8
      boxLines(bx - hw, by - hw, bz, bx + hw, by + hw, bz + h, red)
      debugDrawer:drawTextAdvanced(vec3(bx, by, bz + h + 0.3), String((tostring(ent.extra):gsub('^minecraft:', ''))), white, true, false, ColorI(0, 0, 0, 160))
    end
  end
end

function M.clear()
  for id, ent in pairs(ents) do M.deleteEnt(ent) end
  ents = {}
  for _, list in pairs(spare) do
    for _, set in ipairs(list) do
      for _, o in pairs(set.parts) do mu.deleteObject(o) end
    end
  end
  spare = {}
end

-- mobs (and other modelled entities) for car hits: { id, x, y, z (MC feet), w, h }
function M.mobList()
  local out = {}
  for id, ent in pairs(ents) do
    if ent.kind == 'm' then
      local c = ent.cur
      out[#out + 1] = { id = id, x = c[1], y = c[2], z = c[3], w = ent.w or 0.6, h = ent.h or 1.8 }
    end
  end
  return out
end

-- living mobs' feet (MC coords), for sampling the ground under them
function M.mobFeet()
  local out = {}
  for _, ent in pairs(ents) do
    if ent.kind == 'm' then out[#out + 1] = ent.cur end
  end
  return out
end

return M
