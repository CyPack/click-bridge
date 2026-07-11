#!/usr/bin/env bash
# click-bridge UserPromptSubmit hook — tarayıcıda son tıklanan elementi prompt bağlamına enjekte eder.
# Taze (<=300s) ve daha önce enjekte edilmemiş ise last.json içeriğini basar; aksi halde sessiz çıkar.
set -u
F="$HOME/.click-bridge/last.json"
M="$HOME/.click-bridge/.consumed"
[ -f "$F" ] || exit 0
now=$(date +%s)
mtime=$(stat -c %Y "$F" 2>/dev/null) || exit 0
age=$(( now - mtime ))
[ "$age" -le 300 ] || exit 0
h=$(md5sum "$F" | cut -d' ' -f1)
if [ -f "$M" ] && [ "$(cat "$M" 2>/dev/null)" = "$h" ]; then exit 0; fi
printf '%s' "$h" > "$M"
echo "[CLICK-BRIDGE] Kullanıcı ${age}s önce tarayıcıda şu UI elementine tıkladı (~/.click-bridge/last.json):"
cat "$F"
echo ""
echo "Prompt bu elemente/component'e atıfta bulunuyorsa bu bağlamı kullan. Geçmiş tıklamalar: ~/.click-bridge/history.jsonl"
exit 0
