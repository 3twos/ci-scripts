#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/monitor-core.sh"
source "${SCRIPT_DIR}/lib/monitor-dashboard.sh"
source "${SCRIPT_DIR}/lib/monitor-audio.sh"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'HELP'
Continuously monitor open GitHub PRs and announce state transitions via voice (Ctrl+C to stop).

Usage:
  monitor-gh-prs.sh <owner/repo> [options]
  monitor-gh-prs.sh --repo <owner/repo> [options]

Arguments:
  <owner/repo>               Repository slug (required; may also be passed via --repo)

Options:
  --repo <owner/repo>        Repository slug (alternative to positional argument)
  --author <login>           Filter by author (use @me for yourself)
  --branch <branch>          Filter by head branch
  --max-prs <count>          Max PRs to track (default: 10)
  -i, --interval <seconds>   Poll interval in seconds (default: 30)
  --timeout <seconds>        Optional script timeout (default: 0, disabled)
  --auto-update              Auto-update PRs that are behind base branch
  --voice <name>             macOS voice name (default: Ava (Premium)). Try: Moira, Daniel, Tessa
  --no-speak                 Disable spoken alerts
  --notify                   Enable macOS desktop notifications
  --plain                    Print line-by-line logs instead of the dashboard view
  -h, --help                 Show help

Examples:
  # Monitor all open PRs for a repo
  monitor-gh-prs.sh 3twos/my-app

  # Monitor your own PRs with 15s polling, auto-update behind branches
  monitor-gh-prs.sh 3twos/my-app --author @me --interval 15 --auto-update

  # Use a different voice
  monitor-gh-prs.sh 3twos/my-app --voice Moira

  # Monitor PRs for a specific branch, no voice
  monitor-gh-prs.sh 3twos/my-app --branch feature/my-branch --no-speak --plain
HELP
}

# ---------------------------------------------------------------------------
# Timeout and sleep
# ---------------------------------------------------------------------------

check_timeout_or_exit() {
  local elapsed_seconds

  if (( TIMEOUT_SECONDS == 0 )); then
    return
  fi

  elapsed_seconds=$(( $(date +%s) - START_EPOCH ))
  if (( elapsed_seconds >= TIMEOUT_SECONDS )); then
    warn_line "Timeout reached after ${TIMEOUT_SECONDS}s."
    render_dashboard
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
    render_dashboard
    exit 124
  fi

  remaining_seconds=$(( TIMEOUT_SECONDS - elapsed_seconds ))
  sleep_seconds="$INTERVAL_SECONDS"
  if (( remaining_seconds < sleep_seconds )); then
    sleep_seconds="$remaining_seconds"
  fi

  sleep "$sleep_seconds"
}

# ---------------------------------------------------------------------------
# PR state arrays
# ---------------------------------------------------------------------------

PR_NUMBERS=()
PR_TITLES=()
PR_AUTHORS=()
PR_BRANCHES=()
PR_URLS=()
PR_IS_DRAFT=()

# Current state (updated each poll)
PR_MERGEABLE=()        # "MERGEABLE" | "CONFLICTING" | "UNKNOWN"
PR_MERGE_STATE=()      # "CLEAN" | "BEHIND" | "BLOCKED" | "DIRTY" | ...
PR_CI_STATUS=()        # "passing" | "failing" | "pending" | "none"
PR_REVIEW_DECISION=()  # "APPROVED" | "CHANGES_REQUESTED" | "REVIEW_REQUIRED" | ""
PR_REVIEW_STATE=()     # "none" | "pending" | "changes" | "approved"
PR_REVIEW_COUNT=()     # number of reviews (includes approvals, change requests, and comments)
PR_LATEST_REVIEWERS=() # comma-separated reviewer logins
PR_IS_READY=()         # 0 | 1

# Previous state (for transition detection)
PR_PREV_MERGEABLE=()
PR_PREV_MERGE_STATE=()
PR_PREV_CI_STATUS=()
PR_PREV_REVIEW_DECISION=()
PR_PREV_REVIEW_STATE=()
PR_PREV_REVIEW_COUNT=()
PR_PREV_IS_READY=()

# Timestamp when an issue state was first detected (epoch seconds, 0 = no issue)
PR_ISSUE_SINCE_EPOCH=()
# Whether the "Still" reminder has been announced for the current issue
PR_ANNOUNCED_STILL=()

# Announcement flags (prevent repeats)
PR_ANNOUNCED_CREATED=()
PR_ANNOUNCED_CONFLICTS=()
PR_ANNOUNCED_CI_FAIL=()
PR_ANNOUNCED_NO_REVIEW=()
PR_ANNOUNCED_READY=()

# ---------------------------------------------------------------------------
# PR-specific functions
# ---------------------------------------------------------------------------

pr_index_by_number() {
  local number="$1"
  local i

  for (( i = 0; i < ${#PR_NUMBERS[@]}; i++ )); do
    if [[ "${PR_NUMBERS[i]}" == "$number" ]]; then
      printf '%s' "$i"
      return
    fi
  done

  printf '%s' "-1"
}

fetch_pr_list() {
  local gh_args=() raw_json parsed_output
  gh_args=(pr list -R "$REPO_SLUG" --state open --limit "$MAX_PRS" --json "number,title,headRefName,author,isDraft,url")

  if [[ -n "$AUTHOR_FILTER" ]]; then
    gh_args+=(--author "$AUTHOR_FILTER")
  fi
  if [[ -n "$BRANCH_FILTER" ]]; then
    gh_args+=(--head "$BRANCH_FILTER")
  fi

  if ! raw_json="$(gh "${gh_args[@]}" 2>/dev/null)"; then
    warn_line "Failed to fetch PR list."
    return 1
  fi

  parsed_output="$(node -e '
const input = require("node:fs").readFileSync(0, "utf8");
let prs;
try { prs = JSON.parse(input); } catch { process.exit(2); }
if (!Array.isArray(prs)) process.exit(2);
for (const pr of prs) {
  const num = pr.number || 0;
  const title = (pr.title || "").replace(/[\t\n\r\x1f]/g, " ");
  const branch = (pr.headRefName || "").replace(/[\t\n\r\x1f]/g, " ");
  const author = ((pr.author && pr.author.login) || "").replace(/[\t\n\r\x1f]/g, " ");
  const draft = pr.isDraft ? "1" : "0";
  const url = (pr.url || "").replace(/[\t\n\r\x1f]/g, " ");
  console.log([num, title, branch, author, draft, url].join("\t"));
}
' <<< "$raw_json" 2>/dev/null)" || {
    warn_line "Failed to parse PR list JSON."
    return 1
  }

  FETCHED_PR_NUMBERS=()
  FETCHED_PR_TITLES=()
  FETCHED_PR_BRANCHES=()
  FETCHED_PR_AUTHORS=()
  FETCHED_PR_IS_DRAFT=()
  FETCHED_PR_URLS=()

  while IFS=$'\t' read -r f_num f_title f_branch f_author f_draft f_url; do
    [[ -z "$f_num" ]] && continue
    FETCHED_PR_NUMBERS+=("$f_num")
    FETCHED_PR_TITLES+=("$f_title")
    FETCHED_PR_BRANCHES+=("$f_branch")
    FETCHED_PR_AUTHORS+=("$f_author")
    FETCHED_PR_IS_DRAFT+=("$f_draft")
    FETCHED_PR_URLS+=("$f_url")
  done <<< "$parsed_output"
}

fetch_pr_detail() {
  local pr_number="$1"
  local raw_json parsed_output

  if ! raw_json="$(gh pr view "$pr_number" -R "$REPO_SLUG" --json "number,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,reviews,reviewRequests,isDraft" 2>/dev/null)"; then
    warn_line "Failed to fetch detail for PR #${pr_number}."
    return 1
  fi

  parsed_output="$(node -e '
const input = require("node:fs").readFileSync(0, "utf8");
let pr;
try { pr = JSON.parse(input); } catch { process.exit(2); }

const mergeable = pr.mergeable || "UNKNOWN";
const mergeState = pr.mergeStateStatus || "UNKNOWN";
const reviewDecision = pr.reviewDecision || "-";
const isDraft = pr.isDraft ? "1" : "0";

const checks = pr.statusCheckRollup || [];
let ciStatus = "none";
if (checks.length > 0) {
  if (checks.some(c => ["FAILURE","ERROR"].includes(c.conclusion || c.state))) {
    ciStatus = "failing";
  } else if (checks.some(c => c.state === "PENDING" || (!c.conclusion && c.state !== "SUCCESS" && c.conclusion !== "SUCCESS"))) {
    ciStatus = "pending";
  } else {
    ciStatus = "passing";
  }
}

const reviews = pr.reviews || [];
const reviewerSet = new Set();
for (const r of reviews) {
  if (r.author && r.author.login) reviewerSet.add(r.author.login);
}
const reviewCount = reviews.length;
const reviewers = [...reviewerSet].join(",") || "-";

const reviewRequests = pr.reviewRequests || [];
const hasRequestedReviewers = reviewRequests.length > 0;

let reviewState = "none";
if (reviewDecision === "APPROVED") {
  reviewState = "approved";
} else if (reviewDecision === "CHANGES_REQUESTED") {
  reviewState = "changes";
} else if (hasRequestedReviewers || reviewDecision === "REVIEW_REQUIRED") {
  reviewState = "pending";
} else if (reviewCount > 0) {
  reviewState = "pending";
} else {
  reviewState = "none";
}

console.log([mergeable, mergeState, ciStatus, reviewDecision, reviewCount, reviewers, isDraft, reviewState].join("\t"));
' <<< "$raw_json" 2>/dev/null)" || {
    warn_line "Failed to parse detail JSON for PR #${pr_number}."
    return 1
  }

  DETAIL_MERGEABLE=""
  DETAIL_MERGE_STATE=""
  DETAIL_CI_STATUS=""
  DETAIL_REVIEW_DECISION=""
  DETAIL_REVIEW_COUNT=""
  DETAIL_REVIEWERS=""
  DETAIL_IS_DRAFT=""
  DETAIL_REVIEW_STATE=""

  IFS=$'\t' read -r DETAIL_MERGEABLE DETAIL_MERGE_STATE DETAIL_CI_STATUS DETAIL_REVIEW_DECISION DETAIL_REVIEW_COUNT DETAIL_REVIEWERS DETAIL_IS_DRAFT DETAIL_REVIEW_STATE <<< "$parsed_output"
}

reconcile_pr_list() {
  local i j found idx existing_numbers=() new_prs_added=0

  for (( i = 0; i < ${#PR_NUMBERS[@]}; i++ )); do
    existing_numbers+=("${PR_NUMBERS[i]}")
  done

  for (( j = 0; j < ${#FETCHED_PR_NUMBERS[@]}; j++ )); do
    found=0
    for (( i = 0; i < ${#existing_numbers[@]}; i++ )); do
      if [[ "${existing_numbers[i]}" == "${FETCHED_PR_NUMBERS[j]}" ]]; then
        found=1
        idx="$(pr_index_by_number "${FETCHED_PR_NUMBERS[j]}")"
        if (( idx >= 0 )); then
          PR_TITLES[idx]="${FETCHED_PR_TITLES[j]}"
          PR_BRANCHES[idx]="${FETCHED_PR_BRANCHES[j]}"
          PR_AUTHORS[idx]="${FETCHED_PR_AUTHORS[j]}"
          PR_IS_DRAFT[idx]="${FETCHED_PR_IS_DRAFT[j]}"
          PR_URLS[idx]="${FETCHED_PR_URLS[j]}"
        fi
        break
      fi
    done

    if (( found == 0 )); then
      PR_NUMBERS+=("${FETCHED_PR_NUMBERS[j]}")
      PR_TITLES+=("${FETCHED_PR_TITLES[j]}")
      PR_BRANCHES+=("${FETCHED_PR_BRANCHES[j]}")
      PR_AUTHORS+=("${FETCHED_PR_AUTHORS[j]}")
      PR_IS_DRAFT+=("${FETCHED_PR_IS_DRAFT[j]}")
      PR_URLS+=("${FETCHED_PR_URLS[j]}")

      PR_MERGEABLE+=("UNKNOWN")
      PR_MERGE_STATE+=("UNKNOWN")
      PR_CI_STATUS+=("none")
      PR_REVIEW_DECISION+=("")
      PR_REVIEW_STATE+=("none")
      PR_REVIEW_COUNT+=("0")
      PR_LATEST_REVIEWERS+=("")
      PR_IS_READY+=("0")

      PR_PREV_MERGEABLE+=("UNKNOWN")
      PR_PREV_MERGE_STATE+=("UNKNOWN")
      PR_PREV_CI_STATUS+=("none")
      PR_PREV_REVIEW_DECISION+=("")
      PR_PREV_REVIEW_STATE+=("none")
      PR_PREV_REVIEW_COUNT+=("0")
      PR_PREV_IS_READY+=("0")

      PR_ISSUE_SINCE_EPOCH+=("0")
      PR_ANNOUNCED_STILL+=("0")

      PR_ANNOUNCED_CREATED+=("0")
      PR_ANNOUNCED_CONFLICTS+=("0")
      PR_ANNOUNCED_CI_FAIL+=("0")
      PR_ANNOUNCED_NO_REVIEW+=("0")
      PR_ANNOUNCED_READY+=("0")

      new_prs_added=1
    fi
  done

  # Remove PRs no longer in the list (closed/merged)
  local keep_indices_str=""
  local keep_count=0
  for (( i = 0; i < ${#PR_NUMBERS[@]}; i++ )); do
    found=0
    for (( j = 0; j < ${#FETCHED_PR_NUMBERS[@]}; j++ )); do
      if [[ "${PR_NUMBERS[i]}" == "${FETCHED_PR_NUMBERS[j]}" ]]; then
        found=1
        break
      fi
    done
    if (( found == 1 )); then
      keep_indices_str="${keep_indices_str:+${keep_indices_str} }${i}"
      keep_count=$(( keep_count + 1 ))
    else
      log_line "PR #${PR_NUMBERS[i]} no longer open (closed/merged)."
    fi
  done

  if (( keep_count < ${#PR_NUMBERS[@]} )); then
    local tmp_numbers=() tmp_titles=() tmp_authors=() tmp_branches=() tmp_urls=() tmp_draft=()
    local tmp_mergeable=() tmp_merge_state=() tmp_ci=() tmp_review_dec=() tmp_review_state=() tmp_review_cnt=() tmp_reviewers=() tmp_ready=()
    local tmp_prev_m=() tmp_prev_ms=() tmp_prev_ci=() tmp_prev_rd=() tmp_prev_rs=() tmp_prev_rc=() tmp_prev_rdy=()
    local tmp_issue_since=() tmp_ann_still=()
    local tmp_ann_c=() tmp_ann_conf=() tmp_ann_ci=() tmp_ann_nr=() tmp_ann_rdy=()

    for idx in $keep_indices_str; do
      tmp_numbers+=("${PR_NUMBERS[idx]}")
      tmp_titles+=("${PR_TITLES[idx]}")
      tmp_authors+=("${PR_AUTHORS[idx]}")
      tmp_branches+=("${PR_BRANCHES[idx]}")
      tmp_urls+=("${PR_URLS[idx]}")
      tmp_draft+=("${PR_IS_DRAFT[idx]}")

      tmp_mergeable+=("${PR_MERGEABLE[idx]}")
      tmp_merge_state+=("${PR_MERGE_STATE[idx]}")
      tmp_ci+=("${PR_CI_STATUS[idx]}")
      tmp_review_dec+=("${PR_REVIEW_DECISION[idx]}")
      tmp_review_state+=("${PR_REVIEW_STATE[idx]}")
      tmp_review_cnt+=("${PR_REVIEW_COUNT[idx]}")
      tmp_reviewers+=("${PR_LATEST_REVIEWERS[idx]}")
      tmp_ready+=("${PR_IS_READY[idx]}")

      tmp_prev_m+=("${PR_PREV_MERGEABLE[idx]}")
      tmp_prev_ms+=("${PR_PREV_MERGE_STATE[idx]}")
      tmp_prev_ci+=("${PR_PREV_CI_STATUS[idx]}")
      tmp_prev_rd+=("${PR_PREV_REVIEW_DECISION[idx]}")
      tmp_prev_rs+=("${PR_PREV_REVIEW_STATE[idx]}")
      tmp_prev_rc+=("${PR_PREV_REVIEW_COUNT[idx]}")
      tmp_prev_rdy+=("${PR_PREV_IS_READY[idx]}")

      tmp_issue_since+=("${PR_ISSUE_SINCE_EPOCH[idx]}")
      tmp_ann_still+=("${PR_ANNOUNCED_STILL[idx]}")

      tmp_ann_c+=("${PR_ANNOUNCED_CREATED[idx]}")
      tmp_ann_conf+=("${PR_ANNOUNCED_CONFLICTS[idx]}")
      tmp_ann_ci+=("${PR_ANNOUNCED_CI_FAIL[idx]}")
      tmp_ann_nr+=("${PR_ANNOUNCED_NO_REVIEW[idx]}")
      tmp_ann_rdy+=("${PR_ANNOUNCED_READY[idx]}")
    done

    PR_NUMBERS=("${tmp_numbers[@]+"${tmp_numbers[@]}"}")
    PR_TITLES=("${tmp_titles[@]+"${tmp_titles[@]}"}")
    PR_AUTHORS=("${tmp_authors[@]+"${tmp_authors[@]}"}")
    PR_BRANCHES=("${tmp_branches[@]+"${tmp_branches[@]}"}")
    PR_URLS=("${tmp_urls[@]+"${tmp_urls[@]}"}")
    PR_IS_DRAFT=("${tmp_draft[@]+"${tmp_draft[@]}"}")

    PR_MERGEABLE=("${tmp_mergeable[@]+"${tmp_mergeable[@]}"}")
    PR_MERGE_STATE=("${tmp_merge_state[@]+"${tmp_merge_state[@]}"}")
    PR_CI_STATUS=("${tmp_ci[@]+"${tmp_ci[@]}"}")
    PR_REVIEW_DECISION=("${tmp_review_dec[@]+"${tmp_review_dec[@]}"}")
    PR_REVIEW_STATE=("${tmp_review_state[@]+"${tmp_review_state[@]}"}")
    PR_REVIEW_COUNT=("${tmp_review_cnt[@]+"${tmp_review_cnt[@]}"}")
    PR_LATEST_REVIEWERS=("${tmp_reviewers[@]+"${tmp_reviewers[@]}"}")
    PR_IS_READY=("${tmp_ready[@]+"${tmp_ready[@]}"}")

    PR_PREV_MERGEABLE=("${tmp_prev_m[@]+"${tmp_prev_m[@]}"}")
    PR_PREV_MERGE_STATE=("${tmp_prev_ms[@]+"${tmp_prev_ms[@]}"}")
    PR_PREV_CI_STATUS=("${tmp_prev_ci[@]+"${tmp_prev_ci[@]}"}")
    PR_PREV_REVIEW_DECISION=("${tmp_prev_rd[@]+"${tmp_prev_rd[@]}"}")
    PR_PREV_REVIEW_STATE=("${tmp_prev_rs[@]+"${tmp_prev_rs[@]}"}")
    PR_PREV_REVIEW_COUNT=("${tmp_prev_rc[@]+"${tmp_prev_rc[@]}"}")
    PR_PREV_IS_READY=("${tmp_prev_rdy[@]+"${tmp_prev_rdy[@]}"}")

    PR_ISSUE_SINCE_EPOCH=("${tmp_issue_since[@]+"${tmp_issue_since[@]}"}")
    PR_ANNOUNCED_STILL=("${tmp_ann_still[@]+"${tmp_ann_still[@]}"}")

    PR_ANNOUNCED_CREATED=("${tmp_ann_c[@]+"${tmp_ann_c[@]}"}")
    PR_ANNOUNCED_CONFLICTS=("${tmp_ann_conf[@]+"${tmp_ann_conf[@]}"}")
    PR_ANNOUNCED_CI_FAIL=("${tmp_ann_ci[@]+"${tmp_ann_ci[@]}"}")
    PR_ANNOUNCED_NO_REVIEW=("${tmp_ann_nr[@]+"${tmp_ann_nr[@]}"}")
    PR_ANNOUNCED_READY=("${tmp_ann_rdy[@]+"${tmp_ann_rdy[@]}"}")
  fi
}

refresh_pr_details() {
  local i pr_number

  for (( i = 0; i < ${#PR_NUMBERS[@]}; i++ )); do
    pr_number="${PR_NUMBERS[i]}"

    PR_PREV_MERGEABLE[i]="${PR_MERGEABLE[i]}"
    PR_PREV_MERGE_STATE[i]="${PR_MERGE_STATE[i]}"
    PR_PREV_CI_STATUS[i]="${PR_CI_STATUS[i]}"
    PR_PREV_REVIEW_DECISION[i]="${PR_REVIEW_DECISION[i]}"
    PR_PREV_REVIEW_STATE[i]="${PR_REVIEW_STATE[i]}"
    PR_PREV_REVIEW_COUNT[i]="${PR_REVIEW_COUNT[i]}"
    PR_PREV_IS_READY[i]="${PR_IS_READY[i]}"

    if ! fetch_pr_detail "$pr_number"; then
      continue
    fi

    PR_MERGEABLE[i]="${DETAIL_MERGEABLE:-UNKNOWN}"
    PR_MERGE_STATE[i]="${DETAIL_MERGE_STATE:-UNKNOWN}"
    PR_CI_STATUS[i]="${DETAIL_CI_STATUS:-none}"
    PR_REVIEW_DECISION[i]="${DETAIL_REVIEW_DECISION:-}"
    [[ "${PR_REVIEW_DECISION[i]}" == "-" ]] && PR_REVIEW_DECISION[i]=""
    PR_REVIEW_STATE[i]="${DETAIL_REVIEW_STATE:-none}"
    [[ "${PR_REVIEW_STATE[i]}" == "-" ]] && PR_REVIEW_STATE[i]="none"
    PR_REVIEW_COUNT[i]="${DETAIL_REVIEW_COUNT:-0}"
    PR_LATEST_REVIEWERS[i]="${DETAIL_REVIEWERS:-}"
    [[ "${PR_LATEST_REVIEWERS[i]}" == "-" ]] && PR_LATEST_REVIEWERS[i]=""
    if [[ -n "$DETAIL_IS_DRAFT" ]]; then
      PR_IS_DRAFT[i]="$DETAIL_IS_DRAFT"
    fi

    local is_ready=0
    if [[ "${PR_CI_STATUS[i]}" == "passing" ]] \
      && [[ "${PR_MERGEABLE[i]}" == "MERGEABLE" ]] \
      && [[ "${PR_REVIEW_DECISION[i]}" == "APPROVED" ]] \
      && [[ "${PR_IS_DRAFT[i]}" == "0" ]]; then
      is_ready=1
    fi
    PR_IS_READY[i]="$is_ready"
  done
}

process_pr_transitions_and_alerts() {
  local i num msg

  for (( i = 0; i < ${#PR_NUMBERS[@]}; i++ )); do
    num="${PR_NUMBERS[i]}"

    # PR created — announce with current state context
    if (( PR_ANNOUNCED_CREATED[i] == 0 )); then
      PR_ANNOUNCED_CREATED[i]=1
      local state_suffix=""
      if [[ "${PR_MERGEABLE[i]}" == "CONFLICTING" ]]; then
        state_suffix=", has conflicts"
        PR_ANNOUNCED_CONFLICTS[i]=1
      elif [[ "${PR_CI_STATUS[i]}" == "failing" ]]; then
        state_suffix=", CI failing"
        PR_ANNOUNCED_CI_FAIL[i]=1
      elif [[ "${PR_REVIEW_STATE[i]}" == "changes" ]]; then
        state_suffix=", unresolved comments"
      elif [[ "${PR_CI_STATUS[i]}" == "pending" ]]; then
        state_suffix=", CI pending"
      elif [[ "${PR_IS_READY[i]}" == "1" ]]; then
        state_suffix=", ready to merge"
        PR_ANNOUNCED_READY[i]=1
      elif [[ "${PR_REVIEW_STATE[i]}" == "approved" ]]; then
        state_suffix=", approved"
      elif [[ "${PR_REVIEW_STATE[i]}" == "none" ]] && [[ "${PR_IS_DRAFT[i]}" == "0" ]]; then
        state_suffix=", no review requested"
        PR_ANNOUNCED_NO_REVIEW[i]=1
      elif [[ "${PR_MERGE_STATE[i]}" == "BEHIND" ]]; then
        state_suffix=", behind"
      fi
      msg="${num} created${state_suffix}"
      log_line "$msg"
      LAST_ALERT_MESSAGE="$msg"
      LAST_ALERT_LEVEL="info"
      LAST_ALERT_EPOCH="$(date +%s)"
      speak_alert "$msg"
      notify_desktop "PR Monitor" "#${num} created${state_suffix}" "info"

      # Auto-update if behind on first discovery
      if [[ "${PR_MERGE_STATE[i]}" == "BEHIND" ]] && (( AUTO_UPDATE == 1 )); then
        if gh pr update-branch "$num" -R "$REPO_SLUG" 2>/dev/null; then
          log_line "${num} branch updated"
        else
          warn_line "${num} branch update failed"
        fi
      fi
      continue
    fi

    # Review comments increased
    if [[ "${PR_REVIEW_COUNT[i]}" =~ ^[0-9]+$ ]] && [[ "${PR_PREV_REVIEW_COUNT[i]}" =~ ^[0-9]+$ ]]; then
      if (( PR_REVIEW_COUNT[i] > PR_PREV_REVIEW_COUNT[i] )); then
        local reviewers_str="${PR_LATEST_REVIEWERS[i]}"
        local voice_names=""
        if [[ -n "$reviewers_str" ]]; then
          local IFS=','
          for login in $reviewers_str; do
            # If reviewer starts with "copilot", just say "copilot"
            local first_name
            if [[ "$login" == copilot* ]]; then
              first_name="copilot"
            else
              # Take part before first hyphen/underscore/dot as first name
              first_name="${login%%-*}"
              first_name="${first_name%%_*}"
              first_name="${first_name%%.*}"
            fi
            if [[ -n "$voice_names" ]]; then
              voice_names="${voice_names}, ${first_name}"
            else
              voice_names="$first_name"
            fi
          done
        fi
        if [[ -n "$voice_names" ]]; then
          msg="${num} has new reviews from ${voice_names}"
        else
          msg="${num} has new reviews"
        fi
        log_line "$msg"
        LAST_ALERT_MESSAGE="$msg"
        LAST_ALERT_LEVEL="info"
        LAST_ALERT_EPOCH="$(date +%s)"
        speak_alert "$msg"
        notify_desktop "PR Monitor" "#${num} reviewed by ${voice_names:-reviewers}" "info"
      fi
    fi

    # Review state: no review requested (voice alert for non-draft PRs)
    if [[ "${PR_REVIEW_STATE[i]}" == "none" ]] && [[ "${PR_IS_DRAFT[i]}" == "0" ]]; then
      if (( PR_ANNOUNCED_NO_REVIEW[i] == 0 )); then
        PR_ANNOUNCED_NO_REVIEW[i]=1
        msg="${num} no review requested"
        log_line "$msg"
        LAST_ALERT_MESSAGE="$msg"
        LAST_ALERT_LEVEL="warning"
        LAST_ALERT_EPOCH="$(date +%s)"
        speak_alert "$msg"
        notify_desktop "PR Monitor" "#${num} no review requested" "warning"
      fi
    else
      PR_ANNOUNCED_NO_REVIEW[i]=0
    fi

    # Review state: transitions
    if [[ "${PR_REVIEW_STATE[i]}" != "${PR_PREV_REVIEW_STATE[i]}" ]] && (( PR_ANNOUNCED_CREATED[i] == 1 )); then
      case "${PR_REVIEW_STATE[i]}" in
        pending)
          if [[ "${PR_PREV_REVIEW_STATE[i]}" == "none" ]]; then
            msg="${num} review requested"
            log_line "$msg"
            LAST_ALERT_MESSAGE="$msg"
            LAST_ALERT_LEVEL="info"
            LAST_ALERT_EPOCH="$(date +%s)"
            speak_alert "$msg"
            notify_desktop "PR Monitor" "#${num} review requested" "info"
          fi
          ;;
        approved)
          msg="${num} review approved"
          log_line "$msg"
          LAST_ALERT_MESSAGE="$msg"
          LAST_ALERT_LEVEL="success"
          LAST_ALERT_EPOCH="$(date +%s)"
          speak_alert "$msg"
          notify_desktop "PR Monitor" "#${num} approved" "success"
          ;;
        changes)
          msg="${num} changes requested"
          log_line "$msg"
          LAST_ALERT_MESSAGE="$msg"
          LAST_ALERT_LEVEL="warning"
          LAST_ALERT_EPOCH="$(date +%s)"
          speak_alert "$msg"
          notify_desktop "PR Monitor" "#${num} changes requested" "warning"
          ;;
      esac
    fi

    # Merge conflicts
    if [[ "${PR_MERGEABLE[i]}" == "CONFLICTING" ]] && [[ "${PR_PREV_MERGEABLE[i]}" != "CONFLICTING" ]]; then
      if (( PR_ANNOUNCED_CONFLICTS[i] == 0 )); then
        PR_ANNOUNCED_CONFLICTS[i]=1
        msg="${num} has merge conflicts"
        log_line "$msg"
        LAST_ALERT_MESSAGE="$msg"
        LAST_ALERT_LEVEL="warning"
        LAST_ALERT_EPOCH="$(date +%s)"
        speak_alert "$msg"
        notify_desktop "PR Monitor" "#${num} has merge conflicts" "warning"
      fi
    fi

    # Conflicts resolved
    if [[ "${PR_MERGEABLE[i]}" == "MERGEABLE" ]] && [[ "${PR_PREV_MERGEABLE[i]}" == "CONFLICTING" ]]; then
      PR_ANNOUNCED_CONFLICTS[i]=0
      msg="${num} conflicts resolved"
      log_line "$msg"
      LAST_ALERT_MESSAGE="$msg"
      LAST_ALERT_LEVEL="success"
      LAST_ALERT_EPOCH="$(date +%s)"
      speak_alert "$msg"
      notify_desktop "PR Monitor" "#${num} conflicts resolved" "success"
    fi

    # Needs update (BEHIND) — silently auto-update if enabled, no voice alert.
    # Fires on every transition to BEHIND *and* when already BEHIND (retry).
    if [[ "${PR_MERGE_STATE[i]}" == "BEHIND" ]]; then
      if (( AUTO_UPDATE == 1 )); then
        # Only attempt update on state change or every 3rd poll to avoid API spam
        if [[ "${PR_PREV_MERGE_STATE[i]}" != "BEHIND" ]] || (( POLL_COUNT % 3 == 0 )); then
          msg="${num} is behind, updating branch"
          log_line "$msg"
          LAST_ALERT_MESSAGE="$msg"
          LAST_ALERT_LEVEL="info"
          LAST_ALERT_EPOCH="$(date +%s)"
          if gh pr update-branch "$num" -R "$REPO_SLUG" 2>/dev/null; then
            msg="${num} branch updated"
            log_line "$msg"
            LAST_ALERT_MESSAGE="$msg"
            LAST_ALERT_LEVEL="success"
            LAST_ALERT_EPOCH="$(date +%s)"
          else
            msg="${num} branch update failed"
            warn_line "$msg"
            LAST_ALERT_MESSAGE="$msg"
            LAST_ALERT_LEVEL="error"
            LAST_ALERT_EPOCH="$(date +%s)"
          fi
        fi
      elif [[ "${PR_PREV_MERGE_STATE[i]}" != "BEHIND" ]]; then
        msg="${num} needs update branch"
        log_line "$msg"
        LAST_ALERT_MESSAGE="$msg"
        LAST_ALERT_LEVEL="warning"
        LAST_ALERT_EPOCH="$(date +%s)"
      fi
    fi

    # CI issues
    if [[ "${PR_CI_STATUS[i]}" == "failing" ]] && [[ "${PR_PREV_CI_STATUS[i]}" != "failing" ]]; then
      if (( PR_ANNOUNCED_CI_FAIL[i] == 0 )); then
        PR_ANNOUNCED_CI_FAIL[i]=1
        msg="${num} has CI issues"
        log_line "$msg"
        LAST_ALERT_MESSAGE="$msg"
        LAST_ALERT_LEVEL="error"
        LAST_ALERT_EPOCH="$(date +%s)"
        speak_alert "$msg"
        notify_desktop "PR Monitor" "#${num} CI failing" "error"
      fi
    fi

    # CI resolved
    if [[ "${PR_CI_STATUS[i]}" == "passing" ]] && [[ "${PR_PREV_CI_STATUS[i]}" == "failing" ]]; then
      PR_ANNOUNCED_CI_FAIL[i]=0
      msg="${num} CI resolved"
      log_line "$msg"
      LAST_ALERT_MESSAGE="$msg"
      LAST_ALERT_LEVEL="success"
      LAST_ALERT_EPOCH="$(date +%s)"
      speak_alert "$msg"
      notify_desktop "PR Monitor" "#${num} CI passing" "success"
    fi

    # Comments resolved (changes → pending only; changes → approved is
    # already covered by the "review approved" transition alert above)
    if [[ "${PR_PREV_REVIEW_STATE[i]}" == "changes" ]] \
      && [[ "${PR_REVIEW_STATE[i]}" == "pending" ]]; then
      msg="${num} comments resolved"
      log_line "$msg"
      LAST_ALERT_MESSAGE="$msg"
      LAST_ALERT_LEVEL="success"
      LAST_ALERT_EPOCH="$(date +%s)"
      speak_alert "$msg"
      notify_desktop "PR Monitor" "#${num} comments resolved" "success"
    fi

    # Ready to merge
    if (( PR_IS_READY[i] == 1 )) && (( PR_PREV_IS_READY[i] == 0 )); then
      if (( PR_ANNOUNCED_READY[i] == 0 )); then
        PR_ANNOUNCED_READY[i]=1
        msg="${num} ready to merge"
        log_line "$msg"
        LAST_ALERT_MESSAGE="$msg"
        LAST_ALERT_LEVEL="success"
        LAST_ALERT_EPOCH="$(date +%s)"
        speak_alert "$msg"
        notify_desktop "PR Monitor" "#${num} ready to merge!" "success"
      fi
    fi

    if (( PR_IS_READY[i] == 0 )); then
      PR_ANNOUNCED_READY[i]=0
    fi

    # Track issue state timestamp and announce "Still" after 2 minutes
    local has_issue=0 issue_desc=""
    if [[ "${PR_MERGEABLE[i]}" == "CONFLICTING" ]]; then
      has_issue=1; issue_desc="has conflicts"
    elif [[ "${PR_CI_STATUS[i]}" == "failing" ]]; then
      has_issue=1; issue_desc="CI failing"
    elif [[ "${PR_REVIEW_STATE[i]}" == "changes" ]]; then
      has_issue=1; issue_desc="unresolved comments"
    elif [[ "${PR_MERGE_STATE[i]}" == "BEHIND" ]]; then
      has_issue=1; issue_desc="behind"
    fi

    if (( has_issue == 1 )); then
      # Start tracking if not already
      if (( PR_ISSUE_SINCE_EPOCH[i] == 0 )); then
        PR_ISSUE_SINCE_EPOCH[i]="$(date +%s)"
        PR_ANNOUNCED_STILL[i]=0
      fi
      # Announce "Still" after 120 seconds
      if (( PR_ANNOUNCED_STILL[i] == 0 )); then
        local now_epoch issue_age
        now_epoch="$(date +%s)"
        issue_age=$(( now_epoch - PR_ISSUE_SINCE_EPOCH[i] ))
        if (( issue_age >= 120 )); then
          PR_ANNOUNCED_STILL[i]=1
          msg="Still ${num} ${issue_desc}"
          log_line "$msg"
          LAST_ALERT_MESSAGE="$msg"
          LAST_ALERT_LEVEL="warning"
          LAST_ALERT_EPOCH="$(date +%s)"
          speak_alert "$msg"
          notify_desktop "PR Monitor" "Still #${num} ${issue_desc}" "warning"
        fi
      fi
    else
      # Issue resolved — reset tracking
      PR_ISSUE_SINCE_EPOCH[i]=0
      PR_ANNOUNCED_STILL[i]=0
    fi
  done
}

# ---------------------------------------------------------------------------
# Dashboard rendering
# ---------------------------------------------------------------------------

pr_status_icon() {
  local idx="$1"
  local draft="${PR_IS_DRAFT[idx]}"
  local ready="${PR_IS_READY[idx]}"
  local ci="${PR_CI_STATUS[idx]}"
  local mergeable="${PR_MERGEABLE[idx]}"
  local merge_state="${PR_MERGE_STATE[idx]}"

  if [[ "$draft" == "1" ]]; then printf '%s' "${C_DIM}◌${C_RESET}"; return; fi
  if (( ready == 1 )); then printf '%s' "${C_BOLD_GREEN}✓${C_RESET}"; return; fi
  if [[ "$ci" == "failing" ]] || [[ "$mergeable" == "CONFLICTING" ]]; then printf '%s' "${C_BOLD_RED}✗${C_RESET}"; return; fi
  if [[ "$merge_state" == "BEHIND" ]]; then printf '%s' "${C_BOLD_YELLOW}⚠${C_RESET}"; return; fi
  printf '%s' "${C_CYAN}·${C_RESET}"
}

pr_status_label() {
  local idx="$1"
  local draft="${PR_IS_DRAFT[idx]}"
  local ready="${PR_IS_READY[idx]}"
  local ci="${PR_CI_STATUS[idx]}"
  local mergeable="${PR_MERGEABLE[idx]}"
  local merge_state="${PR_MERGE_STATE[idx]}"

  if [[ "$draft" == "1" ]]; then printf '%s' "${C_DIM}DRAFT${C_RESET}"; return; fi
  if (( ready == 1 )); then printf '%s' "${C_BOLD_GREEN}READY${C_RESET}"; return; fi
  if [[ "$mergeable" == "CONFLICTING" ]]; then printf '%s' "${C_BOLD_RED}CONFLICT${C_RESET}"; return; fi
  if [[ "$ci" == "failing" ]]; then printf '%s' "${C_RED}CI FAIL${C_RESET}"; return; fi
  if [[ "$merge_state" == "BEHIND" ]]; then printf '%s' "${C_YELLOW}BEHIND${C_RESET}"; return; fi
  if [[ "$merge_state" == "BLOCKED" ]]; then printf '%s' "${C_YELLOW}BLOCKED${C_RESET}"; return; fi
  if [[ "$ci" == "pending" ]]; then printf '%s' "${C_BLUE}PENDING${C_RESET}"; return; fi
  printf '%s' "${C_CYAN}OPEN${C_RESET}"
}

ci_icon() {
  case "$1" in
    passing) printf '%s' "${C_GREEN}✓${C_RESET}" ;;
    failing) printf '%s' "${C_RED}✗${C_RESET}" ;;
    pending) printf '%s' "${C_YELLOW}◑${C_RESET}" ;;
    none)    printf '%s' "${C_DIM}—${C_RESET}" ;;
    *)       printf '%s' "?" ;;
  esac
}

merge_label() {
  local mergeable="$1" merge_state="$2"
  if [[ "$mergeable" == "CONFLICTING" ]]; then printf '%s' "${C_RED}conflict${C_RESET}"; return; fi
  case "$merge_state" in
    CLEAN)    printf '%s' "${C_GREEN}clean${C_RESET}" ;;
    BEHIND)   printf '%s' "${C_YELLOW}behind${C_RESET}" ;;
    BLOCKED)  printf '%s' "${C_YELLOW}blocked${C_RESET}" ;;
    DIRTY)    printf '%s' "${C_RED}dirty${C_RESET}" ;;
    UNSTABLE) printf '%s' "${C_YELLOW}unstable${C_RESET}" ;;
    UNKNOWN)  printf '%s' "${C_DIM}?${C_RESET}" ;;
    *)        printf '%s' "$merge_state" | tr '[:upper:]' '[:lower:]' ;;
  esac
}

review_label() {
  case "$1" in
    approved) printf '%s' "${C_GREEN}approved${C_RESET}" ;;
    changes)  printf '%s' "${C_YELLOW}changes${C_RESET}" ;;
    pending)  printf '%s' "${C_BLUE}pending${C_RESET}" ;;
    none)     printf '%s' "${C_BOLD_YELLOW}none${C_RESET}" ;;
    *)        printf '%s' "${C_DIM}—${C_RESET}" ;;
  esac
}

render_dashboard() {
  local i event_time_display alert_time_display alert_mark
  local status_icon status_label ci_ic merge_lbl review_lbl title_short

  if (( DASHBOARD_ENABLED == 0 )); then return; fi

  event_time_display="$(format_epoch_with_relative "$LAST_EVENT_EPOCH")"
  alert_time_display="$(format_epoch_with_relative "$LAST_ALERT_EPOCH")"

  case "$LAST_ALERT_LEVEL" in
    error)   alert_mark="${C_BOLD_RED}✗${C_RESET}" ;;
    warning) alert_mark="${C_BOLD_YELLOW}⚠${C_RESET}" ;;
    success) alert_mark="${C_BOLD_GREEN}✓${C_RESET}" ;;
    *)       alert_mark="${C_DIM}·${C_RESET}" ;;
  esac

  begin_dashboard_render

  print_dashboard_linef '%s PR Monitor — %s%s' "${C_BOLD_CYAN}" "$REPO_SLUG" "${C_RESET}"
  print_dashboard_line  "======================="
  print_dashboard_linef 'Author    : %s%s' "${AUTHOR_FILTER:-all}" "${BRANCH_FILTER:+    Branch : $BRANCH_FILTER}"
  print_dashboard_linef 'Monitored : %s open PRs   Interval : %ss' "${#PR_NUMBERS[@]}" "$INTERVAL_SECONDS"
  print_dashboard_linef 'Updated   : %s' "$(date '+%H:%M:%S')"
  print_dashboard_line  ""

  if (( ${#PR_NUMBERS[@]} == 0 )); then
    print_dashboard_line "No open PRs found."
  else
    print_dashboard_linef ' %-5s %-10s  %-2s %-9s %-9s %s' "#" "Status" "CI" "Merge" "Review" "Title"
    print_dashboard_linef ' %-5s %-10s  %-2s %-9s %-9s %s' "----" "----------" "--" "---------" "---------" "------------------------------------------------"

    for (( i = 0; i < ${#PR_NUMBERS[@]}; i++ )); do
      status_icon="$(pr_status_icon "$i")"
      status_label="$(pr_status_label "$i")"
      ci_ic="$(ci_icon "${PR_CI_STATUS[i]}")"
      merge_lbl="$(merge_label "${PR_MERGEABLE[i]}" "${PR_MERGE_STATE[i]}")"
      review_lbl="$(review_label "${PR_REVIEW_STATE[i]}")"
      title_short="$(truncate_text "${PR_TITLES[i]}" 48)"

      printf '\r\033[2K %-5s %s %s  %s %s %s %s\n' \
        "${PR_NUMBERS[i]}" "$(color_pad "$status_icon" 1)" "$(color_pad "$status_label" 8)" "$(color_pad "$ci_ic" 2)" "$(color_pad "$merge_lbl" 9)" "$(color_pad "$review_lbl" 9)" "$title_short"
      DASHBOARD_CURRENT_RENDER_LINES=$(( DASHBOARD_CURRENT_RENDER_LINES + 1 ))
    done
  fi

  print_dashboard_line ""
  print_dashboard_linef 'Last Event : %s' "${LAST_EVENT_MESSAGE:-Starting...}"
  print_dashboard_linef 'Event Time : %s' "$event_time_display"
  print_dashboard_linef 'Last Alert : %s %s' "$alert_mark" "${LAST_ALERT_MESSAGE:-None}"
  print_dashboard_linef 'Alert Time : %s' "$alert_time_display"

  end_dashboard_render
}

render_plain_cycle_summary() {
  local i num ci merge_st review_d status_lbl

  if (( ${#PR_NUMBERS[@]} == 0 )); then
    log_line "No open PRs found."
    return
  fi

  log_line "Tracking ${#PR_NUMBERS[@]} open PRs:"
  for (( i = 0; i < ${#PR_NUMBERS[@]}; i++ )); do
    num="${PR_NUMBERS[i]}"
    status_lbl="$(pr_status_label "$i")"
    ci="${PR_CI_STATUS[i]}"
    merge_st="$(merge_label "${PR_MERGEABLE[i]}" "${PR_MERGE_STATE[i]}")"
    review_d="$(review_label "${PR_REVIEW_STATE[i]}")"
    log_line "  #${num} ${status_lbl} | CI:${ci} | merge:${merge_st} | review:${review_d} | $(truncate_text "${PR_TITLES[i]}" 40)"
  done
}

# ---------------------------------------------------------------------------
# Traps
# ---------------------------------------------------------------------------

cleanup_runtime() {
  cleanup_audio_runtime
}

handle_interrupt() {
  warn_line "Stopped PR monitor."
  render_dashboard
  if (( DASHBOARD_ENABLED == 1 )); then
    echo
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# Prereq checks
# ---------------------------------------------------------------------------

if ! command -v gh >/dev/null 2>&1; then
  print_error "gh (GitHub CLI) is required. Install via: brew install gh"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  print_error "node is required."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  print_error "Not authenticated with GitHub CLI. Run: gh auth login"
  exit 1
fi

# ---------------------------------------------------------------------------
# Defaults and arg parsing
# ---------------------------------------------------------------------------

REPO_SLUG=""
AUTHOR_FILTER=""
BRANCH_FILTER=""
MAX_PRS=10
INTERVAL_SECONDS=30
TIMEOUT_SECONDS=0
ENABLE_SPEAK=1
FORCE_PLAIN=0
AUTO_UPDATE=0
VOICE_NAME="Ava (Premium)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)       usage; exit 0 ;;
    --repo)          [[ $# -lt 2 ]] && { print_error "$1 requires a value."; exit 1; }; REPO_SLUG="$2"; shift 2 ;;
    --author)        [[ $# -lt 2 ]] && { print_error "$1 requires a value."; exit 1; }; AUTHOR_FILTER="$2"; shift 2 ;;
    --branch)        [[ $# -lt 2 ]] && { print_error "$1 requires a value."; exit 1; }; BRANCH_FILTER="$2"; shift 2 ;;
    --max-prs)       [[ $# -lt 2 ]] && { print_error "$1 requires a value."; exit 1; }; MAX_PRS="$2"; shift 2 ;;
    -i|--interval)   [[ $# -lt 2 ]] && { print_error "$1 requires a value."; exit 1; }; INTERVAL_SECONDS="$2"; shift 2 ;;
    --timeout)       [[ $# -lt 2 ]] && { print_error "$1 requires a value."; exit 1; }; TIMEOUT_SECONDS="$2"; shift 2 ;;
    --auto-update)   AUTO_UPDATE=1; shift ;;
    --voice)         [[ $# -lt 2 ]] && { print_error "$1 requires a value."; exit 1; }; VOICE_NAME="$2"; shift 2 ;;
    --no-speak)      ENABLE_SPEAK=0; shift ;;
    --notify)        DESKTOP_NOTIFICATIONS=1; shift ;;
    --plain)         FORCE_PLAIN=1; shift ;;
    --)              shift; break ;;
    -*)              print_error "Unknown option: $1"; usage; exit 1 ;;
    *)
      # Accept first positional argument as repo slug
      if [[ -z "$REPO_SLUG" && "$1" == */* && "$1" != -* ]]; then
        REPO_SLUG="$1"
        shift
      else
        print_error "Unexpected argument: $1"; usage; exit 1
      fi
      ;;
  esac
done

if [[ -z "$REPO_SLUG" ]]; then
  # Fall back to git remote if running inside a repo
  if ! REPO_SLUG="$(detect_repo_slug 2>/dev/null)"; then
    print_error "Repository is required. Pass as first argument or use --repo <owner/repo>."
    usage
    exit 1
  fi
fi

if ! [[ "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  print_error "--interval must be a positive integer."; exit 1
fi
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  print_error "--timeout must be a non-negative integer."; exit 1
fi
if ! [[ "$MAX_PRS" =~ ^[1-9][0-9]*$ ]]; then
  print_error "--max-prs must be a positive integer."; exit 1
fi

if (( FORCE_PLAIN == 0 )) && [[ -t 1 ]]; then
  DASHBOARD_ENABLED=1
fi

if (( ENABLE_SPEAK == 1 )); then
  detect_speaker_cmd
  # Use a distinct voice on macOS to distinguish PR alerts from deployment alerts.
  if [[ "$SPEAKER_CMD" == "say" && -n "$VOICE_NAME" ]]; then
    SPEAKER_ARGS=(-v "$VOICE_NAME")
  fi
fi

RUNTIME_DIR_PREFIX="gh-pr-monitor"
start_audio_queue_worker

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

log_line "Monitoring PRs for '${REPO_SLUG}' every ${INTERVAL_SECONDS}s (Ctrl+C to stop)..."
[[ -n "$AUTHOR_FILTER" ]] && log_line "Filtering by author: ${AUTHOR_FILTER}"
[[ -n "$BRANCH_FILTER" ]] && log_line "Filtering by branch: ${BRANCH_FILTER}"
(( AUTO_UPDATE == 1 )) && log_line "Auto-update enabled: PRs behind base branch will be updated automatically."
[[ -n "$SPEAKER_CMD" ]] && log_line "Spoken alerts enabled via '${SPEAKER_CMD}' (voice: ${VOICE_NAME})."

render_dashboard

trap 'handle_interrupt' INT TERM
trap 'cleanup_runtime' EXIT

START_EPOCH="$(date +%s)"
POLL_COUNT=0

while true; do
  check_timeout_or_exit

  POLL_COUNT=$(( POLL_COUNT + 1 ))

  if ! fetch_pr_list; then
    log_line "Retrying next cycle..."
    render_dashboard
    sleep_for_next_poll
    continue
  fi

  reconcile_pr_list
  refresh_pr_details
  process_pr_transitions_and_alerts

  if (( DASHBOARD_ENABLED == 1 )); then
    render_dashboard
  else
    if (( POLL_COUNT == 1 )); then
      render_plain_cycle_summary
    fi
  fi

  sleep_for_next_poll
done
