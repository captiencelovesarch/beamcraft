-- Minecraft-style HUD drawn over BeamNG with imgui's foreground draw list:
-- crosshair, hotbar, hearts/hunger, chat, and a small status readout.

local M = {}

local im = ui_imgui

M.chat = {}            -- { {text=, t=} }
M.showStatus = true

local function col(r, g, b, a) return im.GetColorU322(im.ImVec4(r, g, b, a or 1)) end

local function prettyItem(id)
  if not id or id == '' or id == 'minecraft:air' then return '' end
  local name = id:gsub('^minecraft:', ''):gsub('_', ' ')
  return name
end

function M.addChat(text)
  table.insert(M.chat, { text = tostring(text), t = M.now or 0 })
  while #M.chat > 8 do table.remove(M.chat, 1) end
end

local function text(dl, x, y, str, c, size)
  if size then
    im.ImDrawList_AddText2(dl, im.GetFont(), size, im.ImVec2(x, y), c, str)
  else
    im.ImDrawList_AddText1(dl, im.ImVec2(x, y), c, str)
  end
end

local function shadowText(dl, x, y, str, c, size)
  text(dl, x + 1, y + 1, str, col(0, 0, 0, 0.8), size)
  text(dl, x, y, str, c, size)
end

-- state: { active, connected, ready, hud = {...}, status = {lines} }
function M.draw(state)
  local vp = im.GetMainViewport()
  if not vp then return end
  local dl = im.GetForegroundDrawList1()
  local W, H = vp.Size.x, vp.Size.y
  local X0, Y0 = vp.Pos.x, vp.Pos.y
  local cx, cy = X0 + W * 0.5, Y0 + H * 0.5
  local scale = math.max(1, math.floor(H / 540 + 0.5))

  if M.showStatus and state.status then
    local y = Y0 + 8
    for _, line in ipairs(state.status) do
      shadowText(dl, X0 + 8, y, line, col(1, 1, 1, 0.85))
      y = y + 16
    end
  end

  if not state.active then return end

  -- crosshair
  local ch = 7 * scale
  local white = col(1, 1, 1, 0.9)
  im.ImDrawList_AddLine(dl, im.ImVec2(cx - ch, cy), im.ImVec2(cx + ch + 1, cy), white, scale)
  im.ImDrawList_AddLine(dl, im.ImVec2(cx, cy - ch), im.ImVec2(cx, cy + ch + 1), white, scale)

  local hud = state.hud
  if hud then
    -- hotbar
    local slot = 20 * scale
    local gap = 2 * scale
    local barW = 9 * slot + 8 * gap
    local bx = cx - barW / 2
    local by = Y0 + H - slot - 6 * scale
    for i = 0, 8 do
      local x = bx + i * (slot + gap)
      im.ImDrawList_AddRectFilled(dl, im.ImVec2(x, by), im.ImVec2(x + slot, by + slot), col(0.1, 0.1, 0.1, 0.55), 0)
      local selected = hud.sel == i
      im.ImDrawList_AddRect(dl, im.ImVec2(x, by), im.ImVec2(x + slot, by + slot),
        selected and col(1, 1, 1, 1) or col(0.5, 0.5, 0.5, 0.8), 0, 0, selected and 2 * scale or scale)
      local it = hud.bar and hud.bar[i + 1]
      if it and it.id and it.id ~= 'minecraft:air' then
        local name = prettyItem(it.id)
        -- abbreviated name inside the slot, full name above the bar for the selected one
        local short = name:gsub('(%w)%w*%s*', '%1'):upper():sub(1, 3)
        shadowText(dl, x + 3 * scale, by + 3 * scale, short, col(1, 1, 0.8, 1), 9 * scale)
        if it.n and it.n > 1 then
          shadowText(dl, x + slot - 12 * scale, by + slot - 10 * scale, tostring(it.n), white, 8 * scale)
        end
        if selected then
          local w = #name * 6 * scale * 0.55
          shadowText(dl, cx - w / 2, by - 40 * scale, name, white, 11 * scale)
        end
      end
    end

    -- hearts / hunger (survival + adventure only)
    if hud.gm == 'survival' or hud.gm == 'adventure' then
      local hy = by - 12 * scale
      local hp = hud.hp or 20
      for i = 0, 9 do
        local x = bx + i * 9 * scale
        local fill = math.max(0, math.min(2, hp - i * 2))
        im.ImDrawList_AddRectFilled(dl, im.ImVec2(x, hy), im.ImVec2(x + 8 * scale, hy + 8 * scale), col(0.15, 0.0, 0.0, 0.8), 2)
        if fill > 0 then
          im.ImDrawList_AddRectFilled(dl, im.ImVec2(x + scale, hy + scale),
            im.ImVec2(x + scale + 6 * scale * fill / 2, hy + 7 * scale), col(0.9, 0.1, 0.1, 1), 1)
        end
      end
      local food = hud.food or 20
      for i = 0, 9 do
        local x = bx + barW - (i + 1) * 9 * scale
        local fill = math.max(0, math.min(2, food - i * 2))
        im.ImDrawList_AddRectFilled(dl, im.ImVec2(x, hy), im.ImVec2(x + 8 * scale, hy + 8 * scale), col(0.12, 0.07, 0.0, 0.8), 2)
        if fill > 0 then
          im.ImDrawList_AddRectFilled(dl, im.ImVec2(x + scale + 6 * scale * (1 - fill / 2), hy + scale),
            im.ImVec2(x + 7 * scale, hy + 7 * scale), col(0.75, 0.5, 0.2, 1), 1)
        end
      end
    end
  end

  -- chat (fades after 10 s)
  local now = M.now or 0
  local y = Y0 + H - 120 * scale
  for i = #M.chat, 1, -1 do
    local c = M.chat[i]
    local age = now - c.t
    if age < 10 then
      local a = age > 8 and (10 - age) / 2 or 1
      im.ImDrawList_AddRectFilled(dl, im.ImVec2(X0 + 4, y - 2), im.ImVec2(X0 + 4 + 320 * scale, y + 10 * scale), col(0, 0, 0, 0.4 * a))
      shadowText(dl, X0 + 8, y, c.text, col(1, 1, 1, a), 9 * scale)
      y = y - 12 * scale
    end
  end
end

return M
