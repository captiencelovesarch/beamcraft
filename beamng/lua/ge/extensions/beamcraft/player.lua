-- Steve in BeamNG: Minecraft's player model parts, animated from the exact
-- ModelPart poses sent by the hidden client, plus a first-person arm and held item.

local coords = require('beamcraft/coords')
local mu = require('beamcraft/meshutil')

local M = {}

local PX = 0.9375 / 16      -- one skin pixel in metres (Minecraft renders players at 15/16)
local objs = {}             -- part name -> ProceduralMesh
local capeObj
local fpArm, fpItem, tpItem, tpLeft
local fpItemKey, tpItemKey, tpLeftKey
local skin                  -- { material, slim }
local armorSpec, armorKey
local pi = math.pi

M.visibleThird = false
M.visibleFirst = false

-- part = { pivot (character space, px), box min/max relative to pivot (px), uv, overlay uv, inflate }
local function partDefs(slim)
  local aw = slim and 3 or 4
  return {
    head = { pivot = { 0, 0, 24 }, box = { -4, -4, 0, 4, 4, 8 }, uv = { 0, 0, 8, 8, 8 }, over = { 32, 0 }, inflate = 0.5 },
    body = { pivot = { 0, 0, 24 }, box = { -4, -2, -12, 4, 2, 0 }, uv = { 16, 16, 8, 12, 4 }, over = { 16, 32 }, inflate = 0.25 },
    armR = { pivot = { 5, 0, 22 }, box = { -1, -2, -10, aw - 1, 2, 2 }, uv = { 40, 16, aw, 12, 4 }, over = { 40, 32 }, inflate = 0.25 },
    armL = { pivot = { -5, 0, 22 }, box = { 1 - aw, -2, -10, 1, 2, 2 }, uv = { 32, 48, aw, 12, 4 }, over = { 48, 48 }, inflate = 0.25 },
    legR = { pivot = { 2, 0, 12 }, box = { -2, -2, -12, 2, 2, 0 }, uv = { 0, 16, 4, 12, 4 }, over = { 0, 32 }, inflate = 0.25 },
    legL = { pivot = { -2, 0, 12 }, box = { -2, -2, -12, 2, 2, 0 }, uv = { 16, 48, 4, 12, 4 }, over = { 0, 48 }, inflate = 0.25 },
  }
end

local function partMesh(def)
  local m = mu.newMesh(skin.baseMaterial)
  local b, uv = def.box, def.uv
  mu.addUvBox(m, b[1] * PX, b[2] * PX, b[3] * PX, b[4] * PX, b[5] * PX, b[6] * PX, uv[1], uv[2], uv[3], uv[4], uv[5], 64, 64, true)
  local meshes = { m }
  if skin.overlays and skin.overlays[def.name] then
    local outer = mu.newMesh(skin.outerMaterial)
    local i = def.inflate
    mu.addUvBox(outer, (b[1] - i) * PX, (b[2] - i) * PX, (b[3] - i) * PX, (b[4] + i) * PX, (b[5] + i) * PX, (b[6] + i) * PX,
      def.over[1], def.over[2], uv[3], uv[4], uv[5], 64, 64, true)
    meshes[#meshes + 1] = outer
  end
  local slots = {
    head = { 'head' }, body = { 'chest', 'legs' },
    armR = { 'chest' }, armL = { 'chest' },
    legR = { 'legs', 'feet' }, legL = { 'legs', 'feet' },
  }
  for _, slot in ipairs(slots[def.name] or {}) do
    local armor = skin.armor and skin.armor[slot]
    if armor then
      local m = mu.newMesh(armor.material)
      local i = slot == 'legs' and 0.5 or 1
      local u = uv
      if def.name == 'armL' then u = { 40, 16, uv[3], 12, 4 } end
      if def.name == 'legL' then u = { 0, 16, 4, 12, 4 } end
      mu.addUvBox(m, (b[1] - i) * PX, (b[2] - i) * PX, (b[3] - i) * PX,
        (b[4] + i) * PX, (b[5] + i) * PX, (b[6] + i) * PX,
        u[1], u[2], u[3], u[4], u[5], 64, 32, true)
      meshes[#meshes + 1] = m
    end
  end
  return meshes
end

local defs

local function attachArmorMaterials()
  if not skin then return end
  skin.armor = {}
  for _, slot in ipairs({ 'head', 'chest', 'legs', 'feet' }) do
    local piece = armorSpec and armorSpec[slot]
    if piece and piece.texture then
      local name = 'bc_armor_' .. slot .. '_' .. piece.texture:gsub('[^%w]', '_')
      skin.armor[slot] = {
        material = mu.textureMaterial(name, piece.texture, 'cutout', nil, piece.mask, true),
      }
    end
  end
  mu.flushMaterials()
end

function M.setArmor(pieces)
  pieces = pieces or {}
  local parts = {}
  for _, slot in ipairs({ 'head', 'chest', 'legs', 'feet' }) do
    local piece = pieces[slot]
    parts[#parts + 1] = piece and piece.texture or ''
  end
  local key = table.concat(parts, '|')
  if key == armorKey then return end
  armorKey, armorSpec = key, pieces
  M.destroy()
  attachArmorMaterials()
end

-- called when Minecraft sends the gui assets (skin texture)
function M.setSkin(dir, slim, file, overlays, maskFile, capeFile)
  M.destroy()
  file = file or 'skin.png'
  local name = 'bc_skin_' .. (tostring(dir) .. '_' .. file):gsub('[^%w]', '_')
  skin = {
    baseMaterial = mu.textureMaterial(name .. '_base', dir .. '/' .. file, 'solid', nil, nil, true),
    outerMaterial = mu.textureMaterial(name .. '_outer', dir .. '/' .. file, 'cutout', nil,
      maskFile and (dir .. '/' .. maskFile) or nil, true),
    capeMaterial = capeFile and mu.textureMaterial(name .. '_cape', dir .. '/' .. capeFile, 'solid', nil, nil, true),
    slim = slim, overlays = overlays,
  }
  attachArmorMaterials()
  defs = partDefs(slim)
  for partName, def in pairs(defs) do def.name = partName end
end

local function ensureParts()
  if objs.head or not skin then return objs.head ~= nil end
  for name, def in pairs(defs) do objs[name] = mu.newObject('beamcraft_steve_' .. name, partMesh(def)) end
  fpArm = mu.newObject('beamcraft_fparm', partMesh(defs.armR))
  if skin.capeMaterial then
    local m = mu.newMesh(skin.capeMaterial)
    mu.addUvBox(m, -5 * PX, 0, -16 * PX, 5 * PX, 1 * PX, 0, 0, 0, 10, 16, 1, 64, 32, true)
    capeObj = mu.newObject('beamcraft_cape', { m })
  end
  return true
end

function M.destroy()
  for k, o in pairs(objs) do mu.deleteObject(o) objs[k] = nil end
  mu.deleteObject(fpArm) fpArm = nil
  mu.deleteObject(fpItem) fpItem = nil fpItemKey = nil
  mu.deleteObject(tpItem) tpItem = nil tpItemKey = nil
  mu.deleteObject(tpLeft) tpLeft = nil tpLeftKey = nil
  mu.deleteObject(capeObj) capeObj = nil
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

-- Rotate Minecraft model coordinates (-X, -Z, -Y) into BeamNG character space.
-- Minecraft's ModelPart applies Z, then Y, then X Euler rotations.
local s2 = math.sqrt(0.5)
local mcToBeam = { 0, s2, -s2, 0 }
local beamToMc = { 0, -s2, s2, 0 }
local function modelRotation(part)
  local q = part[7] and { part[7], part[8], part[9], part[10] } or
    mu.qmul(mu.qaxis(0, 0, 1, part[6]),
      mu.qmul(mu.qaxis(0, 1, 0, part[5]), mu.qaxis(1, 0, 0, part[4])))
  return mu.qmul(mu.qmul(mcToBeam, q), beamToMc)
end

-- snap = interpolated pose { x,y,z (MC feet), by (body yaw), hy (head yaw), pitch,
-- m (vanilla ModelPart poses), held, hs }
function M.updateThird(snap, ctx)
  if not M.visibleThird or not snap or not ensureParts() then
    for _, o in pairs(objs) do hide(o) end
    hide(tpItem)
    hide(tpLeft)
    hide(capeObj)
    return
  end
  local bx, by, bz = coords.mcToBng(snap.x, snap.y, snap.z)
  local yawB = pi - math.rad(snap.by or 0)
  local qBody = mu.qaxis(0, 0, 1, yawB)
  -- vanilla's extra body rotation (elytra flight, swimming, riptide, dying) about the
  -- feet, in the yawed body frame; MC axes (x, y, z) are our (x, -z, y) there
  local bt = snap.bt
  if bt then
    local ox, oy, oz = mu.qrot(qBody, bt[5], -bt[7], bt[6])
    bx, by, bz = bx + ox, by + oy, bz + oz
    qBody = mu.qmul(qBody, { bt[1], -bt[3], bt[2], bt[4] })
  end
  local worldParts = {}
  for name, def in pairs(defs) do
    local part = snap.m and snap.m[name]
    local px, py, pz, q
    if part then
      local ox, oy, oz = mu.qrot(qBody, -part[1] * PX, -part[3] * PX, (24 - part[2]) * PX)
      px, py, pz = bx + ox, by + oy, bz + oz
      q = mu.qmul(qBody, modelRotation(part))
    else
      -- A client without model poses still has a stable standing player.
      local pv = def.pivot
      local ox, oy, oz = mu.qrot(qBody, pv[1] * PX, pv[2] * PX, pv[3] * PX)
      px, py, pz, q = bx + ox, by + oy, bz + oz, qBody
    end
    mu.setXform(objs[name], px, py, pz, q)
    worldParts[name] = { px, py, pz, q }
  end

  local cape = snap.m and snap.m.cape
  if capeObj and cape and worldParts.body then
    local body = worldParts.body
    local ox, oy, oz = mu.qrot(body[4], -cape[1] * PX, -cape[3] * PX, -cape[2] * PX)
    mu.setXform(capeObj, body[1] + ox, body[2] + oy, body[3] + oz,
      mu.qmul(body[4], modelRotation(cape)))
  else
    hide(capeObj)
  end

  -- Mesh vertices already include vanilla's item and hand transforms. Attach at
  -- the ModelPart pivot; applying another offset here would double-transform it.
  if snap.ir ~= tpItemKey or (snap.ir and not tpItem) then
    mu.deleteObject(tpItem) tpItem = snap.ir and ctx.items.object(snap.ir, 'beamcraft_tpitem') or nil tpItemKey = snap.ir
  end
  if snap.il ~= tpLeftKey or (snap.il and not tpLeft) then
    mu.deleteObject(tpLeft) tpLeft = snap.il and ctx.items.object(snap.il, 'beamcraft_tpitem_left') or nil tpLeftKey = snap.il
  end
  for _, hand in ipairs({{tpItem,worldParts.armR},{tpLeft,worldParts.armL}}) do
    if hand[1] and hand[2] then local arm=hand[2] mu.setXform(hand[1],arm[1],arm[2],arm[3],arm[4]) end
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
