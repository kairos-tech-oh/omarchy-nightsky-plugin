#!/usr/bin/env bash
# Render SkyChart.qml to a PNG without touching the running shell.
#
#   tools/preview/render.sh                                    # here, now
#   tools/preview/render.sh 2026-01-15T22:00:00Z 40.13 -82.93  # Ohio, winter
#   tools/preview/render.sh 2026-08-23T10:00:00Z -33.87 151.21 # Sydney
#
# Arguments: an instant (anything `date -d` understands), then latitude and
# longitude. Output goes to preview-sky.png in this directory unless a fourth
# argument names somewhere else.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

when="${1:-now}"
lat="${2:-40.1267}"
lon="${3:--82.9319}"
out="${4:-$here/preview-sky.png}"

epoch_ms="$(date -u -d "$when" +%s)000"

qml_bin=""
for candidate in /usr/lib/qt6/bin/qml "$(command -v qml 2>/dev/null)"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && qml_bin="$candidate" && break
done
[ -n "$qml_bin" ] || { echo "no qml runner found" >&2; exit 1; }

rm -f "$out"

# Offscreen with software rasterisation, so this works over SSH and anywhere
# without a GPU context to bind.
QT_ASSUME_STDERR_HAS_CONSOLE=1 QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  "$qml_bin" -I "$here" "$here/preview.qml" -- "$out" "$epoch_ms" "$lat" "$lon" "${5:-5}"

if [ -f "$out" ]; then
  echo "wrote $out  (lat $lat, lon $lon, $when)"
else
  echo "render produced no file" >&2
  exit 1
fi
