#!/usr/bin/env bash
# Audio queue infrastructure and speaker detection for monitor scripts.
# Uses file descriptor 9 for the FIFO-based audio queue.
#
# Cross-process speech locking: multiple monitor scripts sharing this library
# will not overlap speech. A shared lockfile serializes TTS invocations.
#
# To handle custom audio event kinds (e.g., "beat" in the Vercel monitor),
# define _audio_queue_custom_handler() before calling start_audio_queue_worker.
# It receives (event_kind, event_payload) and should return 0 if handled.
#
# Usage: source "${SCRIPT_DIR}/lib/monitor-audio.sh"

[[ -n "${_MONITOR_AUDIO_LOADED:-}" ]] && return 0
_MONITOR_AUDIO_LOADED=1

SCRIPT_DIR_AUDIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR_AUDIO}/monitor-core.sh"
unset SCRIPT_DIR_AUDIO

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

RUNTIME_DIR="${RUNTIME_DIR:-}"
AUDIO_QUEUE_ENABLED="${AUDIO_QUEUE_ENABLED:-0}"
AUDIO_QUEUE_PID="${AUDIO_QUEUE_PID:-}"
AUDIO_QUEUE_PIPE="${AUDIO_QUEUE_PIPE:-}"
SPEAKER_CMD="${SPEAKER_CMD:-}"
# SPEAKER_ARGS — extra arguments passed to the speaker command (e.g., "-v Karen" for macOS say).
# Set by the sourcing script before calling start_audio_queue_worker.
if [[ -z "${SPEAKER_ARGS+x}" ]]; then
  SPEAKER_ARGS=()
fi

# Shared lockfile path for cross-process speech serialization.
SPEECH_LOCK_FILE="${TMPDIR:-/tmp}/monitor-speech.lock"
# Lock method: "shlock" (macOS), "flock" (Linux), or "none".
SPEECH_LOCK_METHOD="none"

# ---------------------------------------------------------------------------
# Runtime directory
# ---------------------------------------------------------------------------

# ensure_runtime_dir [prefix]
#   Creates a temp directory if one doesn't exist yet.
#   prefix defaults to "monitor" if not provided.
ensure_runtime_dir() {
  local prefix="${1:-monitor}"

  if [[ -n "${RUNTIME_DIR:-}" && -d "${RUNTIME_DIR}" ]]; then
    return 0
  fi

  if ! RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX" 2>/dev/null)"; then
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Speaker detection
# ---------------------------------------------------------------------------

# detect_speaker_cmd
#   Sets SPEAKER_CMD to the first available TTS command.
#   Also detects the best available locking method for cross-process speech.
#   Call after parsing --no-speak (check ENABLE_SPEAK yourself).
detect_speaker_cmd() {
  SPEAKER_CMD=""
  if command -v say >/dev/null 2>&1; then
    SPEAKER_CMD="say"
  elif command -v spd-say >/dev/null 2>&1; then
    SPEAKER_CMD="spd-say"
    # spd-say is async by default; add --wait so the speech lock is held
    # until audio finishes, preventing overlap across processes.
    SPEAKER_ARGS=("--wait" "${SPEAKER_ARGS[@]+"${SPEAKER_ARGS[@]}"}")
  elif command -v espeak >/dev/null 2>&1; then
    SPEAKER_CMD="espeak"
  else
    warn_line "Speech command not found (checked: say, spd-say, espeak). Alerts will be text-only."
  fi

  # Detect lock method for cross-process speech serialization.
  SPEECH_LOCK_METHOD="none"
  if command -v shlock >/dev/null 2>&1; then
    SPEECH_LOCK_METHOD="shlock"
  elif command -v flock >/dev/null 2>&1; then
    SPEECH_LOCK_METHOD="flock"
  fi
}

# ---------------------------------------------------------------------------
# Cross-process speech lock
# ---------------------------------------------------------------------------

# _acquire_speech_lock
#   Blocks until the shared speech lock is acquired.
_acquire_speech_lock() {
  case "$SPEECH_LOCK_METHOD" in
    shlock)
      # shlock -f <file> -p <pid>: creates lockfile containing the PID.
      # shlock succeeds immediately if the lockfile doesn't exist or the PID inside is dead.
      # Loop with short sleep since shlock returns immediately on contention.
      local attempts=0 lock_pid
      while ! shlock -f "$SPEECH_LOCK_FILE" -p $$; do
        attempts=$(( attempts + 1 ))
        if (( attempts > 100 )); then
          # After ~10s, only force-remove if the holding PID is no longer alive.
          lock_pid=""
          if [[ -f "$SPEECH_LOCK_FILE" ]]; then
            lock_pid="$(cat "$SPEECH_LOCK_FILE" 2>/dev/null)" || true
          fi
          if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -f "$SPEECH_LOCK_FILE" 2>/dev/null || true
          fi
          # Try once more, then give up to avoid blocking the poll loop.
          shlock -f "$SPEECH_LOCK_FILE" -p $$ || true
          break
        fi
        sleep 0.1
      done
      ;;
    flock)
      # Open the lockfile on fd 8 and acquire an exclusive lock (blocks until free).
      exec 8>"$SPEECH_LOCK_FILE"
      flock 8
      ;;
    *)
      # No locking available — proceed without serialization.
      ;;
  esac
}

# _release_speech_lock
#   Releases the shared speech lock.
_release_speech_lock() {
  case "$SPEECH_LOCK_METHOD" in
    shlock)
      rm -f "$SPEECH_LOCK_FILE" 2>/dev/null || true
      ;;
    flock)
      exec 8>&- 2>/dev/null || true
      ;;
    *)
      ;;
  esac
}

# _speak_with_lock <speaker_cmd> [speaker_args...] <message>
#   Acquires the cross-process lock, speaks, then releases the lock.
_speak_with_lock() {
  _acquire_speech_lock
  "$@" >/dev/null 2>&1 || true
  _release_speech_lock
}

# ---------------------------------------------------------------------------
# Audio queue worker
# ---------------------------------------------------------------------------

# Default custom handler — override before start_audio_queue_worker if needed.
if ! declare -F _audio_queue_custom_handler >/dev/null 2>&1; then
  _audio_queue_custom_handler() { return 1; }
fi

start_audio_queue_worker() {
  local event_kind event_payload

  if (( ENABLE_SPEAK == 0 )); then
    return
  fi
  if [[ -z "$SPEAKER_CMD" ]]; then
    return
  fi
  if (( AUDIO_QUEUE_ENABLED == 1 )); then
    return
  fi

  if ! ensure_runtime_dir "${RUNTIME_DIR_PREFIX:-monitor}"; then
    warn_line "Failed to create runtime dir for audio queue. Voice alerts may overlap."
    return
  fi

  AUDIO_QUEUE_PIPE="${RUNTIME_DIR}/audio.queue"
  rm -f "${AUDIO_QUEUE_PIPE}" >/dev/null 2>&1 || true
  if ! mkfifo "${AUDIO_QUEUE_PIPE}"; then
    warn_line "Failed to initialize audio queue FIFO. Voice alerts may overlap."
    AUDIO_QUEUE_PIPE=""
    return
  fi

  (
    while IFS=$'\x1f' read -r event_kind event_payload; do
      case "$event_kind" in
        speak)
          if [[ -n "$event_payload" && -n "$SPEAKER_CMD" ]]; then
            _speak_with_lock "$SPEAKER_CMD" "${SPEAKER_ARGS[@]+"${SPEAKER_ARGS[@]}"}" "$event_payload"
          fi
          ;;
        stop)
          break
          ;;
        *)
          # Try script-specific handler (custom handlers should also use _speak_with_lock if speaking)
          _audio_queue_custom_handler "$event_kind" "$event_payload" || true
          ;;
      esac
    done < "${AUDIO_QUEUE_PIPE}"
  ) &
  AUDIO_QUEUE_PID="$!"

  if ! exec 9> "${AUDIO_QUEUE_PIPE}"; then
    warn_line "Failed to open audio queue writer. Voice alerts may overlap."
    kill "${AUDIO_QUEUE_PID}" >/dev/null 2>&1 || true
    wait "${AUDIO_QUEUE_PID}" >/dev/null 2>&1 || true
    AUDIO_QUEUE_PID=""
    rm -f "${AUDIO_QUEUE_PIPE}" >/dev/null 2>&1 || true
    AUDIO_QUEUE_PIPE=""
    return
  fi

  AUDIO_QUEUE_ENABLED=1
}

stop_audio_queue_worker() {
  if (( AUDIO_QUEUE_ENABLED == 0 )); then
    return
  fi

  printf 'stop\x1f\n' >&9 || true
  exec 9>&- || true

  if [[ "${AUDIO_QUEUE_PID:-}" =~ ^[0-9]+$ ]]; then
    wait "${AUDIO_QUEUE_PID}" >/dev/null 2>&1 || true
  fi

  AUDIO_QUEUE_ENABLED=0
  AUDIO_QUEUE_PID=""
  AUDIO_QUEUE_PIPE=""
}

enqueue_audio_event() {
  local event_kind="$1"
  local event_payload="${2:-}"

  if (( AUDIO_QUEUE_ENABLED == 0 )); then
    return 1
  fi

  event_kind="$(sanitize_field "$event_kind")"
  event_payload="$(sanitize_field "$event_payload")"
  if [[ -z "$event_kind" ]]; then
    return 1
  fi

  printf '%s\x1f%s\n' "$event_kind" "$event_payload" >&9
}

speak_alert() {
  local message="$1"

  if [[ -z "$SPEAKER_CMD" ]]; then
    return
  fi

  if (( AUDIO_QUEUE_ENABLED == 1 )); then
    enqueue_audio_event "speak" "$message" || true
    return
  fi

  # Speak asynchronously so polling is not blocked.
  (
    _speak_with_lock "$SPEAKER_CMD" "${SPEAKER_ARGS[@]+"${SPEAKER_ARGS[@]}"}" "$message"
  ) &
}

# ---------------------------------------------------------------------------
# Desktop notifications (macOS Notification Center)
# ---------------------------------------------------------------------------

DESKTOP_NOTIFICATIONS="${DESKTOP_NOTIFICATIONS:-0}"

notify_desktop() {
  local title="$1"
  local message="$2"
  local level="${3:-info}"

  if (( DESKTOP_NOTIFICATIONS == 0 )); then
    return
  fi

  if ! command -v osascript >/dev/null 2>&1; then
    return
  fi

  local sound_name
  case "$level" in
    success) sound_name="Glass" ;;
    error)   sound_name="Sosumi" ;;
    warning) sound_name="Basso" ;;
    *)       sound_name="Pop" ;;
  esac

  osascript - "$title" "$message" "$sound_name" >/dev/null 2>&1 <<'APPLESCRIPT' &
on run argv
  display notification (item 2 of argv) with title (item 1 of argv) sound name (item 3 of argv)
end run
APPLESCRIPT
}

# ---------------------------------------------------------------------------
# Cleanup helper
# ---------------------------------------------------------------------------

# cleanup_audio_runtime
#   Stops audio queue and removes runtime dir.
#   Call from your script's own cleanup/trap handler.
cleanup_audio_runtime() {
  stop_audio_queue_worker

  if [[ -n "${RUNTIME_DIR:-}" && -d "${RUNTIME_DIR}" ]]; then
    rm -rf "${RUNTIME_DIR}" >/dev/null 2>&1 || true
  fi
}
