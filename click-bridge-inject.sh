#!/usr/bin/env bash
# click-bridge UserPromptSubmit hook v4 — SESSION-WIRED teslimat (token ↔ session binding).
#
# Katmanlar (öncelik sırası):
#   1) TOKEN'LI tık (payload'da cb_token — dev-browser.sh #cb=TOKEN ile açılmış sekme):
#      - bound   → SADECE bağlı session_id alır (deterministik; çok-session çakışması İMKANSIZ)
#      - pending → SADECE dev-browser'ı başlatan claude process'inin session'ı alır
#                  (process-ancestry PID eşleşmesi) ve binding o anda session_id'ye kilitlenir
#      - unknown → lazy-bind: ilk prompt yazan session alır VE token o session'a bağlanır
#   2) TOKEN'SIZ tık (legacy): routes.json cwd path-SINIRLI prefix eşleşmesi + exactly-once
#      (CLICK_BRIDGE_BROADCAST=1 → her session birer kez). v3 davranışıyla geriye uyumlu.
#
# Teslimat kaydı: delivery.jsonl (mode=bound|lazy|legacy|legacy-bcast)
# Binding kaydı: bindings.jsonl (append-only, 48h TTL, flock ile yarışsız)
# Test izolasyonu: CLICK_BRIDGE_DIR=/tmp/x ile canlı state'e dokunmadan çalıştırılabilir.
set -u
D="${CLICK_BRIDGE_DIR:-$HOME/.click-bridge}"
F="$D/last.json"
[ -f "$F" ] || exit 0

LIB="$HOME/projects/click-bridge/cb-lib.sh"
[ -f "$LIB" ] && . "$LIB"

# hook stdin JSON'undan session kimliği + çalışma dizini
in=$(cat - 2>/dev/null || true)
sid=$(printf '%s' "$in" | jq -r '.session_id // "unknown"' 2>/dev/null | cut -c1-12)
[ -n "$sid" ] || sid=unknown
scwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)

now=$(date +%s)
mtime=$(stat -c %Y "$F" 2>/dev/null) || exit 0
age=$(( now - mtime ))
[ "$age" -le 300 ] || exit 0
h=$(md5sum "$F" | cut -d' ' -f1)

# bu hook hangi claude process'inin altında koşuyor? (pending-binding eşleşmesi için)
my_claude_pid=""
command -v cb_find_claude_pid >/dev/null 2>&1 && my_claude_pid=$(cb_find_claude_pid || true)

# ── karar: token/binding/route tek geçişte (flock: eşzamanlı prompt yarışına karşı) ──
mkdir -p "$D"
verdict=$(flock "$D/.bindings.lock" python3 - "$F" "$D" "$scwd" "$sid" "${my_claude_pid:-}" <<'PYEOF' 2>/dev/null
import json, os, sys, time
click_f, d, cwd, sid, mypid = sys.argv[1:6]
bind_f = os.path.join(d, "bindings.jsonl")
now = time.time()

def out(v):
    print(v); sys.exit(0)

try:
    click = json.load(open(click_f))
except Exception:
    out("allow-legacy")  # okunamayan tık köprüyü ASLA kilitlemesin

def load_bindings():
    m = {}
    try:
        with open(bind_f) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                t = r.get("token")
                if t and now - r.get("ts", now) < 172800:  # 48h TTL
                    m[t] = r  # last-wins
    except FileNotFoundError:
        pass
    return m

def append(rec):
    rec["ts"] = now
    with open(bind_f, "a") as f:
        f.write(json.dumps(rec) + "\n")

token = str(click.get("cb_token") or "")
if token:
    b = load_bindings().get(token)
    if b and b.get("state") == "bound":
        out("allow-bound" if b.get("session_id") == sid else "deny")
    if b and b.get("state") == "pending":
        cpid = str(b.get("claude_pid") or "")
        if cpid and mypid and cpid == mypid:
            append({"token": token, "state": "bound", "session_id": sid, "claude_pid": cpid})
            out("allow-bound")
        if cpid and os.path.exists("/proc/" + cpid):
            out("deny")  # sahibi belli ve canlı ama bu session değil — tıkı ÇALMA
        # sahibi ölmüş/bilinmiyor → lazy'e düş
    append({"token": token, "state": "bound", "session_id": sid, "via": "lazy"})
    out("allow-lazy")

# token yok → legacy routing (path-SINIRLI prefix: cc-dashboard-backups ≠ cc-dashboard)
try:
    routes = json.load(open(os.path.join(d, "routes.json"))).get("routes", [])
except Exception:
    routes = []
url = click.get("url", "") or ""
for r in routes:
    pat = r.get("url_contains", "")
    proj = (r.get("project", "") or "").rstrip("/")
    if pat and proj and pat in url:
        out("allow-legacy" if (cwd == proj or cwd.startswith(proj + "/")) else "deny")
out("allow-legacy")  # eşleşen route yok → global tık (routing hatası köprüyü kilitlemesin)
PYEOF
)
verdict="${verdict:-allow-legacy}"
[ "$verdict" = "deny" ] && exit 0

# ── tüketim (exactly-once) ──
find "$D" -name '.consumed-*' -mmin +120 -delete 2>/dev/null || true
mode="${verdict#allow-}"
case "$verdict" in
  allow-bound|allow-lazy)
    # bağlı/lazy-bağlanmış session zaten TEK alıcı → session-başı marker yeter
    M="$D/.consumed-$h-$sid"
    [ -f "$M" ] && exit 0
    : > "$M"
    ;;
  *)
    if [ "${CLICK_BRIDGE_BROADCAST:-0}" = "1" ]; then
      mode="legacy-bcast"
      M="$D/.consumed-$h-$sid"
      [ -f "$M" ] && exit 0
      : > "$M"
    else
      mode="legacy"
      M="$D/.consumed"
      [ -f "$M" ] && [ "$(cat "$M" 2>/dev/null)" = "$h" ] && exit 0
      printf '%s' "$h" > "$M"
    fi
    ;;
esac

printf '{"ts":%s,"iso":"%s","session":"%s","click_hash":"%s","click_age_s":%s,"mode":"%s"}\n' \
  "$now" "$(date -Is)" "$sid" "$h" "$age" "$mode" >> "$D/delivery.jsonl"

echo "[CLICK-BRIDGE] Kullanıcı ${age}s önce tarayıcıda şu UI elementine tıkladı (~/.click-bridge/last.json):"
cat "$F"
echo ""
echo "Prompt bu elemente/component'e atıfta bulunuyorsa bu bağlamı kullan. ÖNCELİK SIRASI:"
echo "1) component + source (dosya:satır) → doğrudan ilgili koda git"
echo "2) console_errors doluysa → ÖNCE hataları analiz et (kök neden genelde orada)"
echo "3) failed_requests doluysa → backend/endpoint/network sorununu değerlendir"
echo "4) box (padding/margin/boyut) → görsel/yerleşim şikayetlerinde kullan"
echo "Derin canlı analiz gerekirse: chrome-devtools MCP (list_console_messages, list_network_requests, take_screenshot, performance_start_trace) veya playwright MCP ile sayfayı incele. Geçmiş tıklamalar: ~/.click-bridge/history.jsonl · Detay: Skill 'click-bridge'"
exit 0
