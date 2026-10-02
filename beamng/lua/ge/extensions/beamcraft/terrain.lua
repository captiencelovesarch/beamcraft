-- Feeds BeamNG's world shape to Minecraft's physics.
--
-- Minecraft's world is empty air; Steve stands on BeamNG's terrain because we
-- raycast a grid of columns around him and send each column's surface height. The
-- Fabric mod turns every column into a collision box. Columns are cached, and only
-- resampled when Steve's height has changed enough that what is "the floor under
-- me" might be different (under/over a bridge, up a ramp).

local coords = require('beamcraft/coords')

local M = {}

M.res = 0.5           -- column size in metres
M.radius = 5.0        -- sample this far around Steve
M.above = 2.0         -- rays start this far above Steve's feet ...
M.reach = 80.0        -- ... and look this far down
M.resampleDelta = 0.75
M.maxRaysPerFrame = 600

local NONE = -100000  -- sentinel: nothing under this column

local cache = {}      -- [key] = { h = mcY or NONE, at = feetY when sampled }
local outBatch = {}
M.raysLastFrame = 0

local floor = math.floor
local down = vec3(0, 0, -1)
local origin = vec3()

local function colKey(i, k) return (i + 1048576) * 2097152 + (k + 1048576) end

function M.reset() cache = {} end

-- forget columns over a changed block so a removed block can't leave ghost collision
function M.invalidateBlock(x, y, z)
  local r = M.res
  for i = floor(x / r) - 1, floor((x + 1) / r) do
    for k = floor(z / r) - 1, floor((z + 1) / r) do
      cache[colKey(i, k)] = nil
    end
  end
end

function M.invalidateAll()
  for key, c in pairs(cache) do c.at = -1e9 end
end

-- feetX/Y/Z in Minecraft coordinates. Returns a message table or nil.
function M.update(feetX, feetY, feetZ)
  local r = M.res
  local rad = M.radius
  local ci, ck = floor(feetX / r), floor(feetZ / r)
  local n = math.ceil(rad / r)
  local rays = 0
  local out = outBatch
  local cnt = 0
  table.clear(out)

  for di = -n, n do
    for dk = -n, n do
      if (di * di + dk * dk) * r * r <= rad * rad then
        local i, k = ci + di, ck + dk
        local key = colKey(i, k)
        local c = cache[key]
        if not c or math.abs(c.at - feetY) > M.resampleDelta then
          if rays >= M.maxRaysPerFrame then goto continue end
          rays = rays + 1
          local cx, cz = (i + 0.5) * r, (k + 0.5) * r
          local bx, by = cx, -cz
          local startZ = feetY + M.above
          origin:set(bx, by, startZ)
          local d = castRayStatic(origin, down, M.reach)
          local h = NONE
          if d and d < M.reach then h = startZ - d end
          if not c then c = {} cache[key] = c end
          c.h, c.at = h, feetY
          out[cnt + 1], out[cnt + 2], out[cnt + 3] = i, k, h
          cnt = cnt + 3
        end
      end
      ::continue::
    end
  end
  M.raysLastFrame = rays
  if cnt == 0 then return nil end
  local list = {}
  for j = 1, cnt do list[j] = out[j] end
  return { t = 'ter', r = r, c = list }
end

-- Where the crosshair meets BeamNG's world (MC coords), for placing blocks on the
-- ground. eyeB = BeamNG eye position, dirB = BeamNG unit look direction.
function M.aim(eyeB, dirB, maxDist)
  local d = castRayStatic(eyeB, dirB, maxDist)
  if not d or d >= maxDist then return nil end
  local hit = eyeB + dirB * d
  -- estimate the surface normal with two extra rays nudged sideways
  local side = dirB:cross(vec3(0, 0, 1))
  if side:squaredLength() < 1e-6 then side = vec3(1, 0, 0) end
  side:normalize()
  local up2 = side:cross(dirB)
  local e = 0.05
  local d1 = castRayStatic(eyeB + side * e, dirB, maxDist + 1)
  local d2 = castRayStatic(eyeB + up2 * e, dirB, maxDist + 1)
  local nx, ny, nz = 0, 0, 1
  if d1 and d2 and d1 < maxDist + 1 and d2 < maxDist + 1 then
    local p1 = eyeB + side * e + dirB * d1
    local p2 = eyeB + up2 * e + dirB * d2
    local nrm = (p1 - hit):cross(p2 - hit)
    if nrm:squaredLength() > 1e-12 then
      nrm:normalize()
      if nrm:dot(dirB) > 0 then nrm = nrm * -1 end
      nx, ny, nz = nrm.x, nrm.y, nrm.z
    end
  end
  local mx, my, mz = coords.bngToMc(hit.x, hit.y, hit.z)
  local mnx, mny, mnz = coords.bngToMc(nx, ny, nz)
  return { x = mx, y = my, z = mz, nx = mnx, ny = mny, nz = mnz, d = d }
end

return M
