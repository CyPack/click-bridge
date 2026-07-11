# cb-lib.sh — shared click-bridge helpers (sourced by the hook and dev-browser).
# Contents: claude-CLI ancestor PID finder (the foundation of session wiring).
#
# WHY argv0-based matching: commands launched from Claude Code's Bash tool run inside
# intermediate shells whose cmdline may contain "claude" as a substring (e.g. paths under
# ~/.claude/), so substring matching would mis-identify those shells. Only a process whose
# argv0 basename is "claude" (or node + argv1=claude) is treated as the CLI itself.

# Prints the PID of the nearest claude-CLI ancestor to stdout; returns 1 if none found.
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
