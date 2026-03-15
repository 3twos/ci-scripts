#!/usr/bin/env bash
# Line-by-line dashboard rendering primitives for monitor scripts.
# Uses ANSI escape codes to overwrite previous lines in-place.
# Usage: source "${SCRIPT_DIR}/lib/monitor-dashboard.sh"

[[ -n "${_MONITOR_DASHBOARD_LOADED:-}" ]] && return 0
_MONITOR_DASHBOARD_LOADED=1

SCRIPT_DIR_DASHBOARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR_DASHBOARD}/monitor-core.sh"
unset SCRIPT_DIR_DASHBOARD

begin_dashboard_render() {
  DASHBOARD_CURRENT_RENDER_LINES=0
  if (( DASHBOARD_LAST_RENDER_LINES > 0 )); then
    printf '\033[%dA' "$DASHBOARD_LAST_RENDER_LINES"
  fi
}

print_dashboard_line() {
  local line="$1"

  printf '\r\033[2K%s\n' "$line"
  DASHBOARD_CURRENT_RENDER_LINES=$(( DASHBOARD_CURRENT_RENDER_LINES + 1 ))
}

print_dashboard_linef() {
  local format="$1"
  shift || true

  printf '\r\033[2K'
  printf "$format" "$@"
  printf '\n'
  DASHBOARD_CURRENT_RENDER_LINES=$(( DASHBOARD_CURRENT_RENDER_LINES + 1 ))
}

end_dashboard_render() {
  local extra_lines i

  if (( DASHBOARD_LAST_RENDER_LINES > DASHBOARD_CURRENT_RENDER_LINES )); then
    extra_lines=$(( DASHBOARD_LAST_RENDER_LINES - DASHBOARD_CURRENT_RENDER_LINES ))
    for (( i = 0; i < extra_lines; i++ )); do
      printf '\r\033[2K\n'
    done
    printf '\033[%dA' "$extra_lines"
  fi

  DASHBOARD_LAST_RENDER_LINES="$DASHBOARD_CURRENT_RENDER_LINES"
}
