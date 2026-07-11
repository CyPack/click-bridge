#!/usr/bin/env bash
# click-bridge UserPromptSubmit hook v3 — multi-session-aware enjeksiyon.
# Varsayılan: EXACTLY-ONCE — tıklama, tıklamadan sonra İLK prompt yazılan session'a gider (hangi
#             session'a yazarsan ona). Diğer session'lar aynı tıkı görmez (gürültü yok).
# CLICK_BRIDGE_BROADCAST=1 → her session aynı tıkı BİRER kez alır (aynı işi izleyen paralel session'lar için).
# Teslimat kaydı: ~/.click-bridge/delivery.jsonl (hangi session hangi tıkı ne zaman aldı — instance takibi).
set -u
D="$HOME/.click-bridge"
F="$D/last.json"
[ -f "$F" ] || exit 0

# hook stdin JSON'undan session kimliği
in=$(cat - 2>/dev/null || true)
sid=$(printf '%s' "$in" | jq -r '.session_id // "unknown"' 2>/dev/null | cut -c1-12)
[ -n "$sid" ] || sid=unknown

now=$(date +%s)
mtime=$(stat -c %Y "$F" 2>/dev/null) || exit 0
age=$(( now - mtime ))
[ "$age" -le 300 ] || exit 0

h=$(md5sum "$F" | cut -d' ' -f1)

# eski broadcast marker'larını temizle (birikme önleme)
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
