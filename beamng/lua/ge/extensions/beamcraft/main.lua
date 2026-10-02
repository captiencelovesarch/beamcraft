-- BeamCraft: play Minecraft Java Edition inside BeamNG.drive.
--
-- A hidden Minecraft client (Fabric mod) runs the player: movement physics,
-- inventory, block placing and breaking, health. BeamNG renders everything and
-- supplies the world: it raycasts its terrain into Minecraft's collision, forwards
-- your input, meshes the blocks Minecraft reports, draws Steve, dropped items and
-- the HUD, and lets cars and Minecraft hurt each other. This extension is the glue.
--
-- Toggle with Alt+B (or beamcraft_main.toggle() in the console).

local M = {}
M.dependencies = { 'ui_imgui', 'core_camera' }

local coords = require('beamcraft/coords')
local net = require('beamcraft/net')
local world = require('beamcraft/world')
local terrain = require('beamcraft/terrain')
local hud = require('beamcraft/hud')
local player = require('beamcraft/player')
local entities = require('beamcraft/entities')
local vehicles = require('beamcraft/vehicles')
local mu = require('beamcraft/meshutil')
local devconsole = require('beamcraft/devconsole')
local overlay = require('beamcraft/overlay')

M.thirdPerson = false

local now = 0
local active = false          -- BeamCraft camera/controls engaged
local ready = false           -- Minecraft has a world loaded for this level
local mcInfo = {}             -- from 'welcome'
local hudState = nil
local target = nil            -- block the crosshair is on, MC coords
local prevSnap, curSnap = nil, nil
local entering = false
local vehTimer = 0
local screenOpen = false      -- a Minecraft screen (inventory, chat...) is open
local overlaySent = nil
local viewport = { w = 0, h = 0 }
local viewportTimer = 0

local ctx = { world = world, iconPath = hud.iconPath }

local input = {
  f = 0, b = 0, l = 0, r = 0,
  jump = 0, sneak = 0, sprint = 0, attack = 0, use = 0,
  yaw = 0, pitch = 0,
}
local inputDirty = true
local events = {}             -- one-shot key events to send this frame

------------------------------------------------------------------------------
-- outgoing
------------------------------------------------------------------------------

local function levelId()
  local id = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  return id or 'none'
end

local function viewportSize()
  local vp = ui_imgui.GetMainViewport()
  if not vp then return 0, 0 end
  return math.floor(vp.Size.x), math.floor(vp.Size.y)
end

local function sendHello()
  viewport.w, viewport.h = viewportSize()
  net.send({ t = 'hello', v = 1, level = levelId(), userPath = FS:getUserPath(), vw = viewport.w, vh = viewport.h })
end

local function toast(msg)
  log('I', 'beamcraft', msg)
  guihooks.trigger('toastrMsg', { type = 'info', title = 'BeamCraft', msg = msg })
end

-- mouse/keyboard from the overlay page while a Minecraft screen is open, on to Minecraft
function M.overlayInput(json)
  local ok, e = pcall(jsonDecode, json)
  if ok and type(e) == 'table' then net.send({ t = 'oin', e = e }) end
end

-- the overlay page (ui/modModules/beamcraft) asks for this, and gets pushed changes
function M.overlayState()
  return { visible = active, interactive = active and screenOpen }
end

local function pushOverlayState()
  local st = M.overlayState()
  local key = tostring(st.visible) .. tostring(st.interactive)
  if key ~= overlaySent then
    overlaySent = key
    guihooks.trigger('BeamCraftOverlay', st)
  end
end

-- a Minecraft screen opened or closed: hand the mouse and keyboard to the overlay
local function setScreenOpen(open)
  if open == screenOpen then return end
  screenOpen = open
  if lockMouse then lockMouse(active and not open) end
  if setCEFTyping then setCEFTyping(active and open) end
  -- our action map binds the mouse buttons to attack/use: while a screen is open the
  -- clicks belong to the overlay page instead
  if active then
    if open then popActionMap('BeamCraft') else pushActionMapHighestPriority('BeamCraft') end
  end
  input.f, input.b, input.l, input.r = 0, 0, 0, 0
  input.jump, input.sneak, input.sprint, input.attack, input.use = 0, 0, 0, 0, 0
  inputDirty = true
  pushOverlayState()
end
function M.isScreenOpen() return screenOpen end

function M.setMoveInput(f, b, l, r)
  if screenOpen then return end
  f, b, l, r = clamp(f, 0, 1), clamp(b, 0, 1), clamp(l, 0, 1), clamp(r, 0, 1)
  if f ~= input.f or b ~= input.b or l ~= input.l or r ~= input.r then
    input.f, input.b, input.l, input.r = f, b, l, r
    inputDirty = true
  end
end

function M.setLook(yaw, pitch)
  local my, mp = coords.bngLookToMc(yaw, pitch)
  if math.abs(my - input.yaw) > 1e-3 or math.abs(mp - input.pitch) > 1e-3 then
    input.yaw, input.pitch = my, mp
    inputDirty = true
  end
end

function M.isPickerOpen() return screenOpen end

-- run a Minecraft command as Steve, e.g. beamcraft_main.cmd('gamemode survival')
function M.cmd(str) net.send({ t = 'cmd', c = str }) end

local function lookRay()
  local eye = M.getEyePos()
  if not eye then return nil end
  local dx, dy, dz = coords.mcLookDirBng(input.yaw, input.pitch)
  return vec3(eye), vec3(dx, dy, dz)
end

-- left click: punch a car if one is closer than the block Minecraft is aiming at
local function tryPunch()
  local eye, dir = lookRay()
  if not eye then return end
  local reach = 4.5
  if target then
    local bx, by, bz = coords.mcToBng(target[1] + 0.5, target[2] + 0.5, target[3] + 0.5)
    reach = math.min(reach, (vec3(bx, by, bz) - eye):length())
  end
  vehicles.punch(eye, dir, reach)
end

function M.key(name, value)
  if not active then return end
  local v = (value or 0) > 0.5 and 1 or 0
  if screenOpen then return end
  if name == 'jump' or name == 'sneak' or name == 'sprint' or name == 'attack' or name == 'use' then
    if input[name] ~= v then
      input[name] = v
      inputDirty = true
      -- attack/use also need a click event, Minecraft counts presses separately
      if (name == 'attack' or name == 'use') and v == 1 then events[#events + 1] = { k = name } end
      if name == 'attack' and v == 1 then tryPunch() end
    end
  elseif v == 1 then
    events[#events + 1] = { k = name }
  end
end

function M.slot(n)
  if active and not screenOpen then events[#events + 1] = { k = 'slot', n = n } end
end

function M.scroll(value)
  if active and value and value ~= 0 then
    events[#events + 1] = { k = 'scroll', n = value > 0 and -1 or 1 }
  end
end

-- F5: Minecraft cycles its camera (first person / behind / in front); we follow it
function M.togglePerspective()
  if active and not screenOpen then events[#events + 1] = { k = 'view' } end
end
M.cameraMode = 0

------------------------------------------------------------------------------
-- player pose
------------------------------------------------------------------------------

local eyeOut = vec3()
local interval = 0.05

local function lerpAngle(a, b, t)
  local d = (b - a + 180) % 360 - 180
  return a + d * t
end

-- interpolated Minecraft pose (MC coords / degrees), or nil
local function poseNow()
  if not curSnap then return nil end
  local p = prevSnap or curSnap
  local a = prevSnap and clamp((now - curSnap.at) / interval, 0, 1) or 1
  local c = curSnap
  return {
    x = p.x + (c.x - p.x) * a, y = p.y + (c.y - p.y) * a, z = p.z + (c.z - p.z) * a,
    eye = p.eye + (c.eye - p.eye) * a,
    by = lerpAngle(p.by or 0, c.by or 0, a), hy = lerpAngle(p.hy or 0, c.hy or 0, a),
    pitch = c.pitch, lp = (p.lp or 0) + ((c.lp or 0) - (p.lp or 0)) * a, ls = c.ls,
    sw = c.sw, cr = c.cr, held = c.held, hs = c.hs,
  }
end
M.poseNow = poseNow

-- interpolated eye position in BeamNG coords, or nil before the first snapshot
function M.getEyePos()
  local s = poseNow()
  if not s then return nil end
  local bx, by, bz = coords.mcToBng(s.x, s.y + s.eye, s.z)
  eyeOut:set(bx, by, bz)
  return eyeOut
end

-- called by the camera mode with the exact camera pose of this frame
function M.updateFirstPerson(camPos, yaw, pitch, dt)
  -- the first-person hand and held item are drawn by Minecraft, in the overlay
end

------------------------------------------------------------------------------
-- mode switching
------------------------------------------------------------------------------

local function hideBeamNGUi(hide)
  -- hide BeamNG's apps but keep its UI layer: Minecraft's overlay is drawn there
  guihooks.trigger('ShowApps', not hide)
end

function M.onCameraFocus(focused)
  if focused then
    if lockMouse then lockMouse(true) end
  else
    if lockMouse then lockMouse(false) end
    if active then M.exit() end
  end
end

local function groundBelow(pos)
  local d = castRayStatic(pos + vec3(0, 0, 1), vec3(0, 0, -1), 200)
  if d and d < 200 then return pos.z + 1 - d end
  return pos.z
end

function M.enter()
  if active then return end
  if not net.isConnected() then
    toast('Minecraft is not running (start tools/run_backend.sh)')
    return
  end
  if not ready then
    toast('Minecraft is still loading the world...')
    entering = true
    return
  end
  local camPos = core_camera.getPosition()
  local fwdv = core_camera.getForward()
  -- if you're in a car, step out next to it
  local veh = getPlayerVehicle(0)
  if veh and (veh:getPosition() - camPos):length() < 12 then
    local side = veh:getDirectionVectorUp():cross(veh:getDirectionVector()):normalized()
    camPos = veh:getPosition() + side * 2.2 + vec3(0, 0, 1.5)
  end
  local feetZ = groundBelow(camPos)
  local mx, my, mz = coords.bngToMc(camPos.x, camPos.y, feetZ + 0.05)
  local yaw = math.atan2(fwdv.x, fwdv.y)
  local mcYaw = coords.bngLookToMc(yaw, 0)
  terrain.reset()
  prevSnap = nil
  net.send({ t = 'enter', x = mx, y = my, z = mz, yaw = mcYaw })
  -- prime the camera where Steve will appear, so there is no flash
  curSnap = { x = mx, y = my, z = mz, eye = 1.62, at = now, by = mcYaw, hy = mcYaw }
  active = true
  entering = false
  core_camera.setByName(0, 'beamcraft', false)
  local cam = core_camera.getGlobalCameras and core_camera.getGlobalCameras()['beamcraft']
  if cam then cam.yaw, cam.pitch = yaw, 0 end
  hideBeamNGUi(true)
  pushOverlayState()
end

function M.exit()
  if not active then return end
  active = false
  setScreenOpen(false)
  if setCEFTyping then setCEFTyping(false) end
  net.send({ t = 'exit' })
  if lockMouse then lockMouse(false) end
  hideBeamNGUi(false)
  pushOverlayState()
  -- you're about to drive: make what you built solid now (one hitch, during the switch)
  world.rebuildCollisionNow()
  -- back to the vehicle camera if there is a vehicle, else the free camera
  if getPlayerVehicle(0) then
    core_camera.setByName(0, nil)
  else
    core_camera.setByName(0, 'free')
  end
end

function M.toggle()
  if active then M.exit() else M.enter() end
end

function M.isActive() return active end

------------------------------------------------------------------------------
-- incoming
------------------------------------------------------------------------------

local handlers = {}

handlers.welcome = function(m)
  mcInfo = m
  log('I', 'beamcraft', 'Minecraft ' .. tostring(m.mc) .. ', world ' .. tostring(m.world))
end

handlers.ready = function(m)
  ready = true
  mcInfo.world = m.world
  if entering then M.enter() end
end

handlers.unready = function(m)
  ready = false
  if active then M.exit() end
  entities.clear()
end

handlers.atlas = function(m) world.setAtlas(m) end
handlers.states = function(m) world.defineStates(m) end
handlers.blocks = function(m) world.setBlocks(m) end
handlers.clear = function(m) world.clear() terrain.reset() entities.clear() end
handlers.gui = function(m)
  hud.gui = m
  player.setSkin(m.dir, m.slim)
end
handlers.icons = function(m) hud.iconsDir = m.dir end
handlers.ents = function(m) entities.snapshot(m, now, ctx) end
handlers.boom = function(m) vehicles.explode(m.x, m.y, m.z, m.r or 4, now) end

handlers.p = function(m)
  prevSnap = curSnap
  m.at = now
  m.eye = m.eye or 1.62
  curSnap = m
  if prevSnap then
    -- teleports (respawn, /tp) should snap, not glide
    local dx, dy, dz = curSnap.x - prevSnap.x, curSnap.y - prevSnap.y, curSnap.z - prevSnap.z
    if dx * dx + dy * dy + dz * dz > 100 then prevSnap = nil end
  end
  target = m.tgt
  if active then
    setScreenOpen(m.scr == 1)
    M.cameraMode = m.cam or 0
    M.thirdPerson = M.cameraMode ~= 0
  end
end

handlers.hud = function(m) hudState = m end
handlers.items = function(m) hud.items = { blocks = m.blocks or {}, other = m.other or {} } end
handlers.chat = function(m) log('I', 'beamcraft', 'chat: ' .. tostring(m.m)) end
handlers.look = function(m)
  local cam = core_camera.getGlobalCameras and core_camera.getGlobalCameras()['beamcraft']
  if cam then cam.yaw, cam.pitch = coords.mcLookToBng(m.yaw, m.pitch) end
end

local function handle(msg)
  local h = handlers[msg.t]
  if h then
    local ok, err = pcall(h, msg)
    if not ok then log('E', 'beamcraft', 'handler ' .. tostring(msg.t) .. ' failed: ' .. tostring(err)) end
  end
end

------------------------------------------------------------------------------
-- frame
------------------------------------------------------------------------------

world.onBlockChanged = function(x, y, z) terrain.invalidateBlock(x, y, z) end

-- Collision rebuilds hitch the game, so only do them when a car needs them: while you
-- drive, or when a moving car is heading for blocks that changed. Never just because
-- Steve placed a block (Minecraft handles his collision).
world.shouldRebuildCollision = function(centres)
  if not active then return true end
  local need = false
  for _, veh in ipairs(getAllVehicles()) do
    local v = veh:getVelocity()
    local speed = v:length()
    if speed > 1.5 and veh:getJBeamFilename() ~= 'unicycle' then
      local p = veh:getPosition()
      local reach = 15 + speed * 2.5
      for _, c in ipairs(centres) do
        if (c - p):length() < reach then need = true break end
      end
    end
    if need then break end
  end
  return need
end
world.onCollisionReloaded = function() terrain.invalidateAll() end

local inputTimer = 0

local function drawTarget()
  if not target then return end
  local x, y, z = target[1], target[2], target[3]
  local e = 0.003
  local bx0, by1, bz0 = coords.mcToBng(x - e, y - e, z - e)
  local bx1, by0, bz1 = coords.mcToBng(x + 1 + e, y + 1 + e, z + 1 + e)
  entities.boxLines(bx0, by0, bz0, bx1, by1, bz1, ColorF(0, 0, 0, 0.75))
end

local function statusLines()
  local lines = {}
  local conn = net.isConnected() and (ready and 'ready' or 'loading') or 'waiting for Minecraft'
  lines[1] = 'BeamCraft ' .. conn .. (active and '  [Steve]' or '  (Alt+B)')
  if net.isConnected() then
    lines[2] = string.format('blocks %d  sections %d  states %d  dirty %d',
      world.getTotalBlocks(), world.getSectionCount(), world.getStateCount(), world.getDirtyCount())
    lines[4] = string.format('overlay patches %d (%.1f MB)', overlay.patches, overlay.bytes / 1048576)
    lines[3] = string.format('collision %s, last rebuild %s ms (x%d)',
      world.hasPendingCollision() and 'pending' or 'up to date',
      world.lastCollisionMs and string.format('%.0f', world.lastCollisionMs) or '-', world.collisionReloads)
  end
  return lines
end

local function onUpdate(dtReal, dtSim, dtRaw)
  now = now + dtReal
  hud.now = now
  devconsole.update()

  local msgs = net.update(dtReal, function()
    ready = false
    sendHello()
  end, function()
    ready = false
    if active then M.exit() end
    entities.clear()
  end)
  for i = 1, #msgs do handle(msgs[i]) end

  world.update(dtReal)
  overlay.update(dtReal, active and net.isConnected())

  viewportTimer = viewportTimer + dtReal
  if viewportTimer > 1 and net.isConnected() then
    viewportTimer = 0
    local w, h = viewportSize()
    if w > 0 and (w ~= viewport.w or h ~= viewport.h) then
      viewport.w, viewport.h = w, h
      net.send({ t = 'viewport', vw = w, vh = h })
    end
    pushOverlayState()
  end

  local pose = poseNow()
  -- Steve stays visible standing where you left him while you drive
  player.visibleThird = ready and pose ~= nil and (M.thirdPerson or not active)
  player.visibleFirst = false
  player.updateThird(pose, ctx)
  entities.update(now)
  vehicles.drawFlashes(now)

  if active and net.isConnected() and pose then
    local fx, fy, fz = pose.x, pose.y, pose.z
    -- terrain under Steve
    local ter = terrain.update(fx, fy, fz)
    if ter then net.send(ter) end

    -- cars: solid to Steve (10 Hz), and they hurt
    local feetB = vec3(coords.mcToBng(fx, fy, fz))
    vehTimer = vehTimer + dtReal
    if vehTimer > 0.1 then
      vehTimer = 0
      net.send({ t = 'veh', b = vehicles.collisionBoxes(feetB) })
    end
    local hurt = vehicles.checkHits(now, feetB)
    if hurt then net.send(hurt) end

    -- input: on change, and at least 20 Hz so Minecraft never acts on stale state
    inputTimer = inputTimer + dtReal
    if inputDirty or inputTimer > 0.05 or #events > 0 then
      inputTimer = 0
      inputDirty = false
      local msg = {
        t = 'in',
        f = input.f, b = input.b, l = input.l, r = input.r,
        j = input.jump, s = input.sneak, sp = input.sprint,
        at = input.attack, us = input.use,
        yaw = input.yaw, pitch = input.pitch,
      }
      if #events > 0 then msg.ev = events events = {} end
      -- where the crosshair meets BeamNG's world, for placing blocks on the ground
      local eye, dir = lookRay()
      if eye then
        local aim = terrain.aim(eye, dir, 6)
        if aim then msg.aim = aim end
      end
      net.send(msg)
    end
    drawTarget()
  end

  hud.drawStatus(statusLines())
end

local function onExtensionLoaded()
  -- a reload whose unload failed leaves meshes behind: sweep anything of ours
  local n = 0
  for _, name in ipairs(scenetree.findClassObjects('ProceduralMesh') or {}) do
    if name:find('^beamcraft_') then
      local o = scenetree.findObject(name)
      if o then o:delete() n = n + 1 end
    end
  end
  log('I', 'beamcraft', 'BeamCraft loaded' .. (n > 0 and (' (removed ' .. n .. ' stale meshes)') or ''))
end

local function onExtensionUnloaded()
  if active then M.exit() end
  world.clear()
  entities.clear()
  player.destroy()
  net.close('extension unloaded')
  overlay.close()
  devconsole.close()
end

local function onClientStartMission()
  -- new level: Minecraft swaps to that level's world
  world.clear()
  terrain.reset()
  entities.clear()
  player.destroy()
  if hud.gui then player.setSkin(hud.gui.dir, hud.gui.slim) end
  ready = false
  curSnap, prevSnap = nil, nil
  if net.isConnected() then sendHello() end
end

local function onClientEndMission()
  if active then M.exit() end
  world.clear()
  entities.clear()
  player.destroy()
  ready = false
  curSnap, prevSnap = nil, nil
  if net.isConnected() then
    net.send({ t = 'leave' })
    sendHello() -- level is now 'none': Minecraft leaves the world
  end
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission

-- console helpers
M.world = world
M.terrain = terrain
M.net = net
M.hud = hud
M.player = player
M.entities = entities
M.vehicles = vehicles
M.meshutil = mu

return M
