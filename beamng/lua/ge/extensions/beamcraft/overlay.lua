-- Relay for Minecraft's GUI frames: BeamNG's Chromium UI can't open network
-- connections itself, so Lua reads the frame patches from the hidden Minecraft
-- (raw mode of its overlay server, 127.0.0.1:47802) and hands each one to the UI page
-- (ui/modModules/beamcraft) untouched, via guihooks.triggerRawJS.
--
-- Pull model with end-to-end backpressure: we ask Minecraft for one frame (a byte on
-- the socket), it answers with one message holding every changed patch of that frame:
-- u32 little-endian length, then '[["fullW,fullH,x,y,w,h|<base64>", ...]]' - already the
-- JS hook's argument list, queued for the page as-is. The page acks once it has painted
-- (beamcraft_main.overlayAck), and only then do we ask for the next frame. Nothing can
-- pile up anywhere, so the overlay always shows the newest frame BeamNG can keep up with.

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
local waiting = nil -- 'mc' while a frame is requested, 'page' while the page paints
local waitTime = 0
M.frames = 0

local function close()
  if sock then pcall(function() sock:close() end) end
  sock = nil
  inbuf:reset()
  need = nil
  waiting = nil
end
M.close = close

-- the page painted the last frame
function M.ack()
  if waiting == 'page' then waiting = nil end
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
  waiting = nil
  return true
end

-- enabled: only pull frames while Steve is being played (Minecraft renders the
-- overlay only while someone is watching)
function M.update(dt, enabled)
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
    if frame ~= '[[]]' then
      M.patches = M.patches + 1
      be:queueHookJS('BeamCraftFrame', frame, 0)
      waiting, waitTime = 'page', 0
    else
      waiting = nil -- nothing changed: ask again right away
    end
  end

  -- recover if an ack or a frame got lost (e.g. the page reloaded)
  if waiting then
    waitTime = waitTime + dt
    if waitTime > 0.5 then waiting = nil end
  end
  if sock and not waiting then
    sock:send('N')
    waiting, waitTime = 'mc', 0
  end
end

return M
