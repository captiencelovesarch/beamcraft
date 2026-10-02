-- Newline-delimited JSON over a localhost TCP socket to the hidden Minecraft client.
-- Minecraft listens; BeamNG connects and retries every couple of seconds, so either
-- side can start (or Ctrl+L reload) first.

local socket = require('socket.socket')

local M = {}

M.host = '127.0.0.1'
M.port = 47800
M.retryInterval = 2.0

local sock
local inBuf = ''
local outBuf = ''
local outPos = 1
local retryTimer = 0
local stats = { rxBytes = 0, txBytes = 0, rxMsgs = 0, txMsgs = 0 }

M.stats = stats

function M.isConnected() return sock ~= nil end

local function close(reason)
  if sock then
    pcall(function() sock:close() end)
    log('I', 'beamcraft.net', 'disconnected: ' .. tostring(reason))
  end
  sock = nil
  inBuf, outBuf, outPos = '', '', 1
end
M.close = close

local function tryConnect()
  local s = socket.tcp()
  if not s then return false end
  s:settimeout(0.05) -- localhost: refused or accepted near-instantly
  local ok, err = s:connect(M.host, M.port)
  if not ok then
    s:close()
    return false, err
  end
  s:settimeout(0)
  s:setoption('tcp-nodelay', true)
  sock = s
  inBuf, outBuf, outPos = '', '', 1
  log('I', 'beamcraft.net', 'connected to Minecraft on ' .. M.host .. ':' .. M.port)
  return true
end

-- queue one message (a Lua table) for sending
function M.send(msg)
  if not sock then return false end
  local line = jsonEncode(msg)
  if outPos > 1 and outPos > #outBuf then outBuf, outPos = '', 1 end
  outBuf = outBuf .. line .. '\n'
  stats.txMsgs = stats.txMsgs + 1
  return true
end

local function flush()
  if not sock or outPos > #outBuf then return end
  local last, err, partialLast = sock:send(outBuf, outPos)
  local sentTo = last or partialLast
  if sentTo then
    stats.txBytes = stats.txBytes + (sentTo - outPos + 1)
    outPos = sentTo + 1
  end
  if err and err ~= 'timeout' then close(err) end
  if outPos > #outBuf then outBuf, outPos = '', 1 end
end

-- pump the socket: returns an array of decoded messages received this frame
-- onConnect() is called right after a fresh connection is established
function M.update(dt, onConnect, onDisconnect)
  local msgs = {}
  if not sock then
    retryTimer = retryTimer - dt
    if retryTimer <= 0 then
      retryTimer = M.retryInterval
      if tryConnect() and onConnect then onConnect() end
    end
    return msgs
  end

  -- read everything available
  while sock do
    local data, err, partial = sock:receive(65536)
    local chunk = data or partial
    if chunk and #chunk > 0 then
      inBuf = inBuf .. chunk
      stats.rxBytes = stats.rxBytes + #chunk
    end
    if err == 'closed' then
      close('closed by Minecraft')
      if onDisconnect then onDisconnect() end
      break
    elseif err then
      break -- 'timeout' = nothing more for now
    end
  end

  -- split complete lines
  local start = 1
  while true do
    local nl = string.find(inBuf, '\n', start, true)
    if not nl then break end
    local line = string.sub(inBuf, start, nl - 1)
    start = nl + 1
    if #line > 0 then
      local ok, msg = pcall(jsonDecode, line)
      if ok and type(msg) == 'table' then
        msgs[#msgs + 1] = msg
        stats.rxMsgs = stats.rxMsgs + 1
      else
        log('W', 'beamcraft.net', 'bad message: ' .. string.sub(line, 1, 200))
      end
    end
  end
  if start > 1 then inBuf = string.sub(inBuf, start) end

  flush()
  return msgs
end

return M
