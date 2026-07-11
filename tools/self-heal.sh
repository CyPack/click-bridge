#!/usr/bin/env bash
# click-bridge self-heal — DETECT + REPAIR + REPORT (hourly timer: click-bridge-heal.timer)
# Repairs what it can (service restart, quarantine a corrupt last.json), logs what it can't.
# Log: ~/.click-bridge/_health.log · Exit 0 = healthy/repaired, 1 = needs human attention
set -u
D="$HOME/.click-bridge"
LOG="$D/_health.log"
fix=0; fail=0
mkdir -p "$D" 2>/dev/null
log() { echo "[$(date -Is)] $*" >> "$LOG"; }

# 1) is the data dir writable
[ -w "$D" ] || { log "FAIL: data dir not writable: $D"; fail=1; }

# 2) corrupt last.json → quarantine it (don't let it wedge the bridge)
if [ -f "$D/last.json" ] && ! python3 -m json.tool "$D/last.json" >/dev/null 2>&1; then
  mv "$D/last.json" "$D/last.json.corrupt-$(date +%s)"
  log "HEAL: quarantined a corrupt last.json"; fix=1
fi

# 3) are the services up → restart if not
for svc in click-bridge click-bridge-demo; do
  if ! systemctl --user is-active --quiet "$svc"; then
    systemctl --user restart "$svc" 2>/dev/null; sleep 1
    if systemctl --user is-active --quiet "$svc"; then log "HEAL: restarted $svc"; fix=1
    else log "FAIL: $svc still down after restart"; fail=1; fi
  fi
done

# 4) does the endpoint actually respond (service can be active but the port dead)
if ! curl -sf -m 3 http://127.0.0.1:7823/health >/dev/null 2>&1; then
  systemctl --user restart click-bridge 2>/dev/null; sleep 1
  if curl -sf -m 3 http://127.0.0.1:7823/health >/dev/null 2>&1; then log "HEAL: 7823 recovered after restart"; fix=1
  else log "FAIL: 7823 not responding"; fail=1; fi
fi
curl -sf -m 3 http://127.0.0.1:7823/snippet.js 2>/dev/null | grep -q __clickBridgeLoaded \
  || { log "FAIL: snippet.js is missing or serving corrupt content"; fail=1; }

# 5) is the hook registered in settings.json (not auto-repaired — settings are user-owned; detect+report)
grep -q "claude-code-inject.sh" "$HOME/.claude/settings.json" 2>/dev/null \
  || { log "FAIL: hook entry MISSING from settings.json — re-add the UserPromptSubmit hook manually (see README § Claude Code integration)"; fail=1; }

# 6) hook smoke test (a broken script shouldn't silently slow down every prompt)
echo '{}' | "$HOME/projects/click-bridge/hooks/claude-code-inject.sh" >/dev/null 2>&1 \
  || { log "FAIL: claude-code-inject.sh failed its smoke test"; fail=1; }

# 7) history.jsonl bloat check (>50MB → gzip-archive, DO NOT DELETE)
if [ -f "$D/history.jsonl" ] && [ "$(stat -c %s "$D/history.jsonl")" -gt 52428800 ]; then
  gzip -c "$D/history.jsonl" > "$D/history-$(date +%Y%m%d).jsonl.gz" && : > "$D/history.jsonl"
  log "HEAL: archived history.jsonl (gzip, not deleted)"; fix=1
fi

# log rotation (keep our own log under 1MB)
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 1048576 ] && tail -200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

[ "$fix" -eq 0 ] && [ "$fail" -eq 0 ] && log "OK: all checks clean"
exit "$fail"
