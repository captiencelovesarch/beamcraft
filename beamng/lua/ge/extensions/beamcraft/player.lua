-- Steve in BeamNG: the third-person model (head, body, arms, legs from the skin,
-- animated with Minecraft's own walk/swing maths) and the first-person arm with the
-- held item.

local coords = require('beamcraft/coords')
local mu = require('beamcraft/meshutil')

local M = {}

local PX = 0.9375 / 16      -- one skin pixel in metres (Minecraft renders players at 15/16)
local objs = {}             -- part name -> ProceduralMesh
local fpArm, fpItem, tpItem
local fpItemKey, tpItemKey
local skin                  -- { material, slim }
local pi = math.pi

M.visibleThird = false
M.visibleFirst = false

-- part = { pivot (character space, px), box min/max relative to pivot (px), uv, overlay uv, inflate }
local function partDefs(slim)
  local aw = slim and 3 or 4
  return {
    head = { pivot = { 0, 0, 24 }, box = { -4, -4, 0, 4, 4, 8 }, uv = { 0, 0, 8, 8, 8 }, over = { 32, 0 }, inflate = 0.5 },
    body = { pivot = { 0, 0, 12 }, box = { -4, -2, 0, 4, 2, 12 }, uv = { 16, 16, 8, 12, 4 }, over = { 16, 32 }, inflate = 0.25 },
    armR = { pivot = { 4 + aw / 2, 0, 22 }, box = { -aw / 2, -2, -10, aw / 2, 2, 2 }, uv = { 40, 16, aw, 12, 4 }, over = { 40, 32 }, inflate = 0.25 },
    armL = { pivot = { -4 - aw / 2, 0, 22 }, box = { -aw / 2, -2, -10, aw / 2, 2, 2 }, uv = { 32, 48, aw, 12, 4 }, over = { 48, 48 }, inflate = 0.25 },
    legR = { pivot = { 2, 0, 12 }, box = { -2, -2, -12, 2, 2, 0 }, uv = { 0, 16, 4, 12, 4 }, over = { 0, 32 }, inflate = 0.25 },
    legL = { pivot = { -2, 0, 12 }, box = { -2, -2, -12, 2, 2, 0 }, uv = { 16, 48, 4, 12, 4 }, over = { 0, 48 }, inflate = 0.25 },
  }
end

local function partMesh(def)
  local m = mu.newMesh(skin.material)
  local b, uv = def.box, def.uv
  mu.addUvBox(m, b[1] * PX, b[2] * PX, b[3] * PX, b[4] * PX, b[5] * PX, b[6] * PX, uv[1], uv[2], uv[3], uv[4], uv[5], 64, 64)
  local i = def.inflate
  mu.addUvBox(m, (b[1] - i) * PX, (b[2] - i) * PX, (b[3] - i) * PX, (b[4] + i) * PX, (b[5] + i) * PX, (b[6] + i) * PX,
    def.over[1], def.over[2], uv[3], uv[4], uv[5], 64, 64)
  return m
end

local defs

-- called when Minecraft sends the gui assets (skin texture)
function M.setSkin(dir, slim, file)
  M.destroy()
  file = file or 'skin.png'
  local name = 'bc_skin_' .. (tostring(dir) .. '_' .. file):gsub('[^%w]', '_')
  skin = { material = mu.textureMaterial(name, dir .. '/' .. file, 'cutout'), slim = slim }
  mu.flushMaterials()
  defs = partDefs(slim)
end

local function ensureParts()
  if objs.head or not skin then return objs.head ~= nil end
  for name, def in pairs(defs) do objs[name] = mu.newObject('beamcraft_steve_' .. name, { partMesh(def) }) end
  fpArm = mu.newObject('beamcraft_fparm', { partMesh(defs.armR) })
  return true
end

function M.destroy()
  for k, o in pairs(objs) do mu.deleteObject(o) objs[k] = nil end
  mu.deleteObject(fpArm) fpArm = nil
  mu.deleteObject(fpItem) fpItem = nil fpItemKey = nil
  mu.deleteObject(tpItem) tpItem = nil tpItemKey = nil
end

local HIDE = -100000
local function hide(o) if o then mu.setXform(o, 0, 0, HIDE, mu.IDENTITY) end end

------------------------------------------------------------------------------
-- held item meshes
------------------------------------------------------------------------------

-- ctx: { world = world module, iconPath = function(id) -> texture path }
local function heldObject(key, held, heldState, ctx, scaleBlock, scaleItem)
  if not held then return nil end
  local meshes
  if heldState and ctx.world.getStateQuads(heldState) then
    meshes = mu.blockMeshes(ctx.world.getStateQuads(heldState), scaleBlock, ctx.world.matFor)
  else
    local m = mu.newMesh(mu.textureMaterial('bc_icon_' .. held:gsub('[^%w]', '_'), ctx.iconPath(held), 'cutout'))
    mu.addFlatQuad(m, scaleItem)
    meshes = { m }
  end
  mu.flushMaterials()
  return mu.newObject('beamcraft_' .. key, meshes)
end

------------------------------------------------------------------------------
-- third person
------------------------------------------------------------------------------

-- snap = interpolated pose { x,y,z (MC feet), by (body yaw), hy (head yaw), pitch,
-- lp, ls (limb swing pos/speed), sw (attack anim 0..1), cr (crouching), held, hs }
function M.updateThird(snap, ctx)
  if not M.visibleThird or not snap or not ensureParts() then
    for _, o in pairs(objs) do hide(o) end
    hide(tpItem)
    return
  end
  local bx, by, bz = coords.mcToBng(snap.x, snap.y, snap.z)
  -- character +Y (forward) -> Minecraft facing; see coords.lua for the yaw mapping
  local yawB = pi - math.rad(snap.by or 0)
  local qBody = mu.qaxis(0, 0, 1, yawB)
  local crouch = (snap.cr == 1)

  local t = (snap.lp or 0) * 0.6662
  local ls = math.min(1, snap.ls or 0)
  local swing = math.sin((snap.sw or 0) * pi)
  local headYaw = math.rad((snap.hy or snap.by or 0) - (snap.by or 0))
  local rot = {
    head = mu.qmul(mu.qaxis(0, 0, 1, -headYaw), mu.qaxis(1, 0, 0, -math.rad(snap.pitch or 0))),
    body = crouch and mu.qaxis(1, 0, 0, 0.5) or mu.IDENTITY,
    armR = mu.qaxis(1, 0, 0, math.cos(t + pi) * ls + swing * 1.4 + (crouch and 0.4 or 0)),
    armL = mu.qaxis(1, 0, 0, math.cos(t) * ls + (crouch and 0.4 or 0)),
    legR = mu.qaxis(1, 0, 0, math.cos(t) * 1.4 * ls),
    legL = mu.qaxis(1, 0, 0, math.cos(t + pi) * 1.4 * ls),
  }
  local drop = crouch and 3.2 or 0  -- crouching lowers the upper body (px)
  for name, def in pairs(defs) do
    local pv = def.pivot
    local pz = pv[3] - ((name ~= 'legR' and name ~= 'legL') and drop or 0)
    local wx, wy, wz = mu.qrot(qBody, pv[1] * PX, pv[2] * PX, pz * PX)
    mu.setXform(objs[name], bx + wx, by + wy, bz + wz, mu.qmul(qBody, rot[name]))
  end

  -- held item in the right hand
  local key = snap.held and (snap.held .. '/' .. tostring(snap.hs)) or nil
  if key ~= tpItemKey then
    mu.deleteObject(tpItem)
    tpItem, tpItemKey = heldObject('tpitem', snap.held, snap.hs, ctx, 0.25, 0.4), key
  end
  if tpItem then
    local qa = mu.qmul(qBody, rot.armR)
    local pv = defs.armR.pivot
    local sx, sy, sz = mu.qrot(qBody, pv[1] * PX, pv[2] * PX, (pv[3] - drop) * PX)
    local hx, hy, hz = mu.qrot(qa, 0, 2 * PX, -10 * PX)
    mu.setXform(tpItem, bx + sx + hx, by + sy + hy, bz + sz + hz, qa)
  end
end

------------------------------------------------------------------------------
-- first person: called from the camera mode with the final camera pose
------------------------------------------------------------------------------

-- camPos (vec3), yaw/pitch = camera look (BeamNG radians), snap as above
function M.updateFirst(camPos, yaw, pitch, snap, ctx, dt)
  if not M.visibleFirst or not snap or not ensureParts() then
    hide(fpArm)
    hide(fpItem)
    return
  end
  -- camera frame: forward = (sin yaw cos p, cos yaw cos p, sin p)
  local qCam = mu.qmul(mu.qaxis(0, 0, 1, -yaw), mu.qaxis(1, 0, 0, pitch))
  local sw = snap.sw or 0
  local swing = math.sin(sw * pi)
  local swing2 = math.sin(math.sqrt(sw) * pi)
  -- bob while walking
  M.bobT = (M.bobT or 0) + dt * (snap.ls or 0) * 10
  local bob = math.sin(M.bobT) * 0.012 * math.min(1, snap.ls or 0)

  local key = snap.held and (snap.held .. '/' .. tostring(snap.hs)) or nil
  if key ~= fpItemKey then
    mu.deleteObject(fpItem)
    fpItem, fpItemKey = heldObject('fpitem', snap.held, snap.hs, ctx, 0.32, 0.42), key
  end

  if fpItem then
    hide(fpArm)
    -- item held out at the lower right, swung down-forward on use
    local ox, oy, oz = 0.36 - swing2 * 0.12, 0.62 + swing * 0.1, -0.38 + bob - swing * 0.12
    local wx, wy, wz = mu.qrot(qCam, ox, oy, oz)
    local q = mu.qmul(qCam, mu.qmul(mu.qaxis(0, 0, 1, 0.75 - swing2 * 0.4), mu.qaxis(1, 0, 0, -swing * 0.9)))
    mu.setXform(fpItem, camPos.x + wx, camPos.y + wy, camPos.z + wz, q)
  else
    hide(fpItem)
    -- bare arm reaching forward from the lower right
    local ox, oy, oz = 0.42 - swing2 * 0.14, 0.3 + swing * 0.12, -0.5 + bob - swing * 0.1
    local wx, wy, wz = mu.qrot(qCam, ox, oy, oz)
    local q = mu.qmul(qCam, mu.qmul(mu.qaxis(0, 0, 1, 0.25), mu.qaxis(1, 0, 0, 1.35 - swing * 0.7)))
    mu.setXform(fpArm, camPos.x + wx, camPos.y + wy, camPos.z + wz, q)
  end
end

return M
