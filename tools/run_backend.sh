#!/usr/bin/env bash
# Start BeamCraft's hidden Minecraft (the Fabric dev client) on an invisible X display,
# so it never opens a window or steals focus from BeamNG. Leave it running; BeamNG
# connects to it on 127.0.0.1:47800 whenever the BeamCraft mod is loaded.
#
#   tools/run_backend.sh            # headless (normal)
#   tools/run_backend.sh --visible  # a real Minecraft window, for debugging
set -euo pipefail
cd "$(dirname "$0")/../fabric"
export JAVA_HOME=/usr/lib/jvm/java-25-openjdk
if [[ "${1:-}" == "--visible" ]]; then
  exec ./gradlew runClient -Pheadless=false
fi
exec xvfb-run -a -s "-screen 0 854x480x24" ./gradlew runClient -Pheadless=true
