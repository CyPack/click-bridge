# cb-lib.sh — click-bridge ortak yardımcılar (hook + dev-browser source eder).
# İçerik: claude CLI ancestor PID bulucu (session-wiring'in temeli).
#
# NEDEN cmdline argv0 bazlı eşleşme: Bash tool komutları zsh -c '... ~/.claude/... ...'
# içinden çalışır; cmdline'da "claude" SUBSTRING araması ara kabukları yanlış eşler.
# Bu yüzden yalnızca argv0 basename'i "claude" olan (veya node + argv1=claude) process eşleşir.

# En yakın claude-CLI atasının PID'ini stdout'a yazar; bulamazsa 1 döner.
cb_find_claude_pid() {
  local pid=$$ depth=0 a0 a1 b0 b1 ppid
  while [ "$pid" -gt 1 ] && [ "$depth" -lt 20 ]; do
    a0=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n 1p)
    a1=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n 2p)
    b0=$(basename -- "${a0:-x}")
    b1=$(basename -- "${a1:-x}")
    if [ "$b0" = "claude" ] || { [ "${b0#node}" != "$b0" ] && [ "$b1" = "claude" ]; }; then
      echo "$pid"
      return 0
    fi
    ppid=$(grep -m1 '^PPid:' "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
    [ -n "$ppid" ] || return 1
    pid=$ppid
    depth=$((depth + 1))
  done
  return 1
}
