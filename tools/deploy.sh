#!/usr/bin/env bash
# Copy the BeamNG half into BeamNG's userfolder as an unpacked mod.
# Ctrl+L in BeamNG reloads Lua after a redeploy.
#   tools/deploy.sh         # deploy
#   tools/deploy.sh --dev   # also enable the dev Lua console (tools/bng_eval.py)
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../beamng" && pwd)"
USER_DIR="$HOME/.local/share/BeamNG/BeamNG.drive/current"
DST="$USER_DIR/mods/unpacked/beamcraft"
mkdir -p "$DST"
rm -rf "$DST"
mkdir -p "$DST"
cp -a "$SRC/." "$DST/"
if [[ "${1:-}" == "--dev" ]]; then
  mkdir -p "$USER_DIR/beamcraft"
  touch "$USER_DIR/beamcraft/dev_eval"
  echo "dev console enabled (127.0.0.1:47801)"
fi
echo "deployed to $DST"
