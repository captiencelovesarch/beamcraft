-- Developer-only remote Lua console for BeamCraft, so tools/bng_eval.py can inspect
-- the running game. Disabled unless the file <userfolder>/beamcraft/dev_eval exists.
-- Binds to 127.0.0.1 only. One JSON request per line: {"code": "return 1+1"};
-- one JSON reply per line: {"ok": true, "result": "2"}.

local socket = require('socket.socket')

local M = {}
M.port = 47801

local server
local clients = {}

function M.enabled()
  return FS:fileExists('/beamcraft/dev_eval')
end

local function run(code)
  local fn, err = (loadstring or load)(code, 'bng_eval')
  if not fn then return { ok = false, result = 'compile: ' .. tostring(err) } end
  local res = { pcall(fn) }
  if not res[1] then return { ok = false, result = tostring(res[2]) } end
  local out = {}
  for i = 2, #res do out[#out + 1] = dumps(res[i]) end
  return { ok = true, result = table.concat(out, '\n') }
end

function M.update()
  if not server then
    if not M.enabled() then return end
    server = socket.bind('127.0.0.1', M.port)
    if not server then return end
    server:settimeout(0)
    log('W', 'beamcraft.dev', 'dev eval console listening on 127.0.0.1:' .. M.port)
  end
  local c = server:accept()
  if c then
    c:settimeout(0)
    clients[#clients + 1] = { sock = c, buf = '' }
  end
  for i = #clients, 1, -1 do
    local cl = clients[i]
    local data, err, partial = cl.sock:receive(65536)
    local chunk = data or partial
    if chunk and #chunk > 0 then cl.buf = cl.buf .. chunk end
    while true do
      local nl = string.find(cl.buf, '\n', 1, true)
      if not nl then break end
      local line = string.sub(cl.buf, 1, nl - 1)
      cl.buf = string.sub(cl.buf, nl + 1)
      local ok, req = pcall(jsonDecode, line)
      local reply = (ok and type(req) == 'table' and req.code) and run(req.code) or { ok = false, result = 'bad request' }
      cl.sock:settimeout(1)
      cl.sock:send(jsonEncode(reply) .. '\n')
      cl.sock:settimeout(0)
    end
    if err == 'closed' then
      cl.sock:close()
      table.remove(clients, i)
    end
  end
end

function M.close()
  for _, cl in ipairs(clients) do pcall(function() cl.sock:close() end) end
  clients = {}
  if server then server:close() server = nil end
end

return M
