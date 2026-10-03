-- BeamNG vehicles <-> Minecraft: cars are solid to Steve (sliced bounding boxes sent
-- as collision), a moving car hurts and launches him, his punches shove and dent cars,
-- and Minecraft explosions throw every nearby car's nodes outward.

local coords = require('beamcraft/coords')

local M = {}

M.boxRadius = 25        -- send collision for cars within this many metres of Steve
M.hitSpeed = 3.0        -- m/s relative speed before a car hurts
M.punchSpeed = 1.8      -- m/s a punch adds to the whole car
M.punchDent = 220       -- per-node shove of the panel you hit (dv * 1/s)

local cooldown = {}
local attackCooldown = {}

local function eachVehicle(fn)
  for _, veh in ipairs(getAllVehicles()) do
    if veh:getJBeamFilename() ~= 'unicycle' then fn(veh) end
  end
end

local function oobbParts(veh)
  local bb = veh:getSpawnWorldOOBB()
  return bb:getCenter(), { bb:getAxis(0), bb:getAxis(1), bb:getAxis(2) }, bb:getHalfExtents()
end

------------------------------------------------------------------------------
-- collision boxes for Minecraft (MC coords), sliced along the car's length so the
-- axis-aligned approximation of a rotated car stays tight
------------------------------------------------------------------------------

function M.collisionBoxes(steveB)
  local out, targets = {}, {}
  eachVehicle(function(veh)
    local c, ax, he = oobbParts(veh)
    if (c - steveB):length() > M.boxRadius then return end
    local hev = { he.x, he.y, he.z }
    -- longest axis that is mostly horizontal
    local L, best = 1, -1
    for i = 1, 3 do
      if math.abs(ax[i].z) < 0.7 and hev[i] > best then best, L = hev[i], i end
    end
    local n = math.max(2, math.min(12, math.ceil(2 * hev[L] / 0.5)))
    for k = 0, n - 1 do
      local off = -hev[L] + (k + 0.5) * 2 * hev[L] / n
      local cc = c + ax[L] * off
      local h = { hev[1], hev[2], hev[3] }
      h[L] = hev[L] / n
      local ex, ey, ez = 0, 0, 0
      for i = 1, 3 do
        ex = ex + math.abs(ax[i].x) * h[i]
        ey = ey + math.abs(ax[i].y) * h[i]
        ez = ez + math.abs(ax[i].z) * h[i]
      end
      -- BeamNG box -> MC box: x = x, y = z, z = -y
      local box = { cc.x - ex, cc.z - ez, -(cc.y + ey), cc.x + ex, cc.z + ez, -(cc.y - ey) }
      out[#out + 1] = box
      targets[#targets + 1] = {veh:getID() * 32 + k, veh:getID(), unpack(box)}
    end
  end)
  return out, targets
end

------------------------------------------------------------------------------
-- cars hitting Steve
------------------------------------------------------------------------------

-- steveB = feet position (BeamNG), returns a 'hurt' message or nil
function M.checkHits(now, steveB)
  local msg
  eachVehicle(function(veh)
    if msg then return end
    local v = veh:getVelocity()
    local speed = v:length()
    if speed < M.hitSpeed then return end
    local c, ax, he = oobbParts(veh)
    local body = steveB + vec3(0, 0, 0.9)
    local d = body - c
    local hev = { he.x, he.y, he.z }
    for i = 1, 3 do
      local margin = math.abs(ax[i].z) > 0.7 and 0.9 or 0.35
      if math.abs(d:dot(ax[i])) > hev[i] + margin then return end
    end
    local id = veh:getID()
    if now - (cooldown[id] or -10) < 0.6 then return end
    cooldown[id] = now
    local dmg = (speed - M.hitSpeed) * 1.6
    local kx, ky, kz = v.x * 1.1, v.y * 1.1, v.z + 4 + speed * 0.15
    local mx, my, mz = coords.bngToMc(kx, ky, kz)
    msg = { t = 'hurt', dmg = dmg, vx = mx, vy = my, vz = mz }
  end)
  return msg
end

------------------------------------------------------------------------------
-- punching cars
------------------------------------------------------------------------------

local DENT = [[
local hp = vec3(%f, %f, %f) local d = vec3(%f, %f, %f) local k = %f
local pos = obj:getPosition() local best, bd = nil, 1e9
for _, n in pairs(v.data.nodes) do
  local q = pos + obj:getNodePosition(n.cid) local dd = (q - hp):squaredLength()
  if dd < bd then bd, best = dd, n.cid end
end
if best and bd < 1.5 then obj:applyForceVectorTime(best, d * (obj:getNodeMass(best) * k), 0.05) end
]]

------------------------------------------------------------------------------
-- explosions
------------------------------------------------------------------------------

local BOOM = [[
local c = vec3(%f, %f, %f) local r = %f
local pos = obj:getPosition()
for _, n in pairs(v.data.nodes) do
  local p = pos + obj:getNodePosition(n.cid) local d = p - c local dist = d:length()
  if dist < r * 5 then
    local dv = math.min(30, 3.2 * r * r / (1 + dist * dist))
    local dir = dist > 0.01 and (d / dist) or vec3(0, 0, 1)
    dir = (dir + vec3(0, 0, 0.35)):normalized()
    obj:applyForceVectorTime(n.cid, dir * (obj:getNodeMass(n.cid) * dv / 0.04), 0.04)
  end
end
]]

-- cMc = explosion centre (MC coords), r = Minecraft blast radius (TNT = 4)
function M.explode(x, y, z, r, now)
  local bx, by, bz = coords.mcToBng(x, y, z)
  local c = vec3(bx, by, bz)
  eachVehicle(function(veh)
    local vc = oobbParts(veh)
    if (vc - c):length() < r * 6 then
      veh:queueLuaCommand(string.format(BOOM, bx, by, bz, r))
    end
  end)
end

-- A successful vanilla combat hit, including weapon, enchantment and mace damage.
function M.hit(m, now)
  local veh=scenetree.findObjectById(m.id)
  if not veh or veh:getJBeamFilename()=='unicycle' then return end
  if now-(attackCooldown[m.id] or -10)<0.1 then return end
  attackCooldown[m.id]=now
  local x,y,z=coords.mcToBng(m.x,m.y,m.z)
  local dx,dy,dz=coords.mcToBng(m.dx,m.dy,m.dz)
  local damage=math.max(0,math.min(200,m.dmg or 1))
  local push=vec3(dx,dy,dz)*math.min(12,0.3+damage*0.23)
  veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(),1,push.x,push.y,math.max(-2,push.z)+0.2)
  veh:queueLuaCommand(string.format(DENT,x,y,z,dx,dy,dz,math.min(8000,damage*110)))
end

function M.updateObstacles(world)
  eachVehicle(function(veh)
    local speed=veh:getVelocity():length()
    local distance=world.obstacleDistance(veh, math.min(180,8+speed*0.5+speed*speed/8))
    veh:queueLuaCommand(string.format("extensions.load('beamcraftObstacles'); extensions.beamcraftObstacles.setDistance(%f)",distance or -1))
  end)
end
return M
