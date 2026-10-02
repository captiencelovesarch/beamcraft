#!/usr/bin/env bash
# Copy the BeamNG half into BeamNG's userfolder as an unpacked mod.
# Ctrl+L in BeamNG reloads Lua after a redeploy.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../beamng" && pwd)"
DST="$HOME/.local/share/BeamNG/BeamNG.drive/current/mods/unpacked/beamcraft"
mkdir -p "$DST"
rsync -a --delete "$SRC/" "$DST/"
echo "deployed to $DST"
