#!/usr/bin/env bash
# Dashboard rendering primitives for monitor scripts.
# Uses the alternate screen buffer with per-line erase for
# flicker-free, scroll-free in-place rendering.
# Usage: source "${SCRIPT_DIR}/lib/monitor-dashboard.sh"

[[ -n "${_MONITOR_DASHBOARD_LOADED:-}" ]] && return 0
_MONITOR_DASHBOARD_LOADED=1

SCRIPT_DIR_DASHBOARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR_DASHBOARD}/monitor-core.sh"
unset SCRIPT_DIR_DASHBOARD

# Whether we've entered the alternate screen buffer
_DASHBOARD_ALT_SCREEN=0

_dashboard_enter_alt_screen() {
  if (( _DASHBOARD_ALT_SCREEN == 0 )) && (( DASHBOARD_ENABLED == 1 )); then
    printf '\033[?1049h'  # enter alternate screen buffer
    printf '\033[?25l'    # hide cursor
    _DASHBOARD_ALT_SCREEN=1
  fi
}

_dashboard_leave_alt_screen() {
  if (( _DASHBOARD_ALT_SCREEN == 1 )); then
    printf '\033[?25h'    # show cursor
    printf '\033[?1049l'  # leave alternate screen buffer
    _DASHBOARD_ALT_SCREEN=0
  fi
}

begin_dashboard_render() {
  DASHBOARD_CURRENT_RENDER_LINES=0
  _dashboard_enter_alt_screen
  printf '\033[H'         # move cursor to row 1, col 1
}

print_dashboard_line() {
  local line="$1"

  printf '\033[2K%s\n' "$line"   # erase current line, then print
  DASHBOARD_CURRENT_RENDER_LINES=$(( DASHBOARD_CURRENT_RENDER_LINES + 1 ))
}

print_dashboard_linef() {
  local format="$1"
  shift || true

  printf '\033[2K'               # erase current line
  printf "$format" "$@"
  printf '\n'
  DASHBOARD_CURRENT_RENDER_LINES=$(( DASHBOARD_CURRENT_RENDER_LINES + 1 ))
}

end_dashboard_render() {
  # Clear any leftover lines from a previous longer render
  if (( DASHBOARD_LAST_RENDER_LINES > DASHBOARD_CURRENT_RENDER_LINES )); then
    local extra=$(( DASHBOARD_LAST_RENDER_LINES - DASHBOARD_CURRENT_RENDER_LINES ))
    local i
    for (( i = 0; i < extra; i++ )); do
      printf '\033[2K\n'
    done
  fi
  DASHBOARD_LAST_RENDER_LINES="$DASHBOARD_CURRENT_RENDER_LINES"
}
