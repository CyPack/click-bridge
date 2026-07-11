#!/usr/bin/env bash
# click-bridge self-heal — TESPIT + ONARIM + RAPOR (saatlik timer: click-bridge-heal.timer)
# Onarabildiğini onarır (servis restart, bozuk last.json karantina), onaramadığını loglar.
# Log: ~/.click-bridge/_health.log · Exit 0 = sağlıklı/onarıldı, 1 = insan müdahalesi gerekli
set -u
D="$HOME/.click-bridge"
LOG="$D/_health.log"
fix=0; fail=0
mkdir -p "$D" 2>/dev/null
log() { echo "[$(date -Is)] $*" >> "$LOG"; }

# 1) veri dizini yazılabilir mi
[ -w "$D" ] || { log "FAIL: veri dizini yazılamıyor: $D"; fail=1; }

# 2) bozuk last.json → karantinaya al (köprüyü kilitlemesin)
if [ -f "$D/last.json" ] && ! python3 -m json.tool "$D/last.json" >/dev/null 2>&1; then
  mv "$D/last.json" "$D/last.json.corrupt-$(date +%s)"
  log "HEAL: bozuk last.json karantinaya alındı"; fix=1
fi

# 3) servisler ayakta mı → değilse restart
for svc in click-bridge click-bridge-demo; do
  if ! systemctl --user is-active --quiet "$svc"; then
    systemctl --user restart "$svc" 2>/dev/null; sleep 1
    if systemctl --user is-active --quiet "$svc"; then log "HEAL: $svc restart edildi"; fix=1
    else log "FAIL: $svc restart'a rağmen kalkmadı"; fail=1; fi
  fi
done

# 4) endpoint gerçekten yanıt veriyor mu (servis active ama port ölü olabilir)
if ! curl -sf -m 3 http://127.0.0.1:7823/health >/dev/null 2>&1; then
  systemctl --user restart click-bridge 2>/dev/null; sleep 1
  if curl -sf -m 3 http://127.0.0.1:7823/health >/dev/null 2>&1; then log "HEAL: 7823 restart ile döndü"; fix=1
  else log "FAIL: 7823 yanıt vermiyor"; fail=1; fi
fi
curl -sf -m 3 http://127.0.0.1:7823/snippet.js 2>/dev/null | grep -q __clickBridgeLoaded \
  || { log "FAIL: snippet.js eksik/bozuk servis ediliyor"; fail=1; }

# 5) hook kaydı settings.json'da duruyor mu (otomatik onarma — settings korumalı; tespit+rapor)
grep -q "click-bridge-inject.sh" "$HOME/.claude/settings.json" 2>/dev/null \
  || { log "FAIL: hook kaydı settings.json'dan KAYBOLMUŞ — elle onarım: skill click-bridge §6"; fail=1; }

# 6) hook smoke test (bozuk script sessizce her prompt'u yavaşlatmasın)
echo '{}' | "$HOME/projects/click-bridge/click-bridge-inject.sh" >/dev/null 2>&1 \
  || { log "FAIL: click-bridge-inject.sh smoke test düştü"; fail=1; }

# 7) history.jsonl şişme kontrolü (>50MB → sıkıştır-arşivle, SİLME)
if [ -f "$D/history.jsonl" ] && [ "$(stat -c %s "$D/history.jsonl")" -gt 52428800 ]; then
  gzip -c "$D/history.jsonl" > "$D/history-$(date +%Y%m%d).jsonl.gz" && : > "$D/history.jsonl"
  log "HEAL: history.jsonl arşivlendi (gzip, silinmedi)"; fix=1
fi

# log rotasyonu (kendi logu 1MB'ı geçmesin)
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 1048576 ] && tail -200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

[ "$fix" -eq 0 ] && [ "$fail" -eq 0 ] && log "OK: tüm kontroller temiz"
exit "$fail"
