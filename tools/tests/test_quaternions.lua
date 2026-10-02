package.path = './lua/ge/extensions/?.lua;' .. package.path
-- stub BeamNG globals used at module load
QuatF = function() end vec3 = function(x,y,z) return {x=x,y=y,z=z} end
local mu = require('beamcraft/meshutil')
local function near(a,b) return math.abs(a-b) < 1e-9 end
-- 90 deg about Z maps +X to +Y
local x,y,z = mu.qrot(mu.qaxis(0,0,1,math.pi/2), 1,0,0)
assert(near(x,0) and near(y,1) and near(z,0), 'rotZ')
-- camera frame: yaw/pitch -> forward (sin yaw cos p, cos yaw cos p, sin p)
for _, a in ipairs({{0.3,0.2},{2.1,-0.6},{-1.0,1.2}}) do
  local yaw, p = a[1], a[2]
  local q = mu.qmul(mu.qaxis(0,0,1,-yaw), mu.qaxis(1,0,0,p))
  local fx,fy,fz = mu.qrot(q, 0,1,0)
  assert(near(fx, math.sin(yaw)*math.cos(p)) and near(fy, math.cos(yaw)*math.cos(p)) and near(fz, math.sin(p)), 'camera fwd')
  local rx,ry,rz = mu.qrot(q, 1,0,0)   -- right vector stays horizontal
  assert(near(rz, 0), 'right horizontal')
end
-- body yaw: MC yaw Y faces BeamNG (-sinY, -cosY)
for _, Y in ipairs({0, 37, 90, 200}) do
  local q = mu.qaxis(0,0,1, math.pi - math.rad(Y))
  local fx,fy = mu.qrot(q, 0,1,0)
  assert(near(fx, -math.sin(math.rad(Y))) and near(fy, -math.cos(math.rad(Y))), 'body yaw '..Y)
end
-- composition order: qmul(a,b) applies b first
local a, b = mu.qaxis(0,0,1,math.pi/2), mu.qaxis(1,0,0,math.pi/2)
local x2,y2,z2 = mu.qrot(mu.qmul(a,b), 0,1,0)   -- b: +Y -> +Z ; a: +Z stays
assert(near(x2,0) and near(y2,0) and near(z2,1), 'order')
print('quaternion maths OK')
