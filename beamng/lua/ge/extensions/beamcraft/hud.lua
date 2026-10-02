-- Minecraft's HUD, drawn over BeamNG with imgui using the real vanilla sprites and
-- pixel font that the hidden client exports: crosshair, hotbar with item icons,
-- hearts, hunger, xp, held-item name, chat. Plus the creative item picker (E).

local M = {}

local im = ui_imgui
local ffi = require('ffi')

M.chat = {}            -- { {text=, t=} }
M.showStatus = false   -- debug readout (beamcraft_main.hud.showStatus = true)
M.now = 0
M.gui = nil            -- { dir=, glyphs={...}, sizes={...} } from Minecraft
M.iconsDir = nil       -- '/beamcraft/icons/<hash>'
M.pickerOpen = false
M.items = { blocks = {}, other = {} }
M.onPick = nil
M.onClose = nil

------------------------------------------------------------------------------
-- textures
------------------------------------------------------------------------------

local texCache = {}
local missRetry = {}

local function tex(path)
  if not path then return nil end
  local t = texCache[path]
  if t then return t end
  -- icons are generated lazily: don't cache a miss, just retry a bit later
  if (missRetry[path] or 0) > M.now then return nil end
  if not FS:fileExists(path) then
    missRetry[path] = M.now + 1
    return nil
  end
  local h = im.ImTextureHandler(path)
  if not h then return nil end
  t = { h = h, id = h:getID() }
  texCache[path] = t
  return t
end

function M.iconPath(itemId)
  if not M.iconsDir or not itemId then return nil end
  local ns, path = itemId:match('^([^:]+):(.+)$')
  if not ns then ns, path = 'minecraft', itemId end
  return string.format('%s/%s/%s.png', M.iconsDir, ns, path)
end

local function sprite(name) return M.gui and tex(M.gui.dir .. '/' .. name .. '.png') end

local function col(r, g, b, a) return im.GetColorU322(im.ImVec4(r, g, b, a or 1)) end
local WHITE = col(1, 1, 1, 1)

local function image(dl, t, x, y, w, h, c, u0, v0, u1, v1)
  if not t then return end
  im.ImDrawList_AddImage(dl, t.id, im.ImVec2(x, y), im.ImVec2(x + w, y + h),
    im.ImVec2(u0 or 0, v0 or 0), im.ImVec2(u1 or 1, v1 or 1), c or WHITE)
end

------------------------------------------------------------------------------
-- the Minecraft font (ascii.png, 16x16 cells of 8px)
------------------------------------------------------------------------------

local function textWidth(str, S)
  local g = M.gui and M.gui.glyphs
  if not g then return #str * 6 * S end
  local w = 0
  for i = 1, #str do w = w + (g[str:byte(i) + 1] or 6) end
  return w * S
end
M.textWidth = textWidth

local function drawText(dl, str, x, y, S, r, gr, b, a, noShadow)
  local font = sprite('font')
  local g = M.gui and M.gui.glyphs
  if not font or not g then
    im.ImDrawList_AddText1(dl, im.ImVec2(x, y), col(r, gr, b, a), str)
    return
  end
  local function pass(ox, oy, c)
    local cx = x + ox
    for i = 1, #str do
      local ch = str:byte(i)
      local adv = g[ch + 1] or 6
      if ch ~= 32 and adv > 0 then
        local u0, v0 = (ch % 16) / 16, math.floor(ch / 16) / 16
        local gw = adv - 1
        image(dl, font, cx, y + oy, gw * S, 8 * S, c, u0, v0, u0 + gw / 128, v0 + 8 / 128)
      end
      cx = cx + adv * S
    end
  end
  if not noShadow then pass(S, S, col(r * 0.25, gr * 0.25, b * 0.25, a)) end
  pass(0, 0, col(r, gr, b, a))
end
M.drawText = drawText

function M.addChat(text)
  table.insert(M.chat, { text = tostring(text):gsub('\194\167.', ''), t = M.now })
  while #M.chat > 10 do table.remove(M.chat, 1) end
end

------------------------------------------------------------------------------
-- creative item picker
------------------------------------------------------------------------------

local search = im.ArrayChar(64, '')
local showAll = im.BoolPtr(false)

local function drawPicker()
  if not M.pickerOpen then return end
  local vp = im.GetMainViewport()
  im.SetNextWindowPos(im.ImVec2(vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.45), im.Cond_Appearing, im.ImVec2(0.5, 0.5))
  im.SetNextWindowSize(im.ImVec2(560, 600), im.Cond_FirstUseEver)
  local open = im.BoolPtr(true)
  if im.Begin('Items##bcpicker', open, im.WindowFlags_NoCollapse) then
    im.Text('Click an item to put it in your selected hotbar slot.')
    im.SetNextItemWidth(300)
    im.InputText('##bcsearch', search)
    im.SameLine()
    im.Checkbox('everything', showAll)
    local q = ffi.string(search):lower()
    im.BeginChild1('##bclist')
    local avail = im.GetContentRegionAvail().x
    local cell = 44
    local perRow = math.max(1, math.floor(avail / (cell + 8)))
    local n = 0
    local function list(ids)
      for _, id in ipairs(ids) do
        local name = id:gsub('^minecraft:', '')
        if q == '' or name:find(q, 1, true) then
          if n % perRow ~= 0 then im.SameLine() end
          n = n + 1
          local t = tex(M.iconPath(id))
          local clicked
          if t then
            clicked = im.ImageButton('##' .. id, t.id, im.ImVec2(cell, cell))
          else
            clicked = im.Button(name:sub(1, 6) .. '##' .. id, im.ImVec2(cell + 8, cell + 6))
          end
          if im.IsItemHovered() then im.SetTooltip(name:gsub('_', ' ')) end
          if clicked and M.onPick then M.onPick(id) end
        end
      end
    end
    list(M.items.blocks or {})
    if showAll[0] then list(M.items.other or {}) end
    im.EndChild()
  end
  im.End()
  if not open[0] and M.onClose then M.onClose() end
end

------------------------------------------------------------------------------
-- HUD
------------------------------------------------------------------------------

local lastSel, selChangedAt = nil, -10

local function prettyItem(id)
  if not id or id == '' or id == 'minecraft:air' then return '' end
  local s = id:gsub('^minecraft:', ''):gsub('_', ' ')
  return (s:gsub('(%a)([%w]*)', function(a, b) return a:upper() .. b end))
end

-- state: { active, hud = {...}, status = {lines} }
function M.draw(state)
  drawPicker()
  local vp = im.GetMainViewport()
  if not vp then return end
  local dl = im.GetForegroundDrawList1()
  local W, H = vp.Size.x, vp.Size.y
  local X0, Y0 = vp.Pos.x, vp.Pos.y
  local S = math.max(2, math.floor(H / 360))   -- Minecraft "GUI scale"

  if M.showStatus and state.status then
    local y = Y0 + 4
    for _, line in ipairs(state.status) do
      drawText(dl, line, X0 + 4, y, 2, 1, 1, 1, 0.9)
      y = y + 20
    end
  end
  if not state.active then return end

  local cx = X0 + W / 2
  local bottom = Y0 + H

  -- crosshair
  local ch = sprite('crosshair')
  if ch then
    image(dl, ch, X0 + W / 2 - 7.5 * S, Y0 + H / 2 - 7.5 * S, 15 * S, 15 * S, col(1, 1, 1, 0.85))
  end

  local hud = state.hud
  if not hud then return end
  local x0 = cx - 91 * S
  local hy = bottom - 22 * S

  -- hotbar + selection
  image(dl, sprite('hotbar'), x0, hy, 182 * S, 22 * S)
  local sel = hud.sel or 0
  image(dl, sprite('hotbar_selection'), x0 - S + sel * 20 * S, hy - S, 24 * S, 23 * S)
  if sel ~= lastSel then lastSel, selChangedAt = sel, M.now end

  for i = 0, 8 do
    local it = hud.bar and hud.bar[i + 1]
    if it and it.id and it.id ~= 'minecraft:air' then
      local ix, iy = x0 + (3 + i * 20) * S, hy + 3 * S
      image(dl, tex(M.iconPath(it.id)), ix, iy, 16 * S, 16 * S)
      if it.n and it.n > 1 then
        local s = tostring(it.n)
        drawText(dl, s, ix + 17 * S - textWidth(s, S), iy + 9 * S, S, 1, 1, 1, 1)
      end
    end
  end

  local survival = hud.gm == 'survival' or hud.gm == 'adventure'
  if survival then
    -- xp bar
    image(dl, sprite('xp_background'), x0, bottom - 29 * S, 182 * S, 5 * S)
    local xp = math.max(0, math.min(1, hud.xp or 0))
    if xp > 0 then
      image(dl, sprite('xp_progress'), x0, bottom - 29 * S, 182 * S * xp, 5 * S, nil, 0, 0, xp, 1)
    end
    if (hud.lvl or 0) > 0 then
      local s = tostring(hud.lvl)
      drawText(dl, s, cx - textWidth(s, S) / 2, bottom - 35 * S, S, 0.5, 1, 0.13, 1)
    end
    -- hearts and hunger
    local top = bottom - 39 * S
    local hp = math.ceil(hud.hp or 20)
    for i = 0, 9 do
      local x = x0 + i * 8 * S
      image(dl, sprite('heart_container'), x, top, 9 * S, 9 * S)
      if hp >= i * 2 + 2 then image(dl, sprite('heart_full'), x, top, 9 * S, 9 * S)
      elseif hp == i * 2 + 1 then image(dl, sprite('heart_half'), x, top, 9 * S, 9 * S) end
    end
    local food = hud.food or 20
    for i = 0, 9 do
      local x = x0 + 182 * S - (i * 8 + 9) * S
      image(dl, sprite('food_empty'), x, top, 9 * S, 9 * S)
      if food >= i * 2 + 2 then image(dl, sprite('food_full'), x, top, 9 * S, 9 * S)
      elseif food == i * 2 + 1 then image(dl, sprite('food_half'), x, top, 9 * S, 9 * S) end
    end
  end

  -- held item name, fades like vanilla
  local age = M.now - selChangedAt
  local held = hud.bar and hud.bar[sel + 1]
  if age < 3 and held and held.id and held.id ~= 'minecraft:air' then
    local a = age > 2 and (3 - age) or 1
    local name = prettyItem(held.id)
    local ny = bottom - (survival and 59 or 38) * S
    drawText(dl, name, cx - textWidth(name, S) / 2, ny, S, 1, 1, 1, a)
  end

  -- chat (fades after 10 s)
  local y = bottom - 40 * S - 9 * S
  for i = #M.chat, 1, -1 do
    local c = M.chat[i]
    local cage = M.now - c.t
    if cage < 10 then
      local a = cage > 9 and (10 - cage) or 1
      im.ImDrawList_AddRectFilled(dl, im.ImVec2(X0, y - S), im.ImVec2(X0 + 320 * S, y + 8 * S), col(0, 0, 0, 0.5 * a))
      drawText(dl, c.text, X0 + 2 * S, y, S, 1, 1, 1, a)
      y = y - 9 * S
    end
  end
end

return M
