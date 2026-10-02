-- BeamCraft: play Minecraft Java Edition inside BeamNG.drive.
--
-- A hidden Minecraft client (Fabric mod) runs the player: movement physics,
-- inventory, block placing and breaking, health. BeamNG renders everything and
-- supplies the world: it raycasts its terrain into Minecraft's collision, forwards
-- your input, and meshes the blocks Minecraft reports. This extension is the glue.
--
-- Toggle with Alt+B (or beamcraft_main.toggle() in the console).

local M = {}
M.dependencies = { 'ui_imgui', 'core_camera' }

local coords = require('beamcraft/coords')
local net = require('beamcraft/net')
local world = require('beamcraft/world')
local terrain = require('beamcraft/terrain')
local hud = require('beamcraft/hud')
local devconsole = require('beamcraft/devconsole')

M.thirdPerson = false

local now = 0
local active = false          -- BeamCraft camera/controls engaged
local ready = false           -- Minecraft has a world loaded for this level
local mcInfo = {}             -- from 'welcome'
local hudState = nil
local target = nil            -- block the crosshair is on, MC coords
local prevSnap, curSnap = nil, nil
local lastStatusLog = 0
local entering = false

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

local function sendHello()
  net.send({
    t = 'hello', v = 1,
    level = levelId(),
    userPath = FS:getUserPath(),
  })
end

function M.setMoveInput(f, b, l, r)
  if hud.pickerOpen then return end
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

local function setPicker(open)
  hud.pickerOpen = open
  if lockMouse then lockMouse(not open) end
  if open then
    -- let go of everything so Steve doesn't keep walking while you browse
    input.f, input.b, input.l, input.r = 0, 0, 0, 0
    input.jump, input.sneak, input.sprint, input.attack, input.use = 0, 0, 0, 0, 0
    inputDirty = true
  end
end

hud.onPick = function(id) net.send({ t = 'give', id = id }) end
hud.onClose = function() setPicker(false) end

function M.isPickerOpen() return hud.pickerOpen end

-- run a Minecraft command as Steve, e.g. beamcraft_main.cmd('gamemode survival')
function M.cmd(str) net.send({ t = 'cmd', c = str }) end

function M.key(name, value)
  if not active then return end
  local v = (value or 0) > 0.5 and 1 or 0
  if name == 'inventory' then
    if v == 1 then setPicker(not hud.pickerOpen) end
    return
  end
  if hud.pickerOpen then return end
  if name == 'jump' or name == 'sneak' or name == 'sprint' or name == 'attack' or name == 'use' then
    if input[name] ~= v then
      input[name] = v
      inputDirty = true
      -- attack/use also need a click event, Minecraft counts presses separately
      if (name == 'attack' or name == 'use') and v == 1 then events[#events + 1] = { k = name } end
    end
  elseif v == 1 then
    events[#events + 1] = { k = name }
  end
end

function M.slot(n)
  if active and not hud.pickerOpen then events[#events + 1] = { k = 'slot', n = n } end
end

function M.scroll(value)
  if active and value and value ~= 0 then
    events[#events + 1] = { k = 'scroll', n = value > 0 and -1 or 1 }
  end
end

function M.togglePerspective() M.thirdPerson = not M.thirdPerson end

------------------------------------------------------------------------------
-- player pose
------------------------------------------------------------------------------

local eyeOut = vec3()
local interval = 0.05

-- interpolated eye position in BeamNG coords, or nil before the first snapshot
function M.getEyePos()
  if not curSnap then return nil end
  local a = 1
  if prevSnap then a = clamp((now - curSnap.at) / interval, 0, 1) end
  local p = prevSnap or curSnap
  local x = p.x + (curSnap.x - p.x) * a
  local y = p.y + (curSnap.y - p.y) * a
  local z = p.z + (curSnap.z - p.z) * a
  local eye = p.eye + (curSnap.eye - p.eye) * a
  local bx, by, bz = coords.mcToBng(x, y + eye, z)
  eyeOut:set(bx, by, bz)
  return eyeOut
end

local function feetMc()
  if curSnap then return curSnap.x, curSnap.y, curSnap.z end
  return nil
end

------------------------------------------------------------------------------
-- mode switching
------------------------------------------------------------------------------

function M.onCameraFocus(focused)
  if focused then
    if lockMouse then lockMouse(true) end
  else
    if lockMouse then lockMouse(false) end
    if active then
      active = false
      net.send({ t = 'exit' })
    end
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
    hud.addChat('BeamCraft: Minecraft is not running (start tools/run_backend.sh)')
    return
  end
  if not ready then
    hud.addChat('BeamCraft: Minecraft is still loading the world...')
    entering = true
    return
  end
  local camPos = core_camera.getPosition()
  local fwdv = core_camera.getForward()
  local feetZ = groundBelow(camPos)
  local mx, my, mz = coords.bngToMc(camPos.x, camPos.y, feetZ + 0.05)
  local yaw = math.atan2(fwdv.x, fwdv.y)
  local mcYaw = coords.bngLookToMc(yaw, 0)
  terrain.reset()
  prevSnap, curSnap = nil, nil
  net.send({ t = 'enter', x = mx, y = my, z = mz, yaw = mcYaw })
  -- prime the camera where Steve will appear, so there is no flash
  curSnap = { x = mx, y = my, z = mz, eye = 1.62, at = now }
  active = true
  entering = false
  core_camera.setByName(0, 'beamcraft', false)
  local cam = core_camera.getGlobalCameras and core_camera.getGlobalCameras()['beamcraft']
  if cam then
    cam.yaw, cam.pitch = yaw, 0
  end
  hud.addChat('BeamCraft: you are Steve. Alt+B to leave.')
end

function M.exit()
  if not active then return end
  active = false
  hud.pickerOpen = false
  net.send({ t = 'exit' })
  if lockMouse then lockMouse(false) end
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
  log('I', 'beamcraft', 'Minecraft says hello: ' .. dumps(m))
end

handlers.ready = function(m)
  ready = true
  mcInfo.world = m.world
  hud.addChat('BeamCraft: world "' .. tostring(m.world) .. '" ready')
  if entering then M.enter() end
end

handlers.unready = function(m)
  ready = false
  if active then M.exit() end
end

handlers.atlas = function(m) world.setAtlas(m) end
handlers.states = function(m) world.defineStates(m) end
handlers.blocks = function(m) world.setBlocks(m) end
handlers.clear = function(m) world.clear() terrain.reset() end

handlers.p = function(m)
  prevSnap = curSnap
  curSnap = { x = m.x, y = m.y, z = m.z, eye = m.eye or 1.62, at = now }
  if prevSnap then
    -- teleports (respawn, /tp) should snap, not glide
    local dx, dy, dz = curSnap.x - prevSnap.x, curSnap.y - prevSnap.y, curSnap.z - prevSnap.z
    if dx * dx + dy * dy + dz * dz > 100 then prevSnap = nil end
  end
  target = m.tgt
end

handlers.hud = function(m) hudState = m end
handlers.items = function(m) hud.items = { blocks = m.blocks or {}, other = m.other or {} } end
handlers.chat = function(m) hud.addChat(m.m) end
handlers.look = function(m)
  -- Minecraft changed our look (teleport/respawn): adopt it
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
world.onCollisionReloaded = function() terrain.invalidateAll() end

local inputTimer = 0

local function drawTarget()
  if not target then return end
  local x, y, z = target[1], target[2], target[3]
  local c = ColorF(0, 0, 0, 0.9)
  local function p(dx, dy, dz)
    local bx, by, bz = coords.mcToBng(x + dx, y + dy, z + dz)
    return vec3(bx, by, bz)
  end
  local e = 0.002
  local a0, a1 = -e, 1 + e
  local corners = {
    p(a0, a0, a0), p(a1, a0, a0), p(a1, a0, a1), p(a0, a0, a1),
    p(a0, a1, a0), p(a1, a1, a0), p(a1, a1, a1), p(a0, a1, a1),
  }
  local edges = { {1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8} }
  for _, ed in ipairs(edges) do
    debugDrawer:drawLine(corners[ed[1]], corners[ed[2]], c)
  end
end

local function statusLines()
  local lines = {}
  local conn = net.isConnected() and (ready and 'ready' or 'loading') or 'waiting for Minecraft'
  lines[1] = 'BeamCraft ' .. conn .. (active and '  [Steve]' or '  (Alt+B)')
  if net.isConnected() then
    lines[2] = string.format('blocks %d  sections %d  states %d  dirty %d',
      world.getTotalBlocks(), world.getSectionCount(), world.getStateCount(), world.getDirtyCount())
    if world.lastCollisionMs then
      lines[3] = string.format('collision rebuild %.1f ms (x%d)  rays %d', world.lastCollisionMs, world.collisionReloads, terrain.raysLastFrame)
    end
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
  end)
  for i = 1, #msgs do handle(msgs[i]) end

  world.update(dtReal)

  if active and net.isConnected() then
    -- terrain under Steve
    local fx, fy, fz = feetMc()
    if fx then
      local ter = terrain.update(fx, fy, fz)
      if ter then net.send(ter) end
    end

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
      local eye = M.getEyePos()
      if eye then
        local dx, dy, dz = coords.mcLookDirBng(input.yaw, input.pitch)
        local aim = terrain.aim(vec3(eye), vec3(dx, dy, dz), 6)
        if aim then msg.aim = aim end
      end
      net.send(msg)
    end
    drawTarget()
  end

  hud.draw({ active = active, hud = hudState, status = statusLines() })
end

local function onExtensionLoaded()
  log('I', 'beamcraft', 'BeamCraft loaded')
end

local function onExtensionUnloaded()
  if active then M.exit() end
  world.clear()
  net.close('extension unloaded')
  devconsole.close()
end

local function onClientStartMission()
  -- new level: Minecraft swaps to that level's world
  world.clear()
  terrain.reset()
  ready = false
  if net.isConnected() then sendHello() end
end

local function onClientEndMission()
  if active then M.exit() end
  world.clear()
  ready = false
  if net.isConnected() then net.send({ t = 'leave' }) end
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

return M
