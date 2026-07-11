#!/usr/bin/env bash
# click-bridge UserPromptSubmit hook v4 — SESSION-WIRED delivery (token ↔ session binding).
#
# Layers (in priority order):
#   1) TOKENED click (payload has cb_token — tab opened via dev-browser.sh with #cb=TOKEN):
#      - bound   → ONLY the bound session_id receives it (deterministic; multi-session
#                  collisions are impossible)
#      - pending → ONLY the session of the claude process that launched dev-browser receives
#                  it (process-ancestry PID match), and the binding locks to that session_id
#      - unknown → lazy-bind: the first session that submits a prompt receives it AND the
#                  token binds to that session
#   2) TOKENLESS click (legacy): routes.json cwd path-BOUNDED prefix match + exactly-once
#      (CLICK_BRIDGE_BROADCAST=1 → every session once). Backward compatible with v3.
#
# Delivery log: delivery.jsonl (mode=bound|lazy|legacy|legacy-bcast)
# Binding log:  bindings.jsonl (append-only, 48h TTL, race-free via flock)
# Test isolation: run with CLICK_BRIDGE_DIR=/tmp/x to leave live state untouched.
set -u
D="${CLICK_BRIDGE_DIR:-$HOME/.click-bridge}"
F="$D/last.json"
[ -f "$F" ] || exit 0

LIB="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/cb-lib.sh"
[ -f "$LIB" ] && . "$LIB"

# session id + working directory from the hook's stdin JSON
in=$(cat - 2>/dev/null || true)
sid=$(printf '%s' "$in" | jq -r '.session_id // "unknown"' 2>/dev/null | cut -c1-12)
[ -n "$sid" ] || sid=unknown
scwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)

now=$(date +%s)
mtime=$(stat -c %Y "$F" 2>/dev/null) || exit 0
age=$(( now - mtime ))
[ "$age" -le 300 ] || exit 0
h=$(md5sum "$F" | cut -d' ' -f1)

# which claude process is this hook running under? (for pending-binding matching)
my_claude_pid=""
command -v cb_find_claude_pid >/dev/null 2>&1 && my_claude_pid=$(cb_find_claude_pid || true)

# ── decision: token/binding/route in one pass (flock guards concurrent prompts) ──
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
    out("allow-legacy")  # an unreadable click must NEVER lock up the bridge

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
            out("deny")  # the owner is known and alive but is not this session — do NOT steal
        # owner dead/unknown → fall through to lazy
    append({"token": token, "state": "bound", "session_id": sid, "via": "lazy"})
    out("allow-lazy")

# no token → legacy routing (path-BOUNDED prefix: my-app-backups ≠ my-app)
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
out("allow-legacy")  # no matching route → global click (a routing error must never block)
PYEOF
)
verdict="${verdict:-allow-legacy}"
[ "$verdict" = "deny" ] && exit 0

# ── consumption (exactly-once) ──
find "$D" -name '.consumed-*' -mmin +120 -delete 2>/dev/null || true
mode="${verdict#allow-}"
case "$verdict" in
  allow-bound|allow-lazy)
    # a bound/lazy-bound session is already the SOLE receiver → per-session marker suffices
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

echo "[CLICK-BRIDGE] The user Alt+Clicked this UI element in the browser ${age}s ago (~/.click-bridge/last.json):"
cat "$F"
echo ""
echo "If the prompt refers to this element/component, use this context. PRIORITY ORDER:"
echo "1) component + source (file:line) → go straight to the relevant code"
echo "2) if console_errors is non-empty → analyze the errors FIRST (the root cause is usually there)"
echo "3) if failed_requests is non-empty → check the backend/endpoint/network issue"
echo "4) box (padding/margin/size) → use for visual/layout complaints"
echo "For deeper live analysis: use the chrome-devtools MCP (list_console_messages, list_network_requests, take_screenshot, performance_start_trace) or the playwright MCP to inspect the page. Past clicks: ~/.click-bridge/history.jsonl"
exit 0
