#!/usr/bin/env bash
# Start BeamCraft's hidden Minecraft (the Fabric dev client). It renders on the GPU
# through your real display, but its window is never shown, so it can't steal focus
# from BeamNG. BeamNG connects to it on 127.0.0.1:47800 whenever the BeamCraft mod is
# loaded.
#
#   tools/run_backend.sh            # hidden, GPU (normal)
#   tools/run_backend.sh --xvfb     # hidden on a virtual display, software rendering (slow)
#   tools/run_backend.sh --visible  # a real Minecraft window, for debugging
set -euo pipefail
cd "$(dirname "$0")/../fabric"
export JAVA_HOME=/usr/lib/jvm/java-25-openjdk
case "${1:-}" in
  --visible) exec ./gradlew runClient -Pheadless=false ;;
  --xvfb) exec xvfb-run -a -s "-screen 0 3840x2160x24" ./gradlew runClient -Pheadless=true ;;
esac
# X11 via XWayland: an unmapped Wayland surface can block buffer swaps, an X window can't
exec env -u WAYLAND_DISPLAY ./gradlew runClient -Pheadless=true
