#!/usr/bin/env bash
# pair-url — UZAK cihazda (Tailscale) açılacak sekmeyi BU Claude session'ına kablolayan URL üretir.
# dev-browser.sh'ın uzak muadili: tarayıcıyı biz açamayız, kullanıcı çıkan URL'yi uzak cihazda açar.
# Kullanım: pair-url.sh <url>    (örn: http://100.75.115.68:8770/)
#           pair-url.sh <port>   (kısaltma → hem lokal hem tailscale URL basılır)
set -u
. "$(dirname "$0")/../cb-lib.sh" 2>/dev/null || true
ARG="${1:?kullanım: pair-url.sh <url|port>}"

TOK=$(uuidgen 2>/dev/null | tr -d '-' | cut -c1-10)
[ -n "$TOK" ] || TOK="t$$$(date +%s)"
CPID=""
command -v cb_find_claude_pid >/dev/null 2>&1 && CPID=$(cb_find_claude_pid || true)
CBD="$HOME/.click-bridge"
mkdir -p "$CBD"
flock "$CBD/.bindings.lock" sh -c 'printf "%s\n" "$1" >> "$2"' _ \
  "{\"token\":\"$TOK\",\"state\":\"pending\",\"claude_pid\":${CPID:-null},\"ts\":$(date +%s)}" \
  "$CBD/bindings.jsonl"

wire() { case "$1" in *\#*) echo "$1&cb=$TOK" ;; *) echo "$1#cb=$TOK" ;; esac; }

if [[ "$ARG" =~ ^[0-9]+$ ]]; then
  TS=$(tailscale ip -4 2>/dev/null | head -1)
  echo "🔗 lokal    : $(wire "http://127.0.0.1:$ARG/")"
  [ -n "$TS" ] && echo "🔗 tailscale: $(wire "http://$TS:$ARG/")"
else
  echo "🔗 $(wire "$ARG")"
fi
echo "   token=$TOK claude_pid=${CPID:-yok→lazy-bind} — bu URL'yi açan sekmenin tıkları SADECE bu session'a gider"
