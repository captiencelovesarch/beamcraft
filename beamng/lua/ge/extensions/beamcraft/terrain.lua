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
M.radius = 14.0       -- sample this far around Steve (mobs need ground to path over)
M.nearRadius = 5.0    -- within this, resample on small height changes (bridges, ramps)
M.farResampleDelta = 4.0
M.above = 2.0         -- rays start this far above Steve's feet ...
M.reach = 80.0        -- ... and look this far down
M.resampleDelta = 0.75
M.maxRaysPerFrame = 192
M.sampleBudgetMs = 2.5

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
local function sample(feetX, feetY, feetZ, radius, above, reach)
  local r = M.res
  local rad = radius or M.radius
  above, reach = above or M.above, reach or M.reach
  local ci, ck = floor(feetX / r), floor(feetZ / r)
  local n = math.ceil(rad / r)
  local rays = 0
  local timer = hptimer()
  local out = outBatch
  local cnt = 0
  table.clear(out)

  for di = -n, n do
    for dk = -n, n do
      if (di * di + dk * dk) * r * r <= rad * rad then
        local i, k = ci + di, ck + dk
        local key = colKey(i, k)
        local c = cache[key]
        local delta = (di * di + dk * dk) * r * r <= M.nearRadius * M.nearRadius and M.resampleDelta or M.farResampleDelta
        if not c or math.abs(c.at - feetY) > delta then
          if rays >= M.maxRaysPerFrame or (rays > 0 and timer:stop() >= M.sampleBudgetMs) then goto continue end
          rays = rays + 1
          local cx, cz = (i + 0.5) * r, (k + 0.5) * r
          local bx, by = cx, -cz
          local startZ = feetY + above
          origin:set(bx, by, startZ)
          local hit = Engine.castRay(origin, origin + down * reach, true, false)
          local d = hit and hit.dist
          local h = NONE
          if d and d < reach then h = startZ - d end
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

function M.update(x,y,z)
  if M.withoutBlocks then return M.withoutBlocks(function() return sample(x,y,z) end) end
  return sample(x,y,z)
end

-- ground around a mob (or a spot Minecraft wants to spawn one at), MC coords
function M.around(x, y, z, radius, above, reach)
  local f = function() return sample(x, y, z, radius, above, reach) end
  if M.withoutBlocks then return M.withoutBlocks(f) end
  return f()
end

-- Where the crosshair meets BeamNG's world (MC coords), for placing blocks on the
-- ground. eyeB = BeamNG eye position, dirB = BeamNG unit look direction.
local function aim(eyeB, dirB, maxDist)
  -- Scene raycasts respect disabled objects; the fast physics raycast reads a
  -- cached triangle soup and can return MC geometry removed this very frame.
  local res = Engine.castRay(eyeB, eyeB + dirB * maxDist, true, false)
  if not res or res.dist >= maxDist then return nil end
  local hit, normal = vec3(res.pt), vec3(res.norm)
  local mx,my,mz = coords.bngToMc(hit.x,hit.y,hit.z)
  local nx,ny,nz = coords.bngToMc(normal.x,normal.y,normal.z)
  return {x=mx,y=my,z=mz,nx=nx,ny=ny,nz=nz,d=res.dist}
end

function M.aim(eye,dir,reach)
  if M.withoutBlocks then return M.withoutBlocks(function() return aim(eye,dir,reach) end) end
  return aim(eye,dir,reach)
end
return M
