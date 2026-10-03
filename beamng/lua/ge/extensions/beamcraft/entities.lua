-- Minecraft entities near Steve, drawn in BeamNG: dropped items (spinning mini
-- blocks or flat icons), falling sand / primed TNT (full blocks), xp orbs, and
-- placeholder boxes for mobs. Minecraft sends a snapshot every tick; we interpolate.

local coords = require('beamcraft/coords')
local mu = require('beamcraft/meshutil')

local M = {}

local ents = {}      -- id -> { obj, key, kind, prev={x,y,z}, cur={x,y,z}, at, seen, w, h, label }
local stamp = 0
local pi = math.pi

-- msg.l = { {id, kind, x, y, z, yaw, w, h, extra}, ... }
function M.snapshot(msg, now, ctx)
  stamp = stamp + 1
  for _, e in ipairs(msg.l or {}) do
    local id, kind = e[1], e[2]
    local ent = ents[id]
    local key = kind .. ':' .. tostring(e[9])
    if ent and ent.key ~= key then
      mu.deleteObject(ent.obj)
      ent = nil
    end
    if not ent then
      ent = { kind = kind, key = key, extra = e[9], cur = { e[3], e[4], e[5] } }
      ents[id] = ent
      ent.obj = M.makeObject(kind, e[9], ctx)
    end
    if not ent.obj then ent.obj = M.makeObject(kind, e[9], ctx) end
    ent.prev = ent.cur
    ent.cur = { e[3], e[4], e[5] }
    ent.yaw = e[6]
    ent.w, ent.h = e[7], e[8]
    ent.at = now
    ent.seen = stamp
  end
  for id, ent in pairs(ents) do
    if ent.seen ~= stamp then
      mu.deleteObject(ent.obj)
      ents[id] = nil
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
    local id = 'minecraft:experience_bottle'
    local m = mu.newMesh(mu.textureMaterial('bc_icon_' .. id:gsub('[^%w]', '_'), ctx.iconPath(id), 'cutout'))
    mu.addFlatQuad(m, 0.25)
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
local function boxLines(x0, y0, z0, x1, y1, z1, color)
  local c = {
    vec3(x0, y0, z0), vec3(x1, y0, z0), vec3(x1, y1, z0), vec3(x0, y1, z0),
    vec3(x0, y0, z1), vec3(x1, y0, z1), vec3(x1, y1, z1), vec3(x0, y1, z1),
  }
  for _, e in ipairs(EDGES) do debugDrawer:drawLine(c[e[1]], c[e[2]], color) end
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
    if ent.obj then
      if ent.kind == 'i' or ent.kind == 'x' then
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
  for id, ent in pairs(ents) do mu.deleteObject(ent.obj) end
  ents = {}
end

return M
