-- Coordinate conversion between Minecraft and BeamNG.
--
-- One Minecraft block is one metre, and both worlds share an origin so blocks sit on
-- BeamNG's own metre grid. Minecraft is Y-up with +Z south; BeamNG is Z-up with +Y
-- forward. The mapping below is a proper rotation (determinant +1), so triangle
-- winding and handedness survive the trip unchanged.
--
--   BeamNG (x, y, z)  =  MC (x, -z, y)
--   MC (x, y, z)      =  BeamNG (x, z, -y)
--
-- Look angles: a BeamNG steadycam yaw of 0 faces +Y (MC north, MC yaw 180), and
-- BeamNG pitch is positive looking up while MC pitch is positive looking down.

local M = {}

local deg, rad = math.deg, math.rad

function M.mcToBng(x, y, z) return x, -z, y end
function M.bngToMc(x, y, z) return x, z, -y end

-- BeamNG camera yaw/pitch (radians) -> Minecraft yaw/pitch (degrees)
function M.bngLookToMc(yaw, pitch)
  local mcYaw = deg(yaw) - 180
  mcYaw = (mcYaw + 180) % 360 - 180
  return mcYaw, -deg(pitch)
end

-- Minecraft yaw/pitch (degrees) -> BeamNG camera yaw/pitch (radians)
function M.mcLookToBng(mcYaw, mcPitch)
  return rad(mcYaw + 180), -rad(mcPitch)
end

-- Minecraft unit direction for a MC yaw/pitch, expressed in BeamNG axes
function M.mcLookDirBng(mcYaw, mcPitch)
  local y, p = rad(mcYaw), rad(mcPitch)
  local mx, my, mz = -math.sin(y) * math.cos(p), -math.sin(p), math.cos(y) * math.cos(p)
  return mx, -mz, my
end

-- Sections are 16^3 blocks. Keys pack section coordinates into one exact double:
-- sx, sz within +-65536 sections (+-1M blocks), sy within +-256 sections.
function M.sectionKey(sx, sy, sz)
  return ((sx + 65536) * 131072 + (sz + 65536)) * 512 + (sy + 256)
end

function M.sectionFromKey(key)
  local sy = key % 512 - 256
  local rest = (key - (sy + 256)) / 512
  local sz = rest % 131072 - 65536
  local sx = (rest - (sz + 65536)) / 131072 - 65536
  return sx, sy, sz
end

return M
