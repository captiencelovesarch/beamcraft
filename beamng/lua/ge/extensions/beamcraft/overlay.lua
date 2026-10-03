-- Relay for Minecraft's GUI frames: Lua reads the frame patches from the hidden Minecraft
-- (raw mode of its overlay server, 127.0.0.1:47802) and hands each one to the UI page
-- (ui/modModules/beamcraft) untouched, directly into the canvas renderer.
--
-- Pull model with a three-frame window: we ask Minecraft for a frame (a byte on
-- the socket), it answers with one message holding every changed patch of that frame:
-- u32 little-endian length, then '[["fullW,fullH,x,y,w,h|<base64>", ...]]' - already the
-- JS hook's argument list, queued for the page as-is. The page acks once it has painted.
-- We decode ahead while a previous frame is in the UI queue, avoiding an entire
-- round trip of idle time without allowing an unbounded backlog.

local socket = require('socket.socket')
local sbuf = require('string.buffer')

local M = {}

M.port = 47802
M.patches = 0
M.bytes = 0

local sock
local inbuf = sbuf.new()
local need = nil   -- length of the patch being read, once its header has arrived
local retry = 0
local mcPending = 0
local pagePending = 0
local waitTime = 0
local WINDOW = 3
M.frames = 0
local refreshOwner, savedRefresh
local refreshTimer = 0

-- BeamNG normally limits its main browser to 30 FPS. Its supported maximum is
-- 60 FPS (requests above 60 are clamped by the engine). Raise it while this HUD
-- is visible, and restore the user's previous rate when leaving Minecraft.
function M.setVisible(enabled)
  local cef = scenetree.maincef
  if refreshOwner and (not enabled or cef ~= refreshOwner) then
    pcall(function() refreshOwner:setMaxFPSLimit(savedRefresh) end)
    refreshOwner, savedRefresh = nil, nil
  end
  if enabled and cef then
    if not refreshOwner then
      local ok, rate = pcall(function() return cef:getMaxFPSLimit() end)
      if not ok then return end
      refreshOwner, savedRefresh = cef, math.floor(rate + 0.5)
    end
    cef:setMaxFPSLimit(60)
    M.browserCap = 60
  else
    M.browserCap = nil
  end
end

local function close()
  if sock then pcall(function() sock:close() end) end
  sock = nil
  inbuf:reset()
  need = nil
  mcPending = 0
  pagePending = 0
end
M.close = close
function M.shutdown()
  close()
  M.setVisible(false)
end

-- the page painted the last frame
function M.ack(n)
  n = math.max(1, math.min(WINDOW, tonumber(n) or 1))
  pagePending = math.max(0, pagePending - n)
  M.painted = (M.painted or 0) + n
end

local function connect()
  local s = socket.tcp()
  s:settimeout(0.05)
  if not s:connect('127.0.0.1', M.port) then
    s:close()
    return false
  end
  s:settimeout(0)
  s:setoption('tcp-nodelay', true)
  s:send('BCRAW')
  sock = s
  inbuf:reset()
  need = nil
  mcPending = 0
  pagePending = 0
  return true
end

-- enabled: only pull frames while Steve is being played (Minecraft renders the
-- overlay only while someone is watching)
function M.update(dt, enabled)
  refreshTimer = refreshTimer - dt
  if enabled ~= (refreshOwner ~= nil) or refreshTimer <= 0 then
    M.setVisible(enabled)
    refreshTimer = 1
  end
  if not enabled then
    if sock then close() end
    return
  end
  if not sock then
    retry = retry - dt
    if retry > 0 then return end
    retry = 1
    if not connect() then return end
  end

  while true do
    local data, err, partial = sock:receive(1048576)
    local chunk = data or partial
    if chunk and #chunk > 0 then inbuf:put(chunk) end
    if err == 'closed' then close() return end
    if err then break end
  end

  while true do
    if not need then
      if #inbuf < 4 then break end
      local b1, b2, b3, b4 = string.byte(inbuf:get(4), 1, 4)
      need = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end
    if #inbuf < need then break end
    local frame = inbuf:get(need)
    M.bytes = M.bytes + need
    need = nil
    M.frames = M.frames + 1
    mcPending = math.max(0, mcPending - 1)
    if frame ~= '[[]]' then
      M.patches = M.patches + 1
      be:executeJS('window.beamcraftOverlay && window.beamcraftOverlay.frame((' .. frame .. ')[0]);')
      pagePending = pagePending + 1
    end
    waitTime = 0
  end

  -- recover if a frame or UI ack got lost (e.g. the page reloaded)
  if mcPending > 0 or pagePending >= WINDOW then
    waitTime = waitTime + dt
    if waitTime > 0.5 then
      if mcPending > 0 then close() return end
      pagePending = 0
      waitTime = 0
    end
  end
  while sock and mcPending + pagePending < WINDOW do
    local sent, err = sock:send('N')
    if not sent then close() return end
    mcPending = mcPending + 1
    waitTime = 0
  end
end

return M
