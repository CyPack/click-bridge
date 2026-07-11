#!/usr/bin/env bash
# Claude dev-browser — BAŞLATMADAN ÖNCE STATE ANALİZİ yapar, sonra mcp-pointer ext yüklü +
# CDP :9222 açık, AYRI profilli chromium açar.
# Kullanım: dev-browser.sh [url]        (default: click-bridge demo)
#           dev-browser.sh --state      (sadece analiz, başlatma)
set -u
EXT="$HOME/projects/click-bridge/vendor/mcp-pointer-extension"
PROFILE="$HOME/.cache/cc-dev-browser-profile"
ROUTES="$HOME/.click-bridge/routes.json"
URL="${1:-http://127.0.0.1:7824/}"

state_analysis() {
  echo "═══ DEV-BROWSER STATE ANALİZİ ($(date +%H:%M:%S)) ═══"
  # köprü altyapısı
  for p in "7823:click-bridge" "7824:demo" "9222:CDP" "7007:pointer-ws"; do
    port="${p%%:*}"; name="${p##*:}"
    if ss -ltn 2>/dev/null | grep -q ":$port "; then echo "  ✅ :$port $name AYAKTA"
    else echo "  ⬜ :$port $name boş"; fi
  done
  # routes.json'daki proje dev server'ları canlı mı
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
    print(f"  {'🟢' if up else '🔴'} :{port} → {proj.split('/')[-1]} dev server {'CANLI' if up else 'KAPALI'}")
PYEOF
  fi
  # 9222 zaten doluysa kim tutuyor
  if ss -ltn 2>/dev/null | grep -q ":9222 "; then
    holder=$(pgrep -af "remote-debugging-port=9222" | head -1 | cut -c1-90)
    echo "  ℹ️ 9222 sahibi: ${holder:-bilinmiyor}"
  fi
}

state_analysis
[ "${1:-}" = "--state" ] && exit 0

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/1000/bus}"

# ── SESSION WIRING: pairing token üret + pending binding kaydet ────────────
# Bu script bir Claude Code session'ının Bash tool'undan çalıştırıldıysa, ancestry'de
# o session'ın claude process'i bulunur → açılan sekmenin tıkları SADECE o session'a gider.
# claude atası yoksa (elle terminalden açıldıysa) → ilk prompt yazan session'a lazy-bind.
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
echo "🔗 session-wiring: token=$TOK claude_pid=${CPID:-yok→lazy-bind} — bu sekmenin tıkları tek session'a bağlanacak"

if ss -ltn 2>/dev/null | grep -q ":9222 "; then
  echo "→ dev-browser zaten açık: mevcut pencerede yeni sekme açılıyor ($URL)"
  nohup chromium-browser --user-data-dir="$PROFILE" "$URL" >/dev/null 2>&1 & disown
else
  echo "→ yeni dev-browser başlatılıyor ($URL, CDP :9222)"
  nohup chromium-browser --user-data-dir="$PROFILE" --load-extension="$EXT" \
    --remote-debugging-port=9222 --no-first-run --no-default-browser-check "$URL" >/dev/null 2>&1 & disown
fi
