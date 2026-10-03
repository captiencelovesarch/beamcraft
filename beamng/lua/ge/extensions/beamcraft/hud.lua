-- What's left of BeamNG-side HUD drawing now that Minecraft draws its own GUI (see
-- ui/modModules/beamcraft): item icon paths for dropped items in the world, and an
-- optional debug readout (beamcraft_main.hud.showStatus = true).

local M = {}

local im = ui_imgui

M.showStatus = false
M.now = 0
M.gui = nil            -- { dir=, glyphs=, sizes=, slim= } exported by Minecraft (skin lives here)
M.iconsDir = nil       -- '/beamcraft/icons/<hash>'
M.items = { blocks = {}, other = {} }

function M.iconPath(itemId)
  if not M.iconsDir or not itemId then return nil end
  local ns, path = itemId:match('^([^:]+):(.+)$')
  if not ns then ns, path = 'minecraft', itemId end
  return string.format('%s/%s/%s.color.png', M.iconsDir, ns, path)
end

function M.drawStatus(lines)
  if not M.showStatus or not lines then return end
  local vp = im.GetMainViewport()
  if not vp then return end
  local dl = im.GetForegroundDrawList1()
  local y = vp.Pos.y + 4
  for _, line in ipairs(lines) do
    im.ImDrawList_AddText1(dl, im.ImVec2(vp.Pos.x + 5, y + 1), im.GetColorU322(im.ImVec4(0, 0, 0, 0.8)), line)
    im.ImDrawList_AddText1(dl, im.ImVec2(vp.Pos.x + 4, y), im.GetColorU322(im.ImVec4(1, 1, 1, 0.9)), line)
    y = y + 16
  end
end

return M
