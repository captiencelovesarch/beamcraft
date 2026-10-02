package.path = './lua/ge/extensions/?.lua;' .. package.path
local c = require('beamcraft/coords')
local fails = 0
local function eq(a, b, msg) if math.abs(a - b) > 1e-9 then print('FAIL', msg, a, b) fails = fails + 1 end end
for _, s in ipairs({{0,0,0},{-1,-1,-1},{65535,255,-65536},{-65536,-256,65535},{123,-7,-4567}}) do
  local k = c.sectionKey(s[1], s[2], s[3])
  local x, y, z = c.sectionFromKey(k)
  eq(x, s[1], 'sx') eq(y, s[2], 'sy') eq(z, s[3], 'sz')
end
-- round trip positions
local bx, by, bz = c.mcToBng(1, 2, 3); local mx, my, mz = c.bngToMc(bx, by, bz)
eq(mx,1,'x') eq(my,2,'y') eq(mz,3,'z')
-- BeamNG yaw 0 (facing +Y) == MC north (yaw 180 / -180), dir (0,0,-1) in MC == (0,1,0) BeamNG
local myaw, mp = c.bngLookToMc(0, 0)
eq(math.abs(myaw), 180, 'yaw0')
local dx, dy, dz = c.mcLookDirBng(myaw, mp)
eq(dx, 0, 'dirx') eq(dy, 1, 'diry') eq(dz, 0, 'dirz')
-- looking up in BeamNG (pitch +0.5) -> MC pitch negative, dir z positive
local _, mp2 = c.bngLookToMc(0.3, 0.5); local _, _, dz2 = c.mcLookDirBng(c.bngLookToMc(0.3, 0.5))
assert(mp2 < 0 and dz2 > 0)
-- the BeamNG camera direction matches mcLookDirBng for arbitrary angles
for _, a in ipairs({{0.3,0.2},{2.5,-0.7},{-1.2,1.1}}) do
  local yaw, pitch = a[1], a[2]
  local cx, cy, cz = math.sin(yaw)*math.cos(pitch), math.cos(yaw)*math.cos(pitch), math.sin(pitch)
  local ex, ey, ez = c.mcLookDirBng(c.bngLookToMc(yaw, pitch))
  eq(cx, ex, 'cdx') eq(cy, ey, 'cdy') eq(cz, ez, 'cdz')
  local ry, rp = c.mcLookToBng(c.bngLookToMc(yaw, pitch))
  eq(math.sin(ry), math.sin(yaw), 'rt sin') eq(math.cos(ry), math.cos(yaw), 'rt cos') eq(rp, pitch, 'rt pitch')
end
print(fails == 0 and 'coords OK' or ('coords FAILED ' .. fails))
