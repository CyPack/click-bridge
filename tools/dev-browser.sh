#!/usr/bin/env bash
# Claude dev-browser — runs a STATE ANALYSIS BEFORE LAUNCHING, then opens a chromium
# instance with a separate profile, an (optional) extension loaded, and CDP :9222 open.
# Usage: dev-browser.sh [url]        (default: click-bridge demo)
#        dev-browser.sh --state      (analysis only, don't launch)
set -u
EXT="$HOME/projects/click-bridge/vendor/mcp-pointer-extension"  # optional: path to an unpacked extension to load
PROFILE="$HOME/.cache/cc-dev-browser-profile"
ROUTES="$HOME/.click-bridge/routes.json"
URL="${1:-http://127.0.0.1:7824/}"

state_analysis() {
  echo "═══ DEV-BROWSER STATE ANALYSIS ($(date +%H:%M:%S)) ═══"
  # bridge infrastructure
  for p in "7823:click-bridge" "7824:demo" "9222:CDP" "7007:pointer-ws"; do
    port="${p%%:*}"; name="${p##*:}"
    if ss -ltn 2>/dev/null | grep -q ":$port "; then echo "  ✅ :$port $name UP"
    else echo "  ⬜ :$port $name idle"; fi
  done
  # are the routes.json project dev servers alive
  if [ -f "$ROUTES" ]; then
    python3 - "$ROUTES" <<'PYEOF' 2>/dev/null
import json, socket, sys, re
for r in json.load(open(sys.argv[1])).get("routes", []):
    pat, proj = r.get("url_contains",""), r.get("project","")
    m = re.search(r"(\d{2,5})", pat)
    if not (m and proj): continue
    port = int(m.group(1))
    s = socket.socket(); s.settimeout(0.5)
    up = s.connect_ex(("127.0.0.1", port)) == 0; s.close()
    print(f"  {'🟢' if up else '🔴'} :{port} → {proj.split('/')[-1]} dev server {'UP' if up else 'DOWN'}")
PYEOF
  fi
  # if 9222 is already taken, who holds it
  if ss -ltn 2>/dev/null | grep -q ":9222 "; then
    holder=$(pgrep -af "remote-debugging-port=9222" | head -1 | cut -c1-90)
    echo "  ℹ️ 9222 held by: ${holder:-unknown}"
  fi
}

state_analysis
[ "${1:-}" = "--state" ] && exit 0

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/1000/bus}"

# ── SESSION WIRING: generate a pairing token + record a pending binding ───────
# If this script was launched from a Claude Code session's Bash tool, that session's
# claude process is in our ancestry → clicks from the opened tab go ONLY to that session.
# No claude ancestor (launched from a plain terminal)? → lazy-bind to the first session
# that submits a prompt after the click.
. "$(dirname "$0")/../cb-lib.sh" 2>/dev/null || true
TOK=$(uuidgen 2>/dev/null | tr -d '-' | cut -c1-10)
[ -n "$TOK" ] || TOK="t$$$(date +%s)"
CPID=""
command -v cb_find_claude_pid >/dev/null 2>&1 && CPID=$(cb_find_claude_pid || true)
CBD="$HOME/.click-bridge"
mkdir -p "$CBD"
flock "$CBD/.bindings.lock" sh -c 'printf "%s\n" "$1" >> "$2"' _ \
  "{\"token\":\"$TOK\",\"state\":\"pending\",\"claude_pid\":${CPID:-null},\"ts\":$(date +%s)}" \
  "$CBD/bindings.jsonl"
case "$URL" in
  *\#*) URL="$URL&cb=$TOK" ;;
  *)    URL="$URL#cb=$TOK" ;;
esac
echo "🔗 session-wiring: token=$TOK claude_pid=${CPID:-none→lazy-bind} — clicks from this tab bind to a single session"

if ss -ltn 2>/dev/null | grep -q ":9222 "; then
  echo "→ dev-browser already open: opening a new tab in the existing window ($URL)"
  nohup chromium-browser --user-data-dir="$PROFILE" "$URL" >/dev/null 2>&1 & disown
else
  echo "→ launching a new dev-browser ($URL, CDP :9222)"
  nohup chromium-browser --user-data-dir="$PROFILE" --load-extension="$EXT" \
    --remote-debugging-port=9222 --no-first-run --no-default-browser-check "$URL" >/dev/null 2>&1 & disown
fi
