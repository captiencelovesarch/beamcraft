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
local items = require('beamcraft/items')
local particles = require('beamcraft/particles')
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
local frames, frameTime = 0, 0

-- Per-subsystem frame cost (ms). beamcraft_main.prof() from the dev console returns
-- { name = {avg, max, calls} } over the frames since the last call, plus BeamNG's fps.
local profT = hptimer and hptimer() or nil
local prof = {}
local profFrames = 0
local function pmark(name, t0)
  local dt = profT:stop() - t0
  local e = prof[name]
  if not e then e = { sum = 0, max = 0, n = 0 } prof[name] = e end
  e.sum, e.n = e.sum + dt, e.n + 1
  if dt > e.max then e.max = dt end
  return profT:stop()
end
function M.prof()
  local out = { frames = profFrames, fps = M.fps }
  for name, e in pairs(prof) do
    out[name] = string.format('avg %.2f  max %.2f  n %d', e.sum / math.max(1, profFrames), e.max, e.n)
  end
  prof, profFrames = {}, 0
  return out
end

local ctx = { world = world, iconPath = hud.iconPath, items = items }

local input = {
  f = 0, b = 0, l = 0, r = 0,
  jump = 0, sneak = 0, sprint = 0, attack = 0, use = 0,
  yaw = 0, pitch = 0,
}
local inputDirty = true
local events = {}             -- one-shot key events to send this frame

-- Forget held buttons. Leaving BeamCraft (e.g. right-clicking a car to get in) pops
-- our action map before the button's release arrives, so without this the button
-- would still read as held when you come back.
local function releaseInput()
  input.f, input.b, input.l, input.r = 0, 0, 0, 0
  input.jump, input.sneak, input.sprint, input.attack, input.use = 0, 0, 0, 0, 0
  events = {}
  inputDirty = true
end

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

-- the overlay page painted a frame: Minecraft may send the next one
function M.overlayAck(n) overlay.ack(n) end
function M.overlayMetrics(fps, decodeMs, maxQueue)
  overlay.uiFps, overlay.decodeMs, overlay.maxQueue = fps, decodeMs, maxQueue
end
M.overlay = overlay

-- mouse/keyboard from the overlay page while a Minecraft screen is open, on to Minecraft
function M.overlayInput(json)
  local ok, e = pcall(jsonDecode, json)
  if ok and type(e) == 'table' then net.send({ t = 'oin', e = e }) end
end

-- the overlay page (ui/modModules/beamcraft) asks for this, and gets pushed changes
function M.overlayState()
  local w, h = overlay.size()
  return { visible = active, interactive = active and screenOpen, w = w, h = h }
end

local function pushOverlayState()
  local st = M.overlayState()
  local key = tostring(st.visible) .. tostring(st.interactive) .. st.w .. 'x' .. st.h
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

local function partRotation(part)
  return mu.qmul(mu.qaxis(0, 0, 1, part[6]),
    mu.qmul(mu.qaxis(0, 1, 0, part[5]), mu.qaxis(1, 0, 0, part[4])))
end

local function lerpPose(poseA, poseB, t)
  if not poseB then return nil end
  if not poseA then return poseB end
  local result = {}
  for name, part in pairs(poseB) do
    local old = poseA[name] or part
    local values = {}
    for i = 1, 3 do values[i] = old[i] + (part[i] - old[i]) * t end
    -- ModelPart Euler angles can flip at the cape's half turn. Interpolate the
    -- equivalent quaternion along its shortest arc instead.
    local qa, qb = partRotation(old), partRotation(part)
    local dot = qa[1] * qb[1] + qa[2] * qb[2] + qa[3] * qb[3] + qa[4] * qb[4]
    if dot < 0 then for i = 1, 4 do qb[i] = -qb[i] end end
    local q = {}
    local norm = 0
    for i = 1, 4 do q[i] = qa[i] + (qb[i] - qa[i]) * t norm = norm + q[i] * q[i] end
    norm = math.sqrt(norm)
    for i = 1, 4 do values[i + 6] = q[i] / norm end
    result[name] = values
  end
  return result
end

-- body tilt (elytra, swimming...): {qx,qy,qz,qw, tx,ty,tz}, nil = upright
local function lerpTilt(ta, tb, t)
  if not ta and not tb then return nil end
  ta, tb = ta or { 0, 0, 0, 1, 0, 0, 0 }, tb or { 0, 0, 0, 1, 0, 0, 0 }
  local sg = (ta[1] * tb[1] + ta[2] * tb[2] + ta[3] * tb[3] + ta[4] * tb[4]) < 0 and -1 or 1
  local r, n = {}, 0
  for i = 1, 4 do r[i] = ta[i] + (tb[i] * sg - ta[i]) * t n = n + r[i] * r[i] end
  n = math.sqrt(n)
  for i = 1, 4 do r[i] = r[i] / n end
  for i = 5, 7 do r[i] = ta[i] + (tb[i] - ta[i]) * t end
  return r
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
    fps = c.fps, fpsCap = c.fpsCap, configuredCap = c.configuredCap,
    sw = c.sw, cr = c.cr, held = c.held, hs = c.hs, ir = c.ir, il = c.il,
    m = lerpPose(p.m, c.m, a),
    bt = lerpTilt(p.bt, c.bt, a),
  }
end
M.poseNow = poseNow
function M.lastPose() return curSnap end

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
  M.inCar = false
  releaseInput()
  net.send({ t = 'enter', x = mx, y = my, z = mz, yaw = mcYaw })
  -- prime the camera where Steve will appear, so there is no flash
  curSnap = { x = mx, y = my, z = mz, eye = 1.62, at = now, by = mcYaw, hy = mcYaw }
  -- switch camera first: if it was already ours (e.g. after a Lua reload), switching
  -- fires our own "camera lost focus" exit, which must not undo this enter
  core_camera.setByName(0, 'beamcraft', false)
  active = true
  overlay.setVisible(true)
  entering = false
  if lockMouse then lockMouse(true) end
  pushActionMapHighestPriority('BeamCraft')
  local cam = core_camera.getGlobalCameras and core_camera.getGlobalCameras()['beamcraft']
  if cam then cam.yaw, cam.pitch = yaw, 0 end
  hideBeamNGUi(true)
  pushOverlayState()
end

function M.exit()
  if not active then return end
  active = false
  overlay.setVisible(false)
  setScreenOpen(false)
  if setCEFTyping then setCEFTyping(false) end
  releaseInput()
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
  particles.clear()
end

handlers.atlas = function(m) world.setAtlas(m) end
handlers.states = function(m) world.defineStates(m) end
handlers.blocks = function(m) world.setBlocks(m) end
handlers.clear = function(m) world.clear() terrain.reset() entities.clear() particles.clear() end
handlers.gui = function(m)
  hud.gui = m
  player.setSkin(m.dir, m.slim, m.skin, m.overlays, m.skinMask, m.cape)
end
handlers.icons = function(m) hud.iconsDir = m.dir end
handlers.ents = function(m) entities.snapshot(m, now, ctx) end
handlers.itemModel = function(m) items.define(m) end
handlers.particles = function(m) particles.snapshot(m, now) end
handlers.mobModel = function(m) entities.defineModel(m) end

-- Textures to load ahead of use (every particle sprite). BeamNG converts a texture
-- to DDS the first time a material draws it and shows a placeholder meanwhile, so we
-- draw them all once, tiny, right in front of the camera for a few seconds.
-- (The converted files stay in BeamNG's temp cache across sessions.)
local warm
handlers.warm = function(m)
  if warm then mu.deleteObject(warm.obj) warm = nil end
  local meshes = {}
  for i, pair in ipairs(m.l or {}) do
    local mat = mu.textureMaterial('bc_warm_' .. pair[1]:gsub('[^%w]', '_'), pair[1], 'translucent', nil, pair[2], true)
    local mesh = mu.newMesh(mat)
    local x = (i % 20) * 0.002 - 0.02
    local z = math.floor(i / 20) * 0.002 - 0.02
    mu.addQuad(mesh, { x, 0, z + 0.0015 }, { x + 0.0015, 0, z + 0.0015 }, { x + 0.0015, 0, z }, { x, 0, z }, 0, 0, 1, 1, 0, -1, 0)
    meshes[#meshes + 1] = mesh
  end
  if #meshes == 0 then return end
  mu.flushMaterials()
  warm = { obj = mu.newObject('beamcraft_warm', meshes), untilT = now + 6 }
  log('I', 'beamcraft', 'warming ' .. #meshes .. ' particle textures')
end
local function updateWarm()
  if not warm then return end
  if now > warm.untilT then mu.deleteObject(warm.obj) warm = nil return end
  local cam, fwd = core_camera.getPosition(), core_camera.getForward()
  local p = cam + fwd * 0.35
  local yaw = math.atan2(fwd.x, fwd.y)
  mu.setXform(warm.obj, p.x, p.y, p.z, mu.qaxis(0, 0, 1, -yaw))
end

-- a Minecraft sound BeamNG should play (e.g. a mob your car hit, far from Steve)
local sounds = {}
handlers.sound = function(m)
  local id = Engine.Audio.createSource('AudioDefault3D', m.f)
  local src = id and scenetree.findObjectById(id)
  if not src then return end
  local mat = MatrixF(true)
  mat:setColumn(3, vec3(coords.mcToBng(m.x, m.y, m.z)))
  src:setTransform(mat)
  if src.setVolume then src:setVolume(math.min(1, m.v or 1)) end
  if src.setPitch then src:setPitch(m.p or 1) end
  src:play(-1)
  sounds[#sounds + 1] = { src = src, at = now }
end
local function reapSounds()
  for i = #sounds, 1, -1 do
    local s = sounds[i]
    if now - s.at > 6 then
      pcall(function() s.src:delete() end)
      table.remove(sounds, i)
    end
  end
end
-- Minecraft wants to spawn a mob here: tell it where the ground is
handlers.probe = function(m)
  local ter = terrain.around(m.x, m.y, m.z, 1.5, 24, 64)
  if ter then net.send(ter) end
end
handlers.vehHit = function(m)
  local eye = M.getEyePos()
  vehicles.hit(m, now, eye and vec3(eye) or nil)
end
handlers.vehUse = function(m)
  local veh = scenetree.findObjectById(m.id)
  if active and veh and veh:getJBeamFilename() ~= 'unicycle' then
    M.exit()
    be:enterVehicle(0, veh)
    M.inCar = true -- Steve got in: don't leave him standing outside
  end
end
handlers.boom = function(m)
  if m.wind then vehicles.gust(m.x, m.y, m.z, m.r or 1.2) else vehicles.explode(m.x, m.y, m.z, m.r or 4, now) end
end

handlers.p = function(m)
  if m.armorModel then player.setArmor(m.armorModel) end
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
    local t0 = profT:stop()
    local ok, err = pcall(h, msg)
    if not ok then log('E', 'beamcraft', 'handler ' .. tostring(msg.t) .. ' failed: ' .. tostring(err)) end
    pmark('msg.' .. tostring(msg.t), t0)
  end
end

------------------------------------------------------------------------------
-- frame
------------------------------------------------------------------------------

world.onBlockChanged = function(x, y, z) terrain.invalidateBlock(x, y, z) end

-- Never leave edited geometry solid indefinitely. World coalesces changes with a
-- bounded delay, and entering a car drains all queued meshes before rebuilding.
terrain.withoutBlocks = world.withoutCollision
world.onCollisionReloaded = function() terrain.invalidateAll() end

local inputTimer = 0
local mobGroundTimer = 0
local mobGroundQueue, mobGroundIdx = {}, 1
M.mobGroundBudgetMs = 1.5
local camTimer = 0
local obstacleTimer = 0

local function drawTarget()
  if not target then return end
  local x, y, z = target[1], target[2], target[3]
  local e = 0.006
  local bx0, by1, bz0 = coords.mcToBng(x - e, y - e, z - e)
  local bx1, by0, bz1 = coords.mcToBng(x + 1 + e, y + 1 + e, z + 1 + e)
  entities.boxLines(bx0, by0, bz0, bx1, by1, bz1, ColorF(0, 0, 0, 0.75), true)
end

local function statusLines()
  local lines = {}
  local conn = net.isConnected() and (ready and 'ready' or 'loading') or 'waiting for Minecraft'
  lines[1] = 'BeamCraft ' .. conn .. (active and '  [Steve]' or '  (Alt+B)')
  if net.isConnected() then
    lines[2] = string.format('blocks %d  sections %d  states %d  dirty %d',
      world.getTotalBlocks(), world.getSectionCount(), world.getStateCount(), world.getDirtyCount())
    lines[4] = string.format('overlay frames %d, tiles %d  BeamNG %.0f fps, Minecraft %s fps', overlay.frames,
      overlay.tilesLoaded, M.fps or 0, tostring(curSnap and curSnap.fps or '?'))
    lines[3] = string.format('collision %s, last rebuild %s ms (x%d)',
      world.hasPendingCollision() and 'pending' or 'up to date',
      world.lastCollisionMs and string.format('%.0f', world.lastCollisionMs) or '-', world.collisionReloads)
  end
  return lines
end

local function onUpdate(dtReal, dtSim, dtRaw)
  now = now + dtReal
  hud.now = now
  profFrames = profFrames + 1
  local frameT0 = profT:stop()
  devconsole.update()
  local t0 = profT:stop()

  local msgs = net.update(dtReal, function()
    ready = false
    -- a (re)started Minecraft numbers its mob models afresh
    entities.clear()
    entities.forgetModels()
    -- a fresh Minecraft knows no ground yet: send every column again
    terrain.reset()
    sendHello()
  end, function()
    ready = false
    if active then M.exit() end
    entities.clear()
    particles.clear()
  end)
  t0 = pmark('net', t0)
  for i = 1, #msgs do handle(msgs[i]) end
  t0 = profT:stop()

  world.update(dtReal)
  t0 = pmark('world', t0)
  obstacleTimer = obstacleTimer + dtReal
  if obstacleTimer >= 0.1 then obstacleTimer = 0 vehicles.updateObstacles(world, now) end
  t0 = pmark('obstacles', t0)
  overlay.update(dtReal, active and net.isConnected())
  t0 = pmark('overlay.update', t0)

  frames, frameTime = frames + 1, frameTime + dtReal
  viewportTimer = viewportTimer + dtReal
  if viewportTimer > 1 and net.isConnected() then
    viewportTimer = 0
    -- Minecraft renders (and streams its overlay) at our frame rate, and shares our time of day
    if frameTime > 0 then
      M.fps = frames / frameTime
      net.send({ t = 'fps', fps = M.fps })
    end
    frames, frameTime = 0, 0
    local tod = core_environment and core_environment.getTimeOfDay and core_environment.getTimeOfDay()
    if tod and tod.time then net.send({ t = 'time', tod = tod.time }) end
    local w, h = viewportSize()
    if w > 0 and (w ~= viewport.w or h ~= viewport.h) then
      viewport.w, viewport.h = w, h
      net.send({ t = 'viewport', vw = w, vh = h })
    end
    pushOverlayState()
  end

  t0 = profT:stop()
  local pose = poseNow()
  -- Steve stays visible standing where you left him while you drive
  player.visibleThird = ready and pose ~= nil and not M.inCar and (M.thirdPerson or not active)
  player.visibleFirst = false
  player.updateThird(pose, ctx)
  t0 = pmark('player', t0)
  entities.showOwn = player.visibleThird
  entities.update(now)
  t0 = pmark('entities', t0)
  particles.update(now)
  t0 = pmark('particles', t0)

  if net.isConnected() and ready and pose then
    -- ground under the mobs, so they walk on BeamNG's world too (also while you
    -- drive). Rays start 4 m above a mob so one that has sunk into the ground still
    -- finds the real surface (Minecraft then lifts it back on top).
    -- Every mob is visited about 5 times a second, a few per frame under one shared
    -- ray budget, instead of all of them in the same frame (a 25-50 ms hitch in fights).
    mobGroundTimer = mobGroundTimer + dtReal
    if mobGroundTimer > 0.2 and mobGroundIdx > #mobGroundQueue then
      mobGroundTimer = 0
      mobGroundQueue, mobGroundIdx = entities.mobFeet(), 1
    end
    if mobGroundIdx <= #mobGroundQueue then
      local budget = hptimer()
      while mobGroundIdx <= #mobGroundQueue do
        local left = M.mobGroundBudgetMs - budget:stop()
        if left <= 0 then break end
        local feet = mobGroundQueue[mobGroundIdx]
        local mt, incomplete = terrain.around(feet[1], feet[2], feet[3], 7, 4, 80, left)
        if mt then net.send(mt) end
        if incomplete then break end -- this mob again next frame
        mobGroundIdx = mobGroundIdx + 1
      end
      t0 = pmark('mobGround', t0)
    end
    -- cars hitting mobs
    for _, hit in ipairs(vehicles.checkMobHits(now, entities.mobList())) do net.send(hit) end
    t0 = pmark('mobHits', t0)
    -- away from Steve, Minecraft hears from BeamNG's camera
    camTimer = camTimer + dtReal
    if not active and camTimer > 0.033 then
      camTimer = 0
      local cp, cf, cu = core_camera.getPosition(), core_camera.getForward(), core_camera.getUp()
      local x, y, z = coords.bngToMc(cp.x, cp.y, cp.z)
      local fx, fy, fz = coords.bngToMc(cf.x, cf.y, cf.z)
      local ux, uy, uz = coords.bngToMc(cu.x, cu.y, cu.z)
      net.send({ t = 'cam', x = x, y = y, z = z, fx = fx, fy = fy, fz = fz, ux = ux, uy = uy, uz = uz })
    end
    reapSounds()
  end

  if active and net.isConnected() and pose then
    local fx, fy, fz = pose.x, pose.y, pose.z
    -- terrain under Steve
    t0 = profT:stop()
    local ter = terrain.update(fx, fy, fz)
    if ter then net.send(ter) end
    t0 = pmark('terrain', t0)


    -- cars: solid to Steve (10 Hz), and they hurt
    local feetB = vec3(coords.mcToBng(fx, fy, fz))
    vehTimer = vehTimer + dtReal
    if vehTimer > 0.1 then
      vehTimer = 0
      local boxes, targets = vehicles.collisionBoxes(feetB)
      net.send({ t = 'veh', b = boxes, targets = targets })
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
      t0 = pmark('vehicles', t0)
      local eye, dir = lookRay()
      if eye then
        local aim = terrain.aim(eye, dir, 6)
        if aim then msg.aim = aim end
      end
      net.send(msg)
      t0 = pmark('aim', t0)
    end
    drawTarget()
  end

  t0 = profT:stop()
  updateWarm()
  if active then overlay.draw() end
  hud.drawStatus(statusLines())
  pmark('overlay.draw', t0)
  pmark('TOTAL', frameT0)
end

local function onExtensionLoaded()
  mu.cleanGenerated()
  -- a Lua reload can leave our action map pushed (it binds F5, E, 1-9...): drop it
  popActionMap('BeamCraft')
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
  particles.clear()
  player.destroy()
  net.close('extension unloaded')
  overlay.shutdown()
  devconsole.close()
end

local function onClientStartMission()
  -- new level: Minecraft swaps to that level's world
  world.clear()
  terrain.reset()
  entities.clear()
  particles.clear()
  player.destroy()
  if hud.gui then player.setSkin(hud.gui.dir, hud.gui.slim, hud.gui.skin, hud.gui.overlays, hud.gui.skinMask, hud.gui.cape) end
  ready = false
  curSnap, prevSnap = nil, nil
  if net.isConnected() then sendHello() end
end

local function onClientEndMission()
  if active then M.exit() end
  world.clear()
  entities.clear()
  particles.clear()
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
M.particlesMod = particles
M.vehicles = vehicles
M.meshutil = mu

return M
