#!/usr/bin/env bash
# Dashboard rendering primitives for monitor scripts.
# Uses the alternate screen buffer and absolute cursor positioning
# for flicker-free, scroll-free in-place rendering.
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

# Trap to restore terminal on exit
_dashboard_cleanup() {
  _dashboard_leave_alt_screen
}

# Register cleanup — scripts should call this after setting DASHBOARD_ENABLED
dashboard_register_cleanup() {
  trap '_dashboard_cleanup' EXIT
}

begin_dashboard_render() {
  DASHBOARD_CURRENT_RENDER_LINES=0
  _dashboard_enter_alt_screen
  printf '\033[H'       # move cursor to top-left
  printf '\033[2J'      # clear entire screen
}

print_dashboard_line() {
  local line="$1"

  printf '%s\n' "$line"
  DASHBOARD_CURRENT_RENDER_LINES=$(( DASHBOARD_CURRENT_RENDER_LINES + 1 ))
}

print_dashboard_linef() {
  local format="$1"
  shift || true

  printf "$format" "$@"
  printf '\n'
  DASHBOARD_CURRENT_RENDER_LINES=$(( DASHBOARD_CURRENT_RENDER_LINES + 1 ))
}

end_dashboard_render() {
  DASHBOARD_LAST_RENDER_LINES="$DASHBOARD_CURRENT_RENDER_LINES"
}
