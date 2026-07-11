#!/usr/bin/env bash
# Claude dev-browser — mcp-pointer extension yüklü + CDP :9222 açık, AYRI profilli chromium.
# Kullanım: dev-browser.sh [url]   (default: click-bridge demo)
# Ne sağlar:
#   • mcp-pointer extension (vetted-source build) her açılışta yüklü → Alt+Click ile element MCP'ye
#   • --remote-debugging-port=9222 → Claude, chrome-devtools/CDP ile BU pencerenin network/console/perf'ine bağlanabilir
#   • Ayrı profil (~/.cache/cc-dev-browser-profile) → günlük tarayıcına DOKUNMAZ
set -u
EXT="$HOME/projects/click-bridge/vendor/mcp-pointer-extension"
PROFILE="$HOME/.cache/cc-dev-browser-profile"
URL="${1:-http://127.0.0.1:7824/}"

# Headless/bg çağrılar için canlı Wayland oturumuna bağlan
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/1000/bus}"

nohup chromium-browser \
  --user-data-dir="$PROFILE" \
  --load-extension="$EXT" \
  --remote-debugging-port=9222 \
  --no-first-run --no-default-browser-check \
  "$URL" >/dev/null 2>&1 &
disown
echo "dev-browser başlatıldı: $URL (CDP: http://127.0.0.1:9222)"
