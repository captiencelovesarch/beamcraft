-- BeamCraft camera: first person through Steve's eyes.
--
-- Look is owned here (mouse -> yaw/pitch, no smoothing, like Minecraft) so aiming
-- has zero network latency; the angles are forwarded to Minecraft every frame.
-- Position comes from Minecraft's physics via beamcraft_main, interpolated.
-- Modelled on core/cameraModes/steadycam.lua.

local C = {}
C.__index = C

local up = vec3(0, 0, 1)
local fwd = vec3()

function C:init()
  self.icon = "personSolid"
  self.isGlobal = true
  self.group = "world"
  self.groupOrder = 90
  self.hidden = true
  self.mouseSens = 0.3
  self.keyLookRate = 1.75
  self.fov = 70          -- Minecraft's default FOV
  self.pos = vec3()
  self.yaw = 0
  self.pitch = 0
  self.thirdPerson = false
end

function C:reset() end

function C:setPosition(p) self.pos:set(p) end
function C:setRotation(q)
  fwd:set(0, 1, 0); fwd:setRotate(q)
  self.yaw = math.atan2(fwd.x, fwd.y)
  self.pitch = clamp(math.asin(clamp(fwd.z, -1, 1)), -1.55, 1.55)
end
function C:setFOV(fov) self.fov = clamp(tonumber(fov) or 70, 30, 120) end

function C:onCameraChanged(focused)
  if focused then
    pushActionMapHighestPriority("BeamCraft")
  else
    popActionMap("BeamCraft")
  end
  if beamcraft_main and beamcraft_main.onCameraFocus then beamcraft_main.onCameraFocus(focused) end
end

function C:update(data)
  data.res.collisionCompatible = false
  local dt = data.dt
  if dt <= 0 then dt = 1e-4 end

  local bc = beamcraft_main
  local looking = not (bc and bc.isPickerOpen and bc.isPickerOpen())
  if looking then
    self.yaw = self.yaw + MoveManager.yawRelative * self.mouseSens
             + (MoveManager.yawRight - MoveManager.yawLeft) * self.keyLookRate * dt
    self.pitch = self.pitch + MoveManager.pitchRelative * self.mouseSens
               + (MoveManager.pitchUp - MoveManager.pitchDown) * self.keyLookRate * dt
    self.pitch = clamp(self.pitch, -1.55, 1.55)
  end

  if bc then
    bc.setMoveInput(
      MoveManager.forward + math.max(0, MoveManager.absYAxis or 0),
      MoveManager.backward + math.max(0, -(MoveManager.absYAxis or 0)),
      MoveManager.left + math.max(0, -(MoveManager.absXAxis or 0)),
      MoveManager.right + math.max(0, MoveManager.absXAxis or 0))
    bc.setLook(self.yaw, self.pitch)
    local eye = bc.getEyePos()
    if eye then self.pos:set(eye) end
  end

  local cp = math.cos(self.pitch)
  fwd:set(math.sin(self.yaw) * cp, math.cos(self.yaw) * cp, math.sin(self.pitch))
  local camPos = self.pos
  if bc and bc.thirdPerson then
    camPos = self.pos - fwd * 4
    local d = castRayStatic(self.pos, fwd * -1, 4)
    if d and d < 4 then camPos = self.pos - fwd * math.max(0.3, d - 0.2) end
  end

  data.res.pos:set(camPos)
  data.res.rot = quatFromDir(fwd, up)
  data.res.fov = self.fov
  data.res.targetPos:set(self.pos.x + fwd.x * 10, self.pos.y + fwd.y * 10, self.pos.z + fwd.z * 10)
  return true
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
