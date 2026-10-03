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

-- A dent where your swing meets the car: the first node along the look ray (within
-- 0.35 m of it) is the impact point, then every node within radius r of it is shoved
-- along the swing, hardest at the centre. dv = speed change (m/s) at the centre.
-- Falls back to the point Minecraft reported if the ray misses every node.
local DENT = [[
local eye = vec3(%f, %f, %f) local d = vec3(%f, %f, %f) local hp = vec3(%f, %f, %f)
local r = %f local dv = %f local br = %f
local pos = obj:getPosition()
local bestT = 1e9
for _, n in pairs(v.data.nodes) do
  local q = pos + obj:getNodePosition(n.cid) local rel = q - eye local t = rel:dot(d)
  if t > 0 and t < 7 and t < bestT and (rel - d * t):length() < 0.35 then bestT, hp = t, q end
end
for _, n in pairs(v.data.nodes) do
  local q = pos + obj:getNodePosition(n.cid) local dist = (q - hp):length()
  if dist < r then
    local w = 1 - dist / r
    obj:applyForceVectorTime(n.cid, d * (obj:getNodeMass(n.cid) * dv * w / 0.03), 0.03)
  end
end
-- heavy blows tear the metal at the impact point
if br > 0 then
  for _, b in pairs(v.data.beams) do
    local p1 = pos + obj:getNodePosition(b.id1) local p2 = pos + obj:getNodePosition(b.id2)
    if (p1 - hp):length() < br and (p2 - hp):length() < br * 1.5 then obj:breakBeam(b.cid) end
  end
end
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

-- A successful vanilla combat hit. m.dmg is Minecraft's final damage for the swing:
-- weapon, attack cooldown, crits, Sharpness/Smite, mace fall bonus all included
-- (fist 1, iron sword 6, netherite axe 10, a mace smash can be 30+).
M.dentPerDamage = 4.5     -- m/s of dent speed per point of damage
M.dentRadiusBase = 0.25   -- metres
M.dentRadiusPerDamage = 0.035
M.tearFromDamage = 20     -- hits at least this hard break beams at the impact
M.tearRadiusPerDamage = 0.006
function M.hit(m, now, eye)
  local veh = scenetree.findObjectById(m.id)
  if not veh or veh:getJBeamFilename() == 'unicycle' then return end
  if now - (attackCooldown[m.id] or -10) < 0.1 then return end
  attackCooldown[m.id] = now
  local x, y, z = coords.mcToBng(m.x, m.y, m.z)
  local dx, dy, dz = coords.mcToBng(m.dx, m.dy, m.dz)
  local damage = math.max(0, math.min(200, m.dmg or 1))
  log('I', 'beamcraft', string.format('hit car %d for %.1f damage', m.id, damage))
  -- the whole car rocks a little; heavy hits shove it
  local push = vec3(dx, dy, dz) * math.min(10, damage * 0.15)
  veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 1, push.x, push.y, math.max(-1, push.z) + 0.1)
  local radius = math.min(1.8, M.dentRadiusBase + damage * M.dentRadiusPerDamage)
  local dv = math.min(300, 6 + damage * M.dentPerDamage)
  local tear = damage >= M.tearFromDamage and math.min(0.6, damage * M.tearRadiusPerDamage) or 0
  eye = eye or vec3(x, y, z) - vec3(dx, dy, dz) * 2
  veh:queueLuaCommand(string.format(DENT, eye.x, eye.y, eye.z, dx, dy, dz, x, y, z, radius, dv, tear))
end

function M.updateObstacles(world)
  eachVehicle(function(veh)
    local speed=veh:getVelocity():length()
    local distance=world.obstacleDistance(veh, math.min(180,8+speed*0.5+speed*speed/8))
    veh:queueLuaCommand(string.format("extensions.load('beamcraftObstacles'); extensions.beamcraftObstacles.setDistance(%f)",distance or -1))
  end)
end
return M
