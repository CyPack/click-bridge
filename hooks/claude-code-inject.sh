#!/usr/bin/env bash
# click-bridge UserPromptSubmit hook v3 — multi-session-aware injection.
# Default: EXACTLY-ONCE — a click goes to the FIRST session that submits a prompt after the
#          click happened (whichever session you type into gets it). Other sessions never see
#          the same click (no noise).
# CLICK_BRIDGE_BROADCAST=1 → every session gets the same click ONCE each (for parallel sessions
#          watching the same piece of work).
# Delivery log: ~/.click-bridge/delivery.jsonl (which session got which click, and when — instance tracking).
set -u
D="$HOME/.click-bridge"
F="$D/last.json"
[ -f "$F" ] || exit 0

# session id + working directory from the hook's stdin JSON
in=$(cat - 2>/dev/null || true)
sid=$(printf '%s' "$in" | jq -r '.session_id // "unknown"' 2>/dev/null | cut -c1-12)
[ -n "$sid" ] || sid=unknown
scwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)

# PROJECT ROUTING: if the click's URL matches a project in routes.json,
# ONLY sessions whose cwd is under that project receive it (avoids cross-project noise).
if [ -f "$D/routes.json" ] && [ -n "$scwd" ]; then
  verdict=$(python3 - "$F" "$D/routes.json" "$scwd" <<'PYEOF' 2>/dev/null
import json, sys
try:
    click = json.load(open(sys.argv[1]))
    routes = json.load(open(sys.argv[2])).get("routes", [])
    cwd = sys.argv[3]
    url = click.get("url", "") or ""
    for r in routes:
        pat, proj = r.get("url_contains", ""), r.get("project", "")
        if pat and proj and pat in url:
            print("allow" if cwd.startswith(proj) else "deny")
            sys.exit(0)
    print("allow")  # no matching route → global click
except Exception:
    print("allow")  # a routing error must NEVER lock up the bridge
PYEOF
)
  [ "$verdict" = "deny" ] && exit 0
fi

now=$(date +%s)
mtime=$(stat -c %Y "$F" 2>/dev/null) || exit 0
age=$(( now - mtime ))
[ "$age" -le 300 ] || exit 0

h=$(md5sum "$F" | cut -d' ' -f1)

# clean up old broadcast markers (avoid unbounded accumulation)
find "$D" -name '.consumed-*' -mmin +120 -delete 2>/dev/null || true

if [ "${CLICK_BRIDGE_BROADCAST:-0}" = "1" ]; then
  M="$D/.consumed-$h-$sid"
  [ -f "$M" ] && exit 0
  : > "$M"
else
  M="$D/.consumed"
  [ -f "$M" ] && [ "$(cat "$M" 2>/dev/null)" = "$h" ] && exit 0
  printf '%s' "$h" > "$M"
fi

printf '{"ts":%s,"iso":"%s","session":"%s","click_hash":"%s","click_age_s":%s}\n' \
  "$now" "$(date -Is)" "$sid" "$h" "$age" >> "$D/delivery.jsonl"

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
