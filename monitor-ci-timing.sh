#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/monitor-core.sh"
source "${SCRIPT_DIR}/lib/monitor-dashboard.sh"

usage() {
  cat <<'HELP'
Continuously monitor GitHub Actions CI timings and regressions (Ctrl+C to stop).

Usage:
  monitor-ci-timing.sh <owner/repo> [options]
  monitor-ci-timing.sh --repo <owner/repo> [options]

Arguments:
  <owner/repo>                     Repository slug (required; may also be passed via --repo)

Options:
  --repo <owner/repo>             Repository slug (alternative to positional argument)
  --workflow <name|id|file>       Workflow to monitor (default: CI)
  --branch <branch>               Branch to monitor (default: current git branch)
  --event <event>                 Optional event filter for branch runs (for example: pull_request, push)
  --baseline-branch <branch>      Baseline branch for regression comparison (default: main)
  --baseline-event <event>        Event filter for baseline (default: push)
  --window <count>                Number of runs used for trend stats (default: 20)
  --top-jobs <count>              Number of slowest jobs shown for latest run (default: 6)
  --regression-threshold <pct>    Alert threshold over baseline p50 total time (default: 20)
  -i, --interval <seconds>        Poll interval in seconds (default: 30)
  --timeout <seconds>             Optional timeout (default: 0, disabled)
  --plain                         Print line-by-line logs instead of dashboard view
  -h, --help                      Show help

Examples:
  # monitor PR CI on current branch with baseline on main
  monitor-ci-timing.sh 3twos/my-app --event pull_request --interval 20

  # monitor a specific workflow file and branch
  monitor-ci-timing.sh 3twos/my-app --workflow ci.yml --branch feature/my-branch --window 30
HELP
}

status_icon() {
  local status="$1"
  local conclusion="$2"

  if [[ "$status" == "queued" ]]; then
    printf '%s' "${C_BLUE}◑${C_RESET}"
    return
  fi
  if [[ "$status" == "in_progress" ]]; then
    printf '%s' "${C_YELLOW}⟳${C_RESET}"
    return
  fi
  if [[ "$status" == "completed" ]]; then
    case "$conclusion" in
      success) printf '%s' "${C_GREEN}✓${C_RESET}" ;;
      cancelled) printf '%s' "${C_DIM}■${C_RESET}" ;;
      failure|timed_out|action_required|stale) printf '%s' "${C_RED}✖${C_RESET}" ;;
      skipped|neutral) printf '%s' "${C_DIM}•${C_RESET}" ;;
      *) printf '%s' "?" ;;
    esac
    return
  fi

  printf '%s' "?"
}

state_label() {
  local status="$1"
  local conclusion="$2"

  case "$status" in
    queued) printf '%s' "${C_BLUE}Queued${C_RESET}" ;;
    in_progress) printf '%s' "${C_YELLOW}Running${C_RESET}" ;;
    completed)
      case "$conclusion" in
        success) printf '%s' "${C_GREEN}Success${C_RESET}" ;;
        cancelled) printf '%s' "${C_DIM}Canceled${C_RESET}" ;;
        failure) printf '%s' "${C_RED}Failed${C_RESET}" ;;
        timed_out) printf '%s' "${C_RED}Timed out${C_RESET}" ;;
        skipped) printf '%s' "${C_DIM}Skipped${C_RESET}" ;;
        *) printf '%s' "${conclusion:-Completed}" ;;
      esac
      ;;
    *) printf '%s' "${status:-Unknown}" ;;
  esac
}

render_progress_bar() {
  local percent="$1"
  local width="${2:-22}"
  local status="$3"
  local fill_count empty_count i bar spinner

  if ! [[ "$percent" =~ ^[0-9]+$ ]]; then
    percent=0
  fi
  if (( percent < 0 )); then
    percent=0
  fi
  if (( percent > 100 )); then
    percent=100
  fi

  fill_count=$(( (percent * width) / 100 ))
  empty_count=$(( width - fill_count ))

  bar=""
  for (( i = 0; i < fill_count; i++ )); do
    bar="${bar}█"
  done
  for (( i = 0; i < empty_count; i++ )); do
    bar="${bar}░"
  done

  if [[ "$status" == "in_progress" ]]; then
    case $(( $(date +%s) % 4 )) in
      0) spinner="⠋" ;;
      1) spinner="⠙" ;;
      2) spinner="⠸" ;;
      *) spinner="⠴" ;;
    esac
    printf '%s %s' "$bar" "$spinner"
    return
  fi

  printf '%s  ' "$bar"
}

percentile_value() {
  local percentile="$1"
  shift
  local values=("$@")
  local sorted rank idx n
  local old_ifs

  n="${#values[@]}"
  if (( n == 0 )); then
    printf '%s' "0"
    return
  fi

  old_ifs="${IFS:-$' \t\n'}"
  IFS=$'\n'
  sorted=($(printf '%s\n' "${values[@]}" | awk '/^-?[0-9]+$/' | sort -n))
  IFS="$old_ifs"
  n="${#sorted[@]}"
  if (( n == 0 )); then
    printf '%s' "0"
    return
  fi

  rank=$(( (percentile * n + 99) / 100 ))
  if (( rank < 1 )); then
    rank=1
  fi
  if (( rank > n )); then
    rank="$n"
  fi

  idx=$(( rank - 1 ))
  printf '%s' "${sorted[idx]}"
}

build_stats_triplet() {
  local values=("$@")
  local p50 p95

  if (( ${#values[@]} == 0 )); then
    printf '%s' "0|0"
    return
  fi

  p50="$(percentile_value 50 "${values[@]}")"
  p95="$(percentile_value 95 "${values[@]}")"
  printf '%s|%s' "$p50" "$p95"
}

fetch_actions_runs_json() {
  local branch="$1"
  local status_filter="$2"
  local event_filter="$3"
  local endpoint
  local -a cmd

  if [[ -n "$WORKFLOW_REF" ]]; then
    endpoint="/repos/${REPO_SLUG}/actions/workflows/${WORKFLOW_REF}/runs"
  else
    endpoint="/repos/${REPO_SLUG}/actions/runs"
  fi

  cmd=(gh api --method GET -H "Accept: application/vnd.github+json" "$endpoint" -f per_page="$WINDOW" -f branch="$branch")
  if [[ -n "$status_filter" ]]; then
    cmd+=(-f status="$status_filter")
  fi
  if [[ -n "$event_filter" ]]; then
    cmd+=(-f event="$event_filter")
  fi

  "${cmd[@]}"
}

fetch_run_jobs_json() {
  local run_id="$1"

  gh api --method GET -H "Accept: application/vnd.github+json" \
    "/repos/${REPO_SLUG}/actions/runs/${run_id}/jobs" \
    -f per_page=100
}

resolve_workflow_ref() {
  local candidate="$1"
  local workflows_json resolved

  if [[ -z "$candidate" ]]; then
    printf '%s' ""
    return
  fi

  if [[ "$candidate" =~ ^[0-9]+$ ]]; then
    printf '%s' "$candidate"
    return
  fi

  if [[ "$candidate" == *.yml || "$candidate" == *.yaml ]]; then
    printf '%s' "$candidate"
    return
  fi

  if ! workflows_json="$(gh api --method GET -H "Accept: application/vnd.github+json" "/repos/${REPO_SLUG}/actions/workflows" -f per_page=100)"; then
    print_error "Failed to list workflows for '${REPO_SLUG}'."
    return 1
  fi

  if ! resolved="$(printf '%s' "$workflows_json" | node -e '
const fs = require("node:fs");

const input = fs.readFileSync(0, "utf8");
const candidate = (process.argv[1] || "").trim().toLowerCase();

let payload;
try {
  payload = JSON.parse(input);
} catch {
  process.stdout.write("");
  process.exit(0);
}

const workflows = Array.isArray(payload.workflows) ? payload.workflows : [];

const normalize = (value) => String(value || "").trim().toLowerCase();
const basename = (value) => {
  const text = String(value || "");
  const parts = text.split("/");
  return parts[parts.length - 1] || "";
};

let found = null;
for (const workflow of workflows) {
  const name = normalize(workflow?.name);
  const path = normalize(workflow?.path);
  const file = normalize(basename(workflow?.path));
  if (candidate && (name === candidate || path === candidate || file === candidate)) {
    found = workflow;
    break;
  }
}

if (!found) {
  process.stdout.write("");
  process.exit(0);
}

if (found.id != null) {
  process.stdout.write(String(found.id));
}
' "$candidate")"; then
    print_error "Failed to resolve workflow '${candidate}'."
    return 1
  fi

  if [[ -z "$resolved" ]]; then
    print_error "Workflow '${candidate}' not found in '${REPO_SLUG}'."
    return 1
  fi

  printf '%s' "$resolved"
}

parse_runs_payload() {
  node -e '
const fs = require("node:fs");

const input = fs.readFileSync(0, "utf8");
let payload;

try {
  payload = JSON.parse(input);
} catch (error) {
  console.error(`PARSE_ERROR\t${error.message}`);
  process.exit(2);
}

if (payload && typeof payload.message === "string" && payload.message.length > 0) {
  const text = payload.message.replace(/[\n\r\t]+/g, " ").trim();
  console.error(`API_ERROR\t${text}`);
  process.exit(3);
}

const runs = Array.isArray(payload.workflow_runs) ? payload.workflow_runs : [];
const nowMs = Date.now();

const safe = (value) =>
  String(value ?? "")
    .replace(/\u001f/g, " ")
    .replace(/[\n\r\t]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();

const toMs = (value) => {
  if (typeof value !== "string" || value.length === 0) return 0;
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) return 0;
  return Math.trunc(parsed);
};

for (const run of runs) {
  const id = run?.id != null ? String(run.id) : "";
  if (!id) continue;

  const runNumber = run?.run_number != null ? String(run.run_number) : "";
  const workflowName = safe(run?.name);
  const status = safe(run?.status || "").toLowerCase();
  const conclusion = safe(run?.conclusion || "").toLowerCase();
  const event = safe(run?.event || "");
  const headBranch = safe(run?.head_branch || "");
  const headSha = safe(run?.head_sha || "");
  const title = safe(run?.display_title || run?.head_commit?.message || "");
  const htmlUrl = safe(run?.html_url || "");

  const createdAtMs = toMs(run?.created_at);
  const startedAtMs = toMs(run?.run_started_at);
  const updatedAtMs = toMs(run?.updated_at);

  const endMs = status === "completed" && updatedAtMs > 0 ? updatedAtMs : nowMs;
  const queueSeconds = createdAtMs > 0 && startedAtMs > createdAtMs
    ? Math.max(0, Math.floor((startedAtMs - createdAtMs) / 1000))
    : (status === "queued" && createdAtMs > 0
      ? Math.max(0, Math.floor((endMs - createdAtMs) / 1000))
      : 0);

  const execStart = startedAtMs > 0 ? startedAtMs : 0;
  const execSeconds = execStart > 0 ? Math.max(0, Math.floor((endMs - execStart) / 1000)) : 0;
  const totalSeconds = createdAtMs > 0 ? Math.max(0, Math.floor((endMs - createdAtMs) / 1000)) : 0;

  process.stdout.write(
    [
      id,
      runNumber,
      workflowName,
      status,
      conclusion,
      event,
      headBranch,
      headSha,
      String(createdAtMs),
      String(startedAtMs),
      String(updatedAtMs),
      String(queueSeconds),
      String(execSeconds),
      String(totalSeconds),
      title,
      htmlUrl,
    ].join("\u001f") + "\n",
  );
}
'
}

parse_jobs_payload() {
  node -e '
const fs = require("node:fs");

const input = fs.readFileSync(0, "utf8");
let payload;

try {
  payload = JSON.parse(input);
} catch (error) {
  console.error(`PARSE_ERROR\t${error.message}`);
  process.exit(2);
}

if (payload && typeof payload.message === "string" && payload.message.length > 0) {
  const text = payload.message.replace(/[\n\r\t]+/g, " ").trim();
  console.error(`API_ERROR\t${text}`);
  process.exit(3);
}

const jobs = Array.isArray(payload.jobs) ? payload.jobs : [];
const nowMs = Date.now();

const safe = (value) =>
  String(value ?? "")
    .replace(/\u001f/g, " ")
    .replace(/[\n\r\t]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();

const toMs = (value) => {
  if (typeof value !== "string" || value.length === 0) return 0;
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) return 0;
  return Math.trunc(parsed);
};

for (const job of jobs) {
  const id = job?.id != null ? String(job.id) : "";
  if (!id) continue;

  const name = safe(job?.name || "");
  const status = safe(job?.status || "").toLowerCase();
  const conclusion = safe(job?.conclusion || "").toLowerCase();
  const startedAtMs = toMs(job?.started_at);
  const completedAtMs = toMs(job?.completed_at);
  const endMs = status === "completed" && completedAtMs > 0 ? completedAtMs : nowMs;
  const durationSeconds = startedAtMs > 0 ? Math.max(0, Math.floor((endMs - startedAtMs) / 1000)) : 0;

  process.stdout.write(
    [
      id,
      name,
      status,
      conclusion,
      String(startedAtMs),
      String(completedAtMs),
      String(durationSeconds),
    ].join("\u001f") + "\n",
  );
}
'
}

clear_run_arrays() {
  RUN_IDS=()
  RUN_NUMBER=()
  RUN_WORKFLOW=()
  RUN_STATUS=()
  RUN_CONCLUSION=()
  RUN_EVENT=()
  RUN_BRANCH=()
  RUN_SHA=()
  RUN_CREATED_MS=()
  RUN_STARTED_MS=()
  RUN_UPDATED_MS=()
  RUN_QUEUE_SEC=()
  RUN_EXEC_SEC=()
  RUN_TOTAL_SEC=()
  RUN_TITLE=()
  RUN_URL=()
}

clear_job_arrays() {
  JOB_IDS=()
  JOB_NAME=()
  JOB_STATUS=()
  JOB_CONCLUSION=()
  JOB_STARTED_MS=()
  JOB_COMPLETED_MS=()
  JOB_DURATION_SEC=()
}

load_runs_from_parsed() {
  local parsed="$1"
  local record
  local id run_number workflow_name status conclusion event branch sha
  local created_ms started_ms updated_ms queue_sec exec_sec total_sec title url

  clear_run_arrays

  while IFS= read -r record; do
    if [[ -z "$record" ]]; then
      continue
    fi

    IFS=$'\x1f' read -r id run_number workflow_name status conclusion event branch sha created_ms started_ms updated_ms queue_sec exec_sec total_sec title url <<<"$record"

    RUN_IDS+=("$id")
    RUN_NUMBER+=("$run_number")
    RUN_WORKFLOW+=("$workflow_name")
    RUN_STATUS+=("$status")
    RUN_CONCLUSION+=("$conclusion")
    RUN_EVENT+=("$event")
    RUN_BRANCH+=("$branch")
    RUN_SHA+=("$sha")
    RUN_CREATED_MS+=("$created_ms")
    RUN_STARTED_MS+=("$started_ms")
    RUN_UPDATED_MS+=("$updated_ms")
    RUN_QUEUE_SEC+=("$queue_sec")
    RUN_EXEC_SEC+=("$exec_sec")
    RUN_TOTAL_SEC+=("$total_sec")
    RUN_TITLE+=("$title")
    RUN_URL+=("$url")
  done <<<"$parsed"
}

load_jobs_from_parsed() {
  local parsed="$1"
  local record
  local id name status conclusion started_ms completed_ms duration_sec

  clear_job_arrays

  while IFS= read -r record; do
    if [[ -z "$record" ]]; then
      continue
    fi

    IFS=$'\x1f' read -r id name status conclusion started_ms completed_ms duration_sec <<<"$record"

    JOB_IDS+=("$id")
    JOB_NAME+=("$name")
    JOB_STATUS+=("$status")
    JOB_CONCLUSION+=("$conclusion")
    JOB_STARTED_MS+=("$started_ms")
    JOB_COMPLETED_MS+=("$completed_ms")
    JOB_DURATION_SEC+=("$duration_sec")
  done <<<"$parsed"
}

compute_branch_metrics() {
  local i

  BRANCH_TOTALS=()
  BRANCH_QUEUES=()
  BRANCH_EXECS=()

  LATEST_INDEX=-1
  LATEST_COMPLETED_INDEX=-1

  if (( ${#RUN_IDS[@]} == 0 )); then
    return
  fi

  LATEST_INDEX=0

  for (( i = 0; i < ${#RUN_IDS[@]}; i++ )); do
    if [[ "${RUN_STATUS[i]}" != "completed" ]]; then
      continue
    fi

    if (( LATEST_COMPLETED_INDEX < 0 )); then
      LATEST_COMPLETED_INDEX="$i"
    fi

    if [[ "${RUN_TOTAL_SEC[i]}" =~ ^[0-9]+$ ]]; then
      BRANCH_TOTALS+=("${RUN_TOTAL_SEC[i]}")
    fi
    if [[ "${RUN_QUEUE_SEC[i]}" =~ ^[0-9]+$ ]]; then
      BRANCH_QUEUES+=("${RUN_QUEUE_SEC[i]}")
    fi
    if [[ "${RUN_EXEC_SEC[i]}" =~ ^[0-9]+$ ]]; then
      BRANCH_EXECS+=("${RUN_EXEC_SEC[i]}")
    fi
  done

  IFS='|' read -r BRANCH_P50_TOTAL BRANCH_P95_TOTAL <<<"$(build_stats_triplet "${BRANCH_TOTALS[@]}")"
  IFS='|' read -r BRANCH_P50_QUEUE BRANCH_P95_QUEUE <<<"$(build_stats_triplet "${BRANCH_QUEUES[@]}")"
  IFS='|' read -r BRANCH_P50_EXEC BRANCH_P95_EXEC <<<"$(build_stats_triplet "${BRANCH_EXECS[@]}")"
}

compute_baseline_metrics() {
  local response parsed
  local base_ids=() base_status=() base_total=() base_queue=() base_exec=()
  local record
  local id run_number workflow_name status conclusion event branch sha
  local created_ms started_ms updated_ms queue_sec exec_sec total_sec title url

  BASE_P50_TOTAL=0
  BASE_P95_TOTAL=0
  BASE_P50_QUEUE=0
  BASE_P95_QUEUE=0
  BASE_P50_EXEC=0
  BASE_P95_EXEC=0
  BASE_SAMPLE_COUNT=0

  if ! response="$(fetch_actions_runs_json "$BASELINE_BRANCH" "completed" "$BASELINE_EVENT")"; then
    warn_line "Failed to fetch baseline runs for ${BASELINE_BRANCH}."
    return 1
  fi

  if ! parsed="$(printf '%s' "$response" | parse_runs_payload 2>&1)"; then
    warn_line "Baseline runs API parse error: ${parsed}"
    return 1
  fi

  while IFS= read -r record; do
    if [[ -z "$record" ]]; then
      continue
    fi

    IFS=$'\x1f' read -r id run_number workflow_name status conclusion event branch sha created_ms started_ms updated_ms queue_sec exec_sec total_sec title url <<<"$record"

    base_ids+=("$id")
    base_status+=("$status")
    base_total+=("$total_sec")
    base_queue+=("$queue_sec")
    base_exec+=("$exec_sec")
  done <<<"$parsed"

  BASE_SAMPLE_COUNT="${#base_ids[@]}"
  IFS='|' read -r BASE_P50_TOTAL BASE_P95_TOTAL <<<"$(build_stats_triplet "${base_total[@]}")"
  IFS='|' read -r BASE_P50_QUEUE BASE_P95_QUEUE <<<"$(build_stats_triplet "${base_queue[@]}")"
  IFS='|' read -r BASE_P50_EXEC BASE_P95_EXEC <<<"$(build_stats_triplet "${base_exec[@]}")"

  return 0
}

refresh_latest_run_jobs() {
  local run_id="$1"
  local response parsed

  clear_job_arrays

  if [[ -z "$run_id" ]]; then
    return 0
  fi

  if ! response="$(fetch_run_jobs_json "$run_id")"; then
    warn_line "Failed to fetch jobs for run ${run_id}."
    return 1
  fi

  if ! parsed="$(printf '%s' "$response" | parse_jobs_payload 2>&1)"; then
    warn_line "Jobs API parse error for run ${run_id}: ${parsed}"
    return 1
  fi

  load_jobs_from_parsed "$parsed"
  return 0
}

compute_latest_progress_percent() {
  local run_status="$1"
  local total_jobs="${#JOB_IDS[@]}"
  local completed_jobs=0
  local i

  LATEST_JOB_TOTAL="$total_jobs"
  LATEST_JOB_COMPLETED=0

  if (( total_jobs == 0 )); then
    case "$run_status" in
      queued) printf '%s' "8" ;;
      in_progress) printf '%s' "55" ;;
      completed) printf '%s' "100" ;;
      *) printf '%s' "0" ;;
    esac
    return
  fi

  for (( i = 0; i < total_jobs; i++ )); do
    if [[ "${JOB_STATUS[i]}" == "completed" ]]; then
      completed_jobs=$(( completed_jobs + 1 ))
    fi
  done

  LATEST_JOB_COMPLETED="$completed_jobs"

  if [[ "$run_status" == "completed" ]]; then
    printf '%s' "100"
    return
  fi

  printf '%s' $(( completed_jobs * 100 / total_jobs ))
}

check_for_regression_alert() {
  local latest_total baseline_total delta_percent threshold

  threshold="$REGRESSION_THRESHOLD"
  REGRESSION_DELTA_PERCENT=0
  REGRESSION_STATE="ok"

  if (( LATEST_COMPLETED_INDEX < 0 )); then
    return
  fi

  latest_total="${RUN_TOTAL_SEC[LATEST_COMPLETED_INDEX]:-0}"
  baseline_total="${BASE_P50_TOTAL:-0}"

  if ! [[ "$latest_total" =~ ^[0-9]+$ ]]; then
    return
  fi
  if ! [[ "$baseline_total" =~ ^[0-9]+$ ]] || (( baseline_total <= 0 )); then
    return
  fi

  delta_percent=$(( (latest_total - baseline_total) * 100 / baseline_total ))
  REGRESSION_DELTA_PERCENT="$delta_percent"

  if (( delta_percent >= threshold )); then
    REGRESSION_STATE="regressed"
    LAST_ALERT_LEVEL="warning"
    LAST_ALERT_EPOCH="$(date +%s)"
    LAST_ALERT_MESSAGE="Latest completed run is ${delta_percent}% slower than ${BASELINE_BRANCH} p50 (${latest_total}s vs ${baseline_total}s)."
  elif (( delta_percent <= -20 )); then
    REGRESSION_STATE="improved"
    LAST_ALERT_LEVEL="success"
    LAST_ALERT_EPOCH="$(date +%s)"
    LAST_ALERT_MESSAGE="Latest completed run is ${delta_percent#-}% faster than ${BASELINE_BRANCH} p50."
  fi
}

check_timeout_or_exit() {
  local elapsed_seconds

  if (( TIMEOUT_SECONDS == 0 )); then
    return
  fi

  elapsed_seconds=$(( $(date +%s) - START_EPOCH ))
  if (( elapsed_seconds >= TIMEOUT_SECONDS )); then
    warn_line "Timeout reached after ${TIMEOUT_SECONDS}s."
    exit 124
  fi
}

sleep_for_next_poll() {
  local elapsed_seconds remaining_seconds sleep_seconds

  if (( TIMEOUT_SECONDS == 0 )); then
    sleep "$INTERVAL_SECONDS"
    return
  fi

  elapsed_seconds=$(( $(date +%s) - START_EPOCH ))
  if (( elapsed_seconds >= TIMEOUT_SECONDS )); then
    warn_line "Timeout reached after ${TIMEOUT_SECONDS}s."
    exit 124
  fi

  remaining_seconds=$(( TIMEOUT_SECONDS - elapsed_seconds ))
  sleep_seconds="$INTERVAL_SECONDS"
  if (( remaining_seconds < sleep_seconds )); then
    sleep_seconds="$remaining_seconds"
  fi

  sleep "$sleep_seconds"
}

render_dashboard() {
  local latest_id latest_number latest_status latest_conclusion latest_state_mark latest_state_label
  local latest_title latest_branch latest_event latest_queue latest_exec latest_total
  local progress_percent progress_bar
  local created_seconds event_time_display alert_time_display
  local i idx row_icon row_state row_total row_queue row_exec row_age
  local top_rows=()

  if (( DASHBOARD_ENABLED == 0 )); then
    return
  fi

  latest_id="n/a"
  latest_number="n/a"
  latest_status=""
  latest_conclusion=""
  latest_title="n/a"
  latest_branch="$BRANCH"
  latest_event="${EVENT_FILTER:-all}"
  latest_queue=0
  latest_exec=0
  latest_total=0

  if (( LATEST_INDEX >= 0 )); then
    latest_id="${RUN_IDS[LATEST_INDEX]}"
    latest_number="${RUN_NUMBER[LATEST_INDEX]:-n/a}"
    latest_status="${RUN_STATUS[LATEST_INDEX]}"
    latest_conclusion="${RUN_CONCLUSION[LATEST_INDEX]}"
    latest_title="$(truncate_text "${RUN_TITLE[LATEST_INDEX]:-}" 72)"
    latest_branch="${RUN_BRANCH[LATEST_INDEX]:-$BRANCH}"
    latest_event="${RUN_EVENT[LATEST_INDEX]:-${EVENT_FILTER:-all}}"
    latest_queue="${RUN_QUEUE_SEC[LATEST_INDEX]:-0}"
    latest_exec="${RUN_EXEC_SEC[LATEST_INDEX]:-0}"
    latest_total="${RUN_TOTAL_SEC[LATEST_INDEX]:-0}"
  fi

  latest_state_mark="$(status_icon "$latest_status" "$latest_conclusion")"
  latest_state_label="$(state_label "$latest_status" "$latest_conclusion")"
  progress_percent="$(compute_latest_progress_percent "$latest_status")"
  progress_bar="$(render_progress_bar "$progress_percent" 24 "$latest_status")"

  event_time_display="$(format_epoch_with_relative "$LAST_EVENT_EPOCH")"
  alert_time_display="$(format_epoch_with_relative "$LAST_ALERT_EPOCH")"

  begin_dashboard_render
  printf '%sCI Timing Monitor%s\n' "${C_BOLD_CYAN}" "${C_RESET}"
  printf '=================\n'
  printf 'Repo         : %s\n' "$REPO_SLUG"
  printf 'Workflow     : %s\n' "${WORKFLOW_INPUT:-all}"
  printf 'Branch       : %s (%s)\n' "$BRANCH" "${EVENT_FILTER:-all events}"
  printf 'Baseline     : %s (%s)\n' "$BASELINE_BRANCH" "${BASELINE_EVENT:-all events}"
  printf 'Window       : %s runs\n' "$WINDOW"
  printf 'Last Update  : %s\n' "$(date '+%H:%M:%S')"

  printf '\nLatest Run\n'
  printf '%s\n' '----------'
  printf 'Run         : #%s (%s)\n' "$latest_number" "$(truncate_text "$latest_id" 20)"
  printf 'State       : %s %s\n' "$latest_state_mark" "$latest_state_label"
  printf 'Branch/Event: %s / %s\n' "$latest_branch" "$latest_event"
  printf 'Progress    : %s %3d%%\n' "$progress_bar" "$progress_percent"
  printf 'Timings     : queue %s | exec %s | total %s\n' \
    "$(format_duration "$latest_queue")" "$(format_duration "$latest_exec")" "$(format_duration "$latest_total")"
  printf 'Jobs        : %s/%s completed\n' "$LATEST_JOB_COMPLETED" "$LATEST_JOB_TOTAL"
  printf 'Title       : %s\n' "${latest_title:-n/a}"

  printf '\nTrend (Completed Runs)\n'
  printf '%s\n' '----------------------'
  printf 'Branch p50  : queue %s | exec %s | total %s\n' \
    "$(format_duration "$BRANCH_P50_QUEUE")" "$(format_duration "$BRANCH_P50_EXEC")" "$(format_duration "$BRANCH_P50_TOTAL")"
  printf 'Branch p95  : queue %s | exec %s | total %s\n' \
    "$(format_duration "$BRANCH_P95_QUEUE")" "$(format_duration "$BRANCH_P95_EXEC")" "$(format_duration "$BRANCH_P95_TOTAL")"
  printf 'Base p50    : queue %s | exec %s | total %s\n' \
    "$(format_duration "$BASE_P50_QUEUE")" "$(format_duration "$BASE_P50_EXEC")" "$(format_duration "$BASE_P50_TOTAL")"
  printf 'Base p95    : queue %s | exec %s | total %s\n' \
    "$(format_duration "$BASE_P95_QUEUE")" "$(format_duration "$BASE_P95_EXEC")" "$(format_duration "$BASE_P95_TOTAL")"

  if [[ "$REGRESSION_STATE" == "regressed" ]]; then
    printf 'Regression  : %s⚠ +%s%% vs baseline p50 (threshold %s%%)%s\n' "${C_BOLD_YELLOW}" "$REGRESSION_DELTA_PERCENT" "$REGRESSION_THRESHOLD" "${C_RESET}"
  elif [[ "$REGRESSION_STATE" == "improved" ]]; then
    printf 'Regression  : %s✓ -%s%% vs baseline p50%s\n' "${C_BOLD_GREEN}" "${REGRESSION_DELTA_PERCENT#-}" "${C_RESET}"
  else
    printf 'Regression  : %s✓ within threshold (%s%%)%s\n' "${C_GREEN}" "$REGRESSION_THRESHOLD" "${C_RESET}"
  fi

  printf '\nTop Slow Jobs (Latest Run)\n'
  printf '%s\n' '--------------------------'

  if (( ${#JOB_IDS[@]} == 0 )); then
    printf 'No job timing data available yet.\n'
  else
    while IFS= read -r row; do
      if [[ -n "$row" ]]; then
        top_rows+=("$row")
      fi
    done < <(
      for (( i = 0; i < ${#JOB_IDS[@]}; i++ )); do
        printf '%s\x1f%s\x1f%s\x1f%s\n' "${JOB_DURATION_SEC[i]:-0}" "${JOB_STATUS[i]:-}" "${JOB_CONCLUSION[i]:-}" "${JOB_NAME[i]:-}"
      done | sort -t $'\x1f' -k1,1nr | head -n "$TOP_JOBS"
    )

    idx=1
    for row in "${top_rows[@]}"; do
      IFS=$'\x1f' read -r row_total row_state row_conclusion row_name <<<"$row"
      row_icon="$(status_icon "$row_state" "$row_conclusion")"
      printf '%2d. %s %s %8s  %s\n' \
        "$idx" "$(color_pad "$row_icon" 1)" "$(color_pad "$(state_label "$row_state" "$row_conclusion")" 10)" "$(format_duration "$row_total")" "$(truncate_text "$row_name" 70)"
      idx=$(( idx + 1 ))
    done
  fi

  printf '\nRecent Runs\n'
  printf '%s\n' '-----------'

  if (( ${#RUN_IDS[@]} == 0 )); then
    printf 'No runs found for branch %s.\n' "$BRANCH"
  else
    for (( i = 0; i < ${#RUN_IDS[@]} && i < 6; i++ )); do
      row_icon="$(color_pad "$(status_icon "${RUN_STATUS[i]}" "${RUN_CONCLUSION[i]}")" 1)"
      row_state="$(color_pad "$(state_label "${RUN_STATUS[i]}" "${RUN_CONCLUSION[i]}")" 10)"
      row_total="$(format_duration "${RUN_TOTAL_SEC[i]:-0}")"
      row_queue="$(format_duration "${RUN_QUEUE_SEC[i]:-0}")"
      row_exec="$(format_duration "${RUN_EXEC_SEC[i]:-0}")"
      if [[ "${RUN_CREATED_MS[i]}" =~ ^[0-9]+$ ]] && (( ${RUN_CREATED_MS[i]} > 0 )); then
        created_seconds=$(( RUN_CREATED_MS[i] / 1000 ))
        row_age="$(format_epoch_with_relative "$created_seconds")"
      else
        row_age="n/a"
      fi

      printf ' %s #%s %-10s total %-8s (queue %-7s exec %-7s)  %s\n' \
        "$row_icon" "${RUN_NUMBER[i]:-n/a}" "$row_state" "$row_total" "$row_queue" "$row_exec" "$row_age"
    done
  fi

  printf '\nLast Event: %s\n' "${LAST_EVENT_MESSAGE:-Starting...}"
  printf 'Event Time: %s\n' "$event_time_display"
  printf 'Last Alert: %s\n' "${LAST_ALERT_MESSAGE:-None}"
  printf 'Alert Time: %s\n' "$alert_time_display"
  printf '\nPress Ctrl+C to stop.\n'
}

render_plain_cycle_summary() {
  local latest_status latest_conclusion latest_state latest_number latest_total latest_queue latest_exec

  if (( LATEST_INDEX < 0 )); then
    log_line "No runs found for branch=${BRANCH} workflow=${WORKFLOW_INPUT}."
    return
  fi

  latest_status="${RUN_STATUS[LATEST_INDEX]}"
  latest_conclusion="${RUN_CONCLUSION[LATEST_INDEX]}"
  latest_state="$(state_label "$latest_status" "$latest_conclusion")"
  latest_number="${RUN_NUMBER[LATEST_INDEX]:-n/a}"
  latest_total="$(format_duration "${RUN_TOTAL_SEC[LATEST_INDEX]:-0}")"
  latest_queue="$(format_duration "${RUN_QUEUE_SEC[LATEST_INDEX]:-0}")"
  latest_exec="$(format_duration "${RUN_EXEC_SEC[LATEST_INDEX]:-0}")"

  log_line "Run #${latest_number} ${latest_state} | total=${latest_total} queue=${latest_queue} exec=${latest_exec} | baseline p50 total=$(format_duration "${BASE_P50_TOTAL:-0}")"

  if [[ "$REGRESSION_STATE" == "regressed" ]]; then
    warn_line "Regression warning: +${REGRESSION_DELTA_PERCENT}% vs ${BASELINE_BRANCH} p50 (threshold ${REGRESSION_THRESHOLD}%)."
  fi
}

if ! command -v gh >/dev/null 2>&1; then
  print_error "gh (GitHub CLI) is required."
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  print_error "node is required."
  exit 1
fi

REPO_SLUG=""
WORKFLOW_INPUT="CI"
WORKFLOW_REF=""
BRANCH=""
EVENT_FILTER=""
BASELINE_BRANCH="main"
BASELINE_EVENT="push"
WINDOW=20
TOP_JOBS=6
REGRESSION_THRESHOLD=20
INTERVAL_SECONDS=30
TIMEOUT_SECONDS=0
FORCE_PLAIN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --repo)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      REPO_SLUG="$2"
      shift 2
      ;;
    --workflow)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      WORKFLOW_INPUT="$2"
      shift 2
      ;;
    --branch)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      BRANCH="$2"
      shift 2
      ;;
    --event)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      EVENT_FILTER="$2"
      shift 2
      ;;
    --baseline-branch)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      BASELINE_BRANCH="$2"
      shift 2
      ;;
    --baseline-event)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      BASELINE_EVENT="$2"
      shift 2
      ;;
    --window)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      WINDOW="$2"
      shift 2
      ;;
    --top-jobs)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      TOP_JOBS="$2"
      shift 2
      ;;
    --regression-threshold)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      REGRESSION_THRESHOLD="$2"
      shift 2
      ;;
    -i|--interval)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --timeout)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --plain)
      FORCE_PLAIN=1
      shift
      ;;
    *)
      # Accept first positional argument as repo slug
      if [[ -z "$REPO_SLUG" && "$1" == */* && "$1" != -* ]]; then
        REPO_SLUG="$1"
        shift
      else
        print_error "Unknown option: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

if ! [[ "$WINDOW" =~ ^[1-9][0-9]*$ ]]; then
  print_error "--window must be a positive integer."
  exit 1
fi

if ! [[ "$TOP_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  print_error "--top-jobs must be a positive integer."
  exit 1
fi

if ! [[ "$REGRESSION_THRESHOLD" =~ ^[0-9]+$ ]]; then
  print_error "--regression-threshold must be a non-negative integer."
  exit 1
fi

if ! [[ "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  print_error "--interval must be a positive integer."
  exit 1
fi

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  print_error "--timeout must be a non-negative integer."
  exit 1
fi

if [[ -z "$REPO_SLUG" ]]; then
  # Fall back to git remote if running inside a repo
  if ! REPO_SLUG="$(detect_repo_slug 2>/dev/null)"; then
    print_error "Repository is required. Pass as first argument or use --repo <owner/repo>."
    usage
    exit 1
  fi
fi

if [[ -z "$BRANCH" ]]; then
  if ! BRANCH="$(detect_current_branch)"; then
    BRANCH="$BASELINE_BRANCH"
  fi
fi

if ! gh auth status >/dev/null 2>&1; then
  print_error "gh is not authenticated. Run 'gh auth login' first."
  exit 1
fi

WORKFLOW_REF=""
if [[ -n "$WORKFLOW_INPUT" ]]; then
  if ! WORKFLOW_REF="$(resolve_workflow_ref "$WORKFLOW_INPUT")"; then
    exit 1
  fi
fi

if (( FORCE_PLAIN == 0 )) && [[ -t 1 ]]; then
  DASHBOARD_ENABLED=1
fi

RUN_IDS=()
RUN_NUMBER=()
RUN_WORKFLOW=()
RUN_STATUS=()
RUN_CONCLUSION=()
RUN_EVENT=()
RUN_BRANCH=()
RUN_SHA=()
RUN_CREATED_MS=()
RUN_STARTED_MS=()
RUN_UPDATED_MS=()
RUN_QUEUE_SEC=()
RUN_EXEC_SEC=()
RUN_TOTAL_SEC=()
RUN_TITLE=()
RUN_URL=()

JOB_IDS=()
JOB_NAME=()
JOB_STATUS=()
JOB_CONCLUSION=()
JOB_STARTED_MS=()
JOB_COMPLETED_MS=()
JOB_DURATION_SEC=()

BRANCH_TOTALS=()
BRANCH_QUEUES=()
BRANCH_EXECS=()

BRANCH_P50_TOTAL=0
BRANCH_P95_TOTAL=0
BRANCH_P50_QUEUE=0
BRANCH_P95_QUEUE=0
BRANCH_P50_EXEC=0
BRANCH_P95_EXEC=0

BASE_P50_TOTAL=0
BASE_P95_TOTAL=0
BASE_P50_QUEUE=0
BASE_P95_QUEUE=0
BASE_P50_EXEC=0
BASE_P95_EXEC=0
BASE_SAMPLE_COUNT=0

LATEST_INDEX=-1
LATEST_COMPLETED_INDEX=-1
LATEST_JOB_TOTAL=0
LATEST_JOB_COMPLETED=0
REGRESSION_DELTA_PERCENT=0
REGRESSION_STATE="ok"

LAST_ALERT_MESSAGE="Waiting for data"
LAST_ALERT_LEVEL="info"
LAST_ALERT_EPOCH="$(date +%s)"

log_line "Monitoring CI timings for repo=${REPO_SLUG} workflow=${WORKFLOW_INPUT} branch=${BRANCH} (interval=${INTERVAL_SECONDS}s)"
log_line "Baseline comparison: branch=${BASELINE_BRANCH} event=${BASELINE_EVENT} threshold=${REGRESSION_THRESHOLD}%"

trap '_dashboard_leave_alt_screen; warn_line "Stopped CI timing monitor."; exit 0' INT TERM
trap '_dashboard_leave_alt_screen' EXIT

START_EPOCH="$(date +%s)"

while true; do
  primary_response=""
  primary_parsed=""

  check_timeout_or_exit

  if ! primary_response="$(fetch_actions_runs_json "$BRANCH" "" "$EVENT_FILTER")"; then
    warn_line "Failed to fetch runs for branch=${BRANCH}. Retrying..."
    LAST_ALERT_LEVEL="warning"
    LAST_ALERT_MESSAGE="Unable to fetch branch runs."
    LAST_ALERT_EPOCH="$(date +%s)"
    render_dashboard
    sleep_for_next_poll
    continue
  fi

  if ! primary_parsed="$(printf '%s' "$primary_response" | parse_runs_payload 2>&1)"; then
    warn_line "Branch runs API parse error: ${primary_parsed}"
    LAST_ALERT_LEVEL="warning"
    LAST_ALERT_MESSAGE="Failed to parse branch run data."
    LAST_ALERT_EPOCH="$(date +%s)"
    render_dashboard
    sleep_for_next_poll
    continue
  fi

  load_runs_from_parsed "$primary_parsed"
  compute_branch_metrics

  if ! compute_baseline_metrics; then
    LAST_ALERT_LEVEL="warning"
    LAST_ALERT_MESSAGE="Baseline metrics unavailable."
    LAST_ALERT_EPOCH="$(date +%s)"
  fi

  if (( LATEST_INDEX >= 0 )); then
    latest_run_id="${RUN_IDS[LATEST_INDEX]}"
    refresh_latest_run_jobs "$latest_run_id" >/dev/null 2>&1 || true
  else
    clear_job_arrays
  fi

  check_for_regression_alert

  if (( DASHBOARD_ENABLED == 0 )); then
    render_plain_cycle_summary
  fi
  render_dashboard

  sleep_for_next_poll
done
