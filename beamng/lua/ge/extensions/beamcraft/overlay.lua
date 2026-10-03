-- Minecraft's GUI, first-person hand and screen effects, drawn over BeamNG with imgui.
--
-- The hidden Minecraft renders them over a transparent background. For each frame it
-- writes every changed 128 px tile as a small PNG file into /beamcraft/ov (a RAM disk
-- linked into the userfolder) and tells us on its raw socket (127.0.0.1:47802) which
-- files belong where:
--   u32 little-endian length, then "W,H,T,full;tx,ty,name;tx,ty,-;..."
-- We load each named file as a texture (well under a millisecond) and draw the whole
-- grid every BeamNG frame on imgui's foreground layer.
--
-- This used to go through BeamNG's Chromium UI, which tops out around 37 fps here no
-- matter what the game runs at - that was the choppy HUD and hand.
--
-- Pull model: each byte we send asks for one frame ('F' = whole frame). Two requests
-- may be in flight, so the next frame is usually already rendered when we want it.

local socket = require('socket.socket')
local sbuf = require('string.buffer')
local im = ui_imgui

local M = {}

M.port = 47802
M.frames = 0
M.tilesLoaded = 0

local WINDOW = 2
local DIR = '/beamcraft/ov/'

local sock
local inbuf = sbuf.new()
local need = nil   -- length of the message being read, once its header has arrived
local retry = 0
local pending = 0
local waitTime = 0
local wantFull = false

local grid = { w = 0, h = 0, t = 128 }
local tiles = {}   -- [ty * 4096 + tx] = { tex =, id =, x =, y = }

local white = 0xFFFFFFFF

local function clearTiles() tiles = {} end
M.clear = clearTiles

local function close()
  if sock then pcall(function() sock:close() end) end
  sock = nil
  inbuf:reset()
  need = nil
  pending = 0
end
M.close = close
function M.shutdown()
  close()
  clearTiles()
end

-- kept for the old page API; nothing to acknowledge any more
function M.ack() end
function M.setVisible() end

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
  pending = 0
  clearTiles()
  return true
end

local function applyFrame(msg)
  local first = true
  local okAll = true
  for part in msg:gmatch('[^;]+') do
    if first then
      first = false
      local w, h, t, full = part:match('^(%d+),(%d+),(%d+),(%d)$')
      if not w then return end
      w, h, t = tonumber(w), tonumber(h), tonumber(t)
      if full == '1' or w ~= grid.w or h ~= grid.h or t ~= grid.t then clearTiles() end
      grid.w, grid.h, grid.t = w, h, t
    else
      local tx, ty, name = part:match('^(%d+),(%d+),(.+)$')
      if tx then
        tx, ty = tonumber(tx), tonumber(ty)
        local key = ty * 4096 + tx
        if name == '-' then
          tiles[key] = nil
        else
          local tex = im.ImTextureHandler(DIR .. name)
          local size = tex:getSize()
          if size and size.x > 0 then
            tiles[key] = { tex = tex, id = tex:getID(), x = tx, y = ty, w = size.x, h = size.y }
            M.tilesLoaded = M.tilesLoaded + 1
          else
            -- the file is gone (we stalled longer than Minecraft keeps them)
            tiles[key] = nil
            okAll = false
          end
        end
      end
    end
  end
  if not okAll then wantFull = true end
end

-- enabled: only pull frames while Steve is being played
function M.update(dt, enabled)
  if not enabled then
    if sock then close() end
    if next(tiles) then clearTiles() end
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

  -- only the newest complete frame matters, but every frame's tiles must be applied
  -- in order (each one only carries what changed)
  while true do
    if not need then
      if #inbuf < 4 then break end
      local b1, b2, b3, b4 = string.byte(inbuf:get(4), 1, 4)
      need = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end
    if #inbuf < need then break end
    local msg = inbuf:get(need)
    need = nil
    M.frames = M.frames + 1
    pending = math.max(0, pending - 1)
    waitTime = 0
    applyFrame(msg)
  end

  -- recover if a request got lost
  if pending > 0 then
    waitTime = waitTime + dt
    if waitTime > 0.5 then pending, waitTime = 0, 0 end
  end
  while sock and pending < WINDOW do
    local sent = sock:send(wantFull and 'F' or 'N')
    if not sent then close() return end
    wantFull = false
    pending = pending + 1
  end
end

-- every BeamNG frame, after everything else
function M.draw()
  if grid.w <= 0 or not next(tiles) then return end
  local vp = im.GetMainViewport()
  if not vp then return end
  local sx, sy = vp.Size.x / grid.w, vp.Size.y / grid.h
  local ox, oy = vp.Pos.x, vp.Pos.y
  local t = grid.t
  local dl = im.GetForegroundDrawList1()
  local p0, p1 = im.ImVec2(0, 0), im.ImVec2(0, 0)
  local uv0, uv1 = im.ImVec2(0, 0), im.ImVec2(1, 1)
  for _, tile in pairs(tiles) do
    -- each texture has a 1 px apron of its neighbours: draw only the inside
    local x, y = tile.x * t, tile.y * t
    p0.x, p0.y = ox + x * sx, oy + y * sy
    p1.x, p1.y = ox + (x + tile.w - 2) * sx, oy + (y + tile.h - 2) * sy
    uv0.x, uv0.y = 1 / tile.w, 1 / tile.h
    uv1.x, uv1.y = (tile.w - 1) / tile.w, (tile.h - 1) / tile.h
    im.ImDrawList_AddImage(dl, tile.id, p0, p1, uv0, uv1, white)
  end
end

function M.size() return grid.w, grid.h end

return M
