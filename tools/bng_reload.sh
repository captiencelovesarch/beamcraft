#!/usr/bin/env bash
# Deploy and hot-reload BeamCraft's Lua in a running BeamNG (needs the dev console).
# Clears BeamCraft's submodules from Lua's require cache, then reloads the extension.
# Never clear 'beamcraft/main' itself: the extension manager needs that entry to
# unload the old instance (otherwise it keeps running alongside the new one).
set -euo pipefail
cd "$(dirname "$0")/.."
tools/deploy.sh >/dev/null
python3 tools/bng_eval.py '
for k in pairs(package.loaded) do
  if type(k) == "string" and k:find("^beamcraft/") and k ~= "beamcraft/main" then package.loaded[k] = nil end
end
extensions.reload("beamcraft_main")
return "reloaded"' 2>/dev/null || true
sleep 3
python3 tools/bng_eval.py 'return "BeamCraft back: connected=" .. tostring(beamcraft_main.net.isConnected())'
