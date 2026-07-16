#!/usr/bin/env bash
# pair-url — generates a URL that wires a tab opened on a REMOTE device (Tailscale) to THIS
# Claude session. The remote counterpart of dev-browser.sh: we can't launch the browser over
# there, so the user opens the printed URL on the remote device instead.
# Usage: pair-url.sh <url>    (e.g. http://100.x.y.z:8770/)
#        pair-url.sh <port>   (shorthand → prints both the local and the Tailscale URL)
set -u
. "$(dirname "$0")/../cb-lib.sh" 2>/dev/null || true
ARG="${1:?usage: pair-url.sh <url|port>}"

TOK=$(uuidgen 2>/dev/null | tr -d '-' | cut -c1-10)
[ -n "$TOK" ] || TOK="t$$$(date +%s)"
CPID=""
command -v cb_find_claude_pid >/dev/null 2>&1 && CPID=$(cb_find_claude_pid || true)
CBD="$HOME/.click-bridge"
mkdir -p "$CBD"
if [[ "$ARG" =~ ^[0-9]+$ ]]; then REC_URL="http://127.0.0.1:$ARG/"; else REC_URL="$ARG"; fi
# Store the base URL so external consumers can reopen the preview after its tab closes.
BINDING_JSON=$(python3 - "$TOK" "${CPID:-}" "$REC_URL" "$(date +%s)" <<'PYEOF'
import json, sys

token, claude_pid, url, ts = sys.argv[1:]
print(json.dumps({
    "token": token,
    "state": "pending",
    "claude_pid": int(claude_pid) if claude_pid else None,
    "url": url,
    "ts": int(ts),
}, separators=(",", ":")))
PYEOF
)
flock "$CBD/.bindings.lock" sh -c 'printf "%s\n" "$1" >> "$2"' _ \
  "$BINDING_JSON" "$CBD/bindings.jsonl"

wire() { case "$1" in *\#*) echo "$1&cb=$TOK" ;; *) echo "$1#cb=$TOK" ;; esac; }

if [[ "$ARG" =~ ^[0-9]+$ ]]; then
  TS=$(tailscale ip -4 2>/dev/null | head -1)
  echo "🔗 local    : $(wire "http://127.0.0.1:$ARG/")"
  [ -n "$TS" ] && echo "🔗 tailscale: $(wire "http://$TS:$ARG/")"
else
  echo "🔗 $(wire "$ARG")"
fi
echo "   token=$TOK claude_pid=${CPID:-none→lazy-bind} — clicks from the tab that opens this URL go ONLY to this session"
