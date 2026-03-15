#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/monitor-core.sh"
source "${SCRIPT_DIR}/lib/monitor-dashboard.sh"
source "${SCRIPT_DIR}/lib/monitor-audio.sh"

usage() {
  cat <<'HELP'
Continuously monitor Vercel deployment status until you stop the script (Ctrl+C).

Usage:
  monitor-vercel-deployment.sh [deployment-id-or-url] [options]

Modes:
  1) Deployment mode
     - Pass a deployment id/url as the first argument.
  2) Project mode (parallel deployment watcher)
     - Omit the first argument and pass --project-id (or set VERCEL_PROJECT_ID).
     - Script tracks multiple recent deployments with separate status rows.

Options:
  -i, --interval <seconds>     Poll interval in seconds (default: 10)
  --timeout <seconds>          Optional script timeout (default: 0, disabled)
  --repo <path>                Repo path — reads .vercel/project.json for project-id & team-id
  --project-id <id>            Project id for project watcher mode
  --project-name <name>        Short name used in spoken alerts
  --team-id <id>               Team/org id (default: $VERCEL_TEAM_ID or $VERCEL_ORG_ID)
  --token <token>              Vercel token (default: $VERCEL_TOKEN, or secure prompt)
  --target production          Filter by target (only production is supported)
  --max-deployments <count>    Number of recent deployments to display (default: 6)
  --event-mode <mode>          auto | stream | poll (default: auto)
  --voice <name>               macOS voice name (default: Ava (Premium)). Try: Moira, Daniel, Tessa
  --no-speak                   Disable spoken alerts
  --notify                     Enable macOS desktop notifications
  --plain                      Print line-by-line logs instead of the dashboard view
  -h, --help                   Show help

Examples:
  # Watch production deployments using a repo's .vercel/project.json
  monitor-vercel-deployment.sh --repo ~/dev/my-app --interval 5

  # Watch production deployments by project id
  VERCEL_TOKEN=... monitor-vercel-deployment.sh --project-id prj_xxx --project-name "my-app"

  # Watch one deployment continuously until Ctrl+C
  monitor-vercel-deployment.sh dpl_123abc --interval 5
HELP
}

normalize_target() {
  local target="$1"

  target="${target#https://}"
  target="${target#http://}"
  target="${target%%\?*}"
  target="${target%%#*}"
  target="${target%/}"

  # Allow dashboard URLs like vercel.com/<team>/<project>/<deployment-id>.
  if [[ "$target" == vercel.com/* ]]; then
    target="${target##*/}"
  fi

  # For URLs with paths, keep only the host.
  if [[ "$target" == */* ]]; then
    target="${target%%/*}"
  fi

  printf '%s' "$target"
}

derive_short_project_name() {
  local deployment_url="$1"
  local fallback_id="$2"
  local host slug short_name

  if [[ -n "$PROJECT_SHORT_NAME" ]]; then
    printf '%s' "$PROJECT_SHORT_NAME"
    return
  fi

  host="$(normalize_target "$deployment_url")"
  host="${host%%/*}"
  slug="${host%.vercel.app}"

  # Typical preview domains look like "<project>-git-<branch>-<team>.vercel.app".
  if [[ "$slug" == *-git-* ]]; then
    slug="${slug%%-git-*}"
  fi
  if [[ "$slug" == *.* ]]; then
    slug="${slug%%.*}"
  fi

  short_name="$slug"
  if [[ -z "$short_name" ]]; then
    short_name="${PROJECT_ID#prj_}"
  fi
  if [[ -z "$short_name" ]]; then
    short_name="$fallback_id"
  fi
  if [[ -z "$short_name" ]]; then
    short_name="deployment"
  fi

  printf '%s' "$short_name"
}

parse_deployment_payload() {
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

if (payload && payload.error) {
  const code = typeof payload.error.code === "string" ? payload.error.code : "API_ERROR";
  const message =
    typeof payload.error.message === "string" ? payload.error.message : "Unknown API error.";
  console.error(`${code}\t${message}`);
  process.exit(3);
}

const text = (value) => (typeof value === "string" ? value : "");
const stringish = (value) =>
  typeof value === "string"
    ? value
    : typeof value === "number" && Number.isFinite(value)
      ? String(Math.trunc(value))
      : "";
const intMs = (value) =>
  typeof value === "number" && Number.isFinite(value) ? String(Math.trunc(value)) : "";
const sanitize = (value) =>
  String(value ?? "")
    .replace(/\u001f/g, " ")
    .replace(/[\n\r\t]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const pick = (...values) => {
  for (const value of values) {
    const candidate = stringish(value);
    if (candidate.trim().length > 0) return candidate;
  }
  return "";
};
const normalizeBranch = (value) => {
  let branch = pick(value).trim();
  if (!branch) return "";
  if (branch.startsWith("refs/heads/")) branch = branch.slice("refs/heads/".length);
  try {
    branch = decodeURIComponent(branch);
  } catch {}
  return branch;
};

const status = sanitize(text(payload.readyState || payload.state).toUpperCase() || "UNKNOWN");
const deploymentId = sanitize(text(payload.id || payload.uid));
const deploymentUrl = sanitize(text(payload.url) ? `https://${payload.url}` : "");
const createdAtMs = intMs(payload.createdAt);
const readyAtMs = intMs(payload.ready);
const target = sanitize(text(payload.target).toLowerCase());
const branch = sanitize(normalizeBranch(
  pick(
    payload?.meta?.githubCommitRef,
    payload?.meta?.gitlabCommitRef,
    payload?.meta?.bitbucketCommitRef,
    payload?.meta?.gitCommitRef,
    payload?.meta?.branch,
    payload?.meta?.commitRef,
    payload?.gitSource?.ref,
  ),
));
const errorMessage = sanitize(text(payload.errorMessage || payload.errorCode));
const source = sanitize(text(
  payload.source || payload?.meta?.deploymentSource || payload?.meta?.source || payload?.gitSource?.type,
));
const actor = sanitize(pick(
  payload?.creator?.username,
  payload?.creator?.name,
  payload?.creator?.email,
  payload?.creator?.id,
));
const commitSha = sanitize(pick(
  payload?.meta?.githubCommitSha,
  payload?.meta?.gitlabCommitSha,
  payload?.meta?.bitbucketCommitSha,
  payload?.meta?.gitCommitSha,
  payload?.meta?.commitSha,
  payload?.meta?.commit,
));
const changeTitle = sanitize(pick(
  payload?.meta?.githubPullRequestTitle,
  payload?.meta?.gitlabMergeRequestTitle,
  payload?.meta?.pullRequestTitle,
  payload?.meta?.prTitle,
  payload?.meta?.mergeRequestTitle,
  payload?.meta?.mrTitle,
  payload?.meta?.githubCommitSubject,
  payload?.meta?.githubCommitMessage,
  payload?.meta?.gitCommitMessage,
  payload?.meta?.commitMessage,
  payload?.meta?.message,
));
const pullRequest = sanitize(pick(
  payload?.meta?.githubPullRequestNumber,
  payload?.meta?.githubPullRequestId,
  payload?.meta?.githubPrNumber,
  payload?.meta?.githubPrId,
  payload?.meta?.pullRequestNumber,
  payload?.meta?.pullRequestId,
  payload?.meta?.prNumber,
  payload?.meta?.pr,
  payload?.meta?.bitbucketPullRequestId,
));
const mergeRequest = sanitize(pick(
  payload?.meta?.gitlabMergeRequestIid,
  payload?.meta?.gitlabMergeRequestId,
  payload?.meta?.mergeRequestIid,
  payload?.meta?.mergeRequestId,
  payload?.meta?.mrNumber,
  payload?.meta?.mr,
));
const pullRequestContext = mergeRequest
  ? `mr:${mergeRequest}`
  : pullRequest;

process.stdout.write(
  [status, deploymentId, deploymentUrl, createdAtMs, readyAtMs, target, branch, errorMessage, source, actor, commitSha, pullRequestContext, changeTitle].join("\u001f"),
);
'
}

parse_project_deployments_payload() {
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

if (payload && payload.error) {
  const code = typeof payload.error.code === "string" ? payload.error.code : "API_ERROR";
  const message =
    typeof payload.error.message === "string" ? payload.error.message : "Unknown API error.";
  console.error(`${code}\t${message}`);
  process.exit(3);
}

const deployments = Array.isArray(payload.deployments) ? payload.deployments : [];
const text = (value) => (typeof value === "string" ? value : "");
const stringish = (value) =>
  typeof value === "string"
    ? value
    : typeof value === "number" && Number.isFinite(value)
      ? String(Math.trunc(value))
      : "";
const intMs = (value) =>
  typeof value === "number" && Number.isFinite(value) ? String(Math.trunc(value)) : "";
const sanitize = (value) =>
  String(value ?? "")
    .replace(/\u001f/g, " ")
    .replace(/[\n\r\t]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const pick = (...values) => {
  for (const value of values) {
    const candidate = stringish(value);
    if (candidate.trim().length > 0) return candidate;
  }
  return "";
};
const normalizeBranch = (value) => {
  let branch = pick(value).trim();
  if (!branch) return "";
  if (branch.startsWith("refs/heads/")) branch = branch.slice("refs/heads/".length);
  try {
    branch = decodeURIComponent(branch);
  } catch {}
  return branch;
};

const rows = [];
for (const item of deployments) {
  const id = sanitize(text(item.uid || item.id));
  if (!id) continue;

  const state = sanitize(text(item.readyState || item.state).toUpperCase() || "UNKNOWN");
  const deploymentUrl = sanitize(text(item.url) ? `https://${item.url}` : "");
  const target = sanitize(text(item.target).toLowerCase());
  const branch = sanitize(normalizeBranch(
    pick(
      item?.meta?.githubCommitRef,
      item?.meta?.gitlabCommitRef,
      item?.meta?.bitbucketCommitRef,
      item?.meta?.gitCommitRef,
      item?.meta?.branch,
      item?.meta?.commitRef,
      item?.gitSource?.ref,
    ),
  ));
  const createdAtMs = intMs(item.createdAt);
  const readyAtMs = intMs(item.ready);
  const errorMessage = sanitize(text(item.errorMessage || item.errorCode));
  const source = sanitize(text(item.source || item?.meta?.deploymentSource || item?.meta?.source || item?.gitSource?.type));
  const actor = sanitize(pick(item?.creator?.username, item?.creator?.name, item?.creator?.email, item?.creator?.id));
  const commitSha = sanitize(pick(
    item?.meta?.githubCommitSha,
    item?.meta?.gitlabCommitSha,
    item?.meta?.bitbucketCommitSha,
    item?.meta?.gitCommitSha,
    item?.meta?.commitSha,
    item?.meta?.commit,
  ));
  const changeTitle = sanitize(pick(
    item?.meta?.githubPullRequestTitle,
    item?.meta?.gitlabMergeRequestTitle,
    item?.meta?.pullRequestTitle,
    item?.meta?.prTitle,
    item?.meta?.mergeRequestTitle,
    item?.meta?.mrTitle,
    item?.meta?.githubCommitSubject,
    item?.meta?.githubCommitMessage,
    item?.meta?.gitCommitMessage,
    item?.meta?.commitMessage,
    item?.meta?.message,
  ));
  const pullRequest = sanitize(pick(
    item?.meta?.githubPullRequestNumber,
    item?.meta?.githubPullRequestId,
    item?.meta?.githubPrNumber,
    item?.meta?.githubPrId,
    item?.meta?.pullRequestNumber,
    item?.meta?.pullRequestId,
    item?.meta?.prNumber,
    item?.meta?.pr,
    item?.meta?.bitbucketPullRequestId,
  ));
  const mergeRequest = sanitize(pick(
    item?.meta?.gitlabMergeRequestIid,
    item?.meta?.gitlabMergeRequestId,
    item?.meta?.mergeRequestIid,
    item?.meta?.mergeRequestId,
    item?.meta?.mrNumber,
    item?.meta?.mr,
  ));
  const pullRequestContext = mergeRequest
    ? `mr:${mergeRequest}`
    : pullRequest;

  rows.push([id, state, deploymentUrl, createdAtMs, readyAtMs, target, branch, errorMessage, source, actor, commitSha, pullRequestContext, changeTitle].join("\u001f"));
}

process.stdout.write(rows.join("\n"));
'
}

parse_deployment_events_snapshot_payload() {
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

if (payload && payload.error) {
  const code = typeof payload.error.code === "string" ? payload.error.code : "API_ERROR";
  const message =
    typeof payload.error.message === "string" ? payload.error.message : "Unknown API error.";
  console.error(`${code}\t${message}`);
  process.exit(3);
}

const events = Array.isArray(payload) ? payload : [];
const sanitize = (value) =>
  String(value ?? "")
    .replace(/\u001f/g, " ")
    .replace(/[\n\r\t]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const text = (value) => (typeof value === "string" ? value : "");
const pick = (...values) =>
  values.find((value) => typeof value === "string" && value.trim().length > 0) ?? "";
const toNumber = (value) =>
  typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : 0;

let latestCreated = 0;
let latestState = "";
let latestStep = "";
let latestText = "";

for (const event of events) {
  const payloadObj = event && typeof event.payload === "object" && event.payload ? event.payload : {};
  const info = payloadObj && typeof payloadObj.info === "object" && payloadObj.info ? payloadObj.info : {};
  const created =
    toNumber(event?.created) || toNumber(payloadObj?.created) || toNumber(payloadObj?.date) || 0;

  const step = sanitize(pick(info?.step, info?.name, info?.type));
  const state = sanitize(text(pick(info?.readyState, payloadObj?.readyState, event?.readyState)).toUpperCase());
  const logText = sanitize(pick(payloadObj?.text, event?.text));

  if (created === 0 && latestCreated > 0) {
    continue;
  }
  if (created > latestCreated) {
    latestCreated = created;
    latestState = state;
    latestStep = step;
    latestText = logText;
    continue;
  }

  if (created === latestCreated) {
    if (step) {
      latestStep = step;
    }
    if (state) {
      latestState = state;
    }
    if (logText) {
      latestText = logText;
    }
    continue;
  }

  if (latestCreated == 0) {
    if (step && !latestStep) {
      latestStep = step;
    }
    if (state && !latestState) {
      latestState = state;
    }
    if (logText && !latestText) {
      latestText = logText;
    }
  }
}

process.stdout.write([
  latestCreated > 0 ? String(latestCreated) : "",
  latestState,
  latestStep,
  latestText,
].join("\u001f"));
'
}

parse_deployment_events_stream_payload() {
  node -e '
const sanitize = (value) =>
  String(value ?? "")
    .replace(/\u001f/g, " ")
    .replace(/[\n\r\t]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const text = (value) => (typeof value === "string" ? value : "");
const pick = (...values) =>
  values.find((value) => typeof value === "string" && value.trim().length > 0) ?? "";
const toNumber = (value) =>
  typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : 0;

const emitRecord = (event) => {
  if (!event || typeof event !== "object" || Array.isArray(event)) {
    return;
  }

  const payloadObj = event && typeof event.payload === "object" && event.payload ? event.payload : {};
  const info = payloadObj && typeof payloadObj.info === "object" && payloadObj.info ? payloadObj.info : {};
  const created =
    toNumber(event?.created) || toNumber(payloadObj?.created) || toNumber(payloadObj?.date) || 0;
  const state = sanitize(text(pick(info?.readyState, payloadObj?.readyState, event?.readyState)).toUpperCase());
  const step = sanitize(pick(info?.step, info?.name, info?.type));
  const logText = sanitize(pick(payloadObj?.text, event?.text));
  const eventType = sanitize(text(event?.type));

  process.stdout.write(
    [created > 0 ? String(created) : "", state, step, logText, eventType].join("\u001f") + "\n",
  );
};

let buffer = "";
let depth = 0;
let start = -1;
let inString = false;
let escaped = false;

const consumeObjects = () => {
  for (let i = 0; i < buffer.length; i += 1) {
    const char = buffer[i];

    if (start === -1) {
      if (char === "{") {
        start = i;
        depth = 1;
        inString = false;
        escaped = false;
      }
      continue;
    }

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char === "\\") {
        escaped = true;
      } else if (char === "\"") {
        inString = false;
      }
      continue;
    }

    if (char === "\"") {
      inString = true;
      continue;
    }

    if (char === "{") {
      depth += 1;
      continue;
    }

    if (char === "}") {
      depth -= 1;
      if (depth === 0) {
        const objectText = buffer.slice(start, i + 1);
        try {
          emitRecord(JSON.parse(objectText));
        } catch {}

        buffer = buffer.slice(i + 1);
        i = -1;
        start = -1;
      }
    }
  }

  if (start === -1 && buffer.length > 200000) {
    buffer = buffer.slice(-10000);
  }
};

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  consumeObjects();
});
process.stdin.on("end", () => {
  consumeObjects();
});
'
}

build_deployment_url() {
  local target="$1"
  local url="https://api.vercel.com/v13/deployments/${target}"

  if [[ -n "$TEAM_ID" ]]; then
    url="${url}?teamId=${TEAM_ID}"
  fi

  printf '%s' "$url"
}

build_project_deployments_url() {
  local url="https://api.vercel.com/v6/deployments?projectId=${PROJECT_ID}&limit=${MAX_DEPLOYMENTS}"

  if [[ -n "$TARGET_FILTER" ]]; then
    url="${url}&target=${TARGET_FILTER}"
  fi

  if [[ -n "$TEAM_ID" ]]; then
    url="${url}&teamId=${TEAM_ID}"
  fi

  printf '%s' "$url"
}

build_deployment_events_url() {
  local target="$1"
  local since_ms="${2:-}"
  local follow="${3:-0}"
  local direction="${4:-forward}"
  local url="https://api.vercel.com/v3/deployments/${target}/events?limit=120&builds=1&delimiter=1&direction=${direction}"

  if [[ "$follow" == "1" ]]; then
    url="${url}&follow=1"
  fi

  if [[ "$since_ms" =~ ^[0-9]+$ ]] && (( since_ms > 0 )); then
    url="${url}&since=${since_ms}"
  fi

  if [[ -n "$TEAM_ID" ]]; then
    url="${url}&teamId=${TEAM_ID}"
  fi

  printf '%s' "$url"
}

fetch_json() {
  local url="$1"

  curl --silent --show-error --location \
    --header "Authorization: Bearer ${TOKEN}" \
    --header "Accept: application/json" \
    "$url"
}

format_duration() {
  local total_seconds="$1"

  if (( total_seconds < 60 )); then
    printf '%ss' "$total_seconds"
    return
  fi

  printf '%02d:%02d' $(( total_seconds / 60 )) $(( total_seconds % 60 ))
}

format_duration_mmss() {
  local total_seconds="$1"

  if ! [[ "$total_seconds" =~ ^[0-9]+$ ]] || (( total_seconds < 0 )); then
    total_seconds=0
  fi

  printf '%02d:%02d' $(( total_seconds / 60 )) $(( total_seconds % 60 ))
}

format_spoken_duration() {
  local total_seconds="$1"
  local minutes seconds minute_word second_word

  if (( total_seconds < 60 )); then
    if (( total_seconds == 1 )); then
      printf '%s' "1 second"
    else
      printf '%s seconds' "$total_seconds"
    fi
    return
  fi

  minutes=$(( total_seconds / 60 ))
  seconds=$(( total_seconds % 60 ))
  minute_word="minutes"
  second_word="seconds"

  if (( minutes == 1 )); then
    minute_word="minute"
  fi
  if (( seconds == 1 )); then
    second_word="second"
  fi

  if (( seconds == 0 )); then
    printf '%s %s' "$minutes" "$minute_word"
  else
    printf '%s %s %s %s' "$minutes" "$minute_word" "$seconds" "$second_word"
  fi
}

friendly_status() {
  local status="$1"

  case "$status" in
    READY) printf '%s' "${C_BOLD_GREEN}Ready${C_RESET}" ;;
    BUILDING) printf '%s' "${C_YELLOW}Building${C_RESET}" ;;
    QUEUED) printf '%s' "${C_BLUE}Queued${C_RESET}" ;;
    INITIALIZING) printf '%s' "${C_BLUE}Initializing${C_RESET}" ;;
    CANCELED) printf '%s' "${C_DIM}Canceled${C_RESET}" ;;
    ERROR|FAILED) printf '%s' "${C_BOLD_RED}Failed${C_RESET}" ;;
    UNKNOWN|"") printf '%s' "${C_DIM}Unknown${C_RESET}" ;;
    *) printf '%s' "$status" ;;
  esac
}

friendly_mode_label() {
  if [[ "$WATCH_MODE" == "project" ]]; then
    printf '%s' "Project deployments"
  else
    printf '%s' "Single deployment"
  fi
}

friendly_environment_label() {
  local target="$1"

  case "$target" in
    production|PRODUCTION) printf '%s' "Production" ;;
    preview|PREVIEW|"") printf '%s' "Preview" ;;
    *)
      # Keep unknown targets visible instead of collapsing them.
      printf '%s' "$target"
      ;;
  esac
}

normalize_branch_context() {
  local branch="$1"
  local lowered

  branch="$(sanitize_field "$branch")"
  if [[ -z "$branch" ]]; then
    printf '%s' ""
    return
  fi
  if [[ "$branch" == refs/heads/* ]]; then
    branch="${branch#refs/heads/}"
  fi

  lowered="$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    head|detached|unknown|n/a|null|none)
      printf '%s' ""
      return
      ;;
  esac

  # Sometimes providers return raw commit SHAs instead of branch refs.
  if [[ "$branch" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    printf '%s' ""
    return
  fi

  printf '%s' "$branch"
}

infer_branch_from_deployment_url() {
  local deployment_url="$1"
  local host slug tail guessed_branch

  host="$(normalize_target "$deployment_url")"
  host="${host%%/*}"
  if [[ -z "$host" ]]; then
    printf '%s' ""
    return
  fi

  slug="${host%.vercel.app}"
  if [[ "$slug" != *-git-* ]]; then
    printf '%s' ""
    return
  fi

  tail="${slug#*-git-}"
  if [[ "$tail" == "$slug" || -z "$tail" ]]; then
    printf '%s' ""
    return
  fi

  # Typical preview host shape: <project>-git-<branch>-<scope>.
  guessed_branch="${tail%-*}"
  if [[ -z "$guessed_branch" || "$guessed_branch" == "$tail" ]]; then
    guessed_branch="$tail"
  fi

  printf '%s' "$(normalize_branch_context "$guessed_branch")"
}

friendly_branch_label() {
  local branch="$1"
  local target="$2"
  local deployment_url="${3:-}"
  local normalized inferred

  normalized="$(normalize_branch_context "$branch")"
  if [[ -n "$normalized" ]]; then
    printf '%s' "$normalized"
    return
  fi

  inferred="$(infer_branch_from_deployment_url "$deployment_url")"
  if [[ -n "$inferred" ]]; then
    printf '%s' "$inferred"
    return
  fi

  if [[ "$target" == "production" || "$target" == "PRODUCTION" ]]; then
    printf '%s' "main"
    return
  fi
  printf '%s' "unknown"
}

friendly_source_label() {
  local source="$1"
  local lowered

  source="$(sanitize_field "$source")"
  if [[ -z "$source" ]]; then
    printf '%s' "unknown"
    return
  fi

  lowered="$(printf '%s' "$source" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    github|gitlab|bitbucket|git)
      printf '%s' "git"
      ;;
    *)
      printf '%s' "$lowered"
      ;;
  esac
}

friendly_actor_label() {
  local actor="$1"

  actor="$(sanitize_field "$actor")"
  if [[ -z "$actor" ]]; then
    printf '%s' "n/a"
    return
  fi

  printf '%s' "$(truncate_text "$actor" 22)"
}

friendly_commit_label() {
  local commit_sha="$1"

  commit_sha="$(sanitize_field "$commit_sha")"
  if [[ -z "$commit_sha" ]]; then
    printf '%s' "n/a"
    return
  fi

  if [[ "$commit_sha" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    printf '%s' "${commit_sha:0:8}"
    return
  fi

  printf '%s' "$(truncate_text "$commit_sha" 12)"
}

friendly_pull_request_label() {
  local pull_request="$1"
  local lowered lowered_payload kind payload candidate

  pull_request="$(sanitize_field "$pull_request")"
  if [[ -z "$pull_request" ]]; then
    printf '%s' "n/a"
    return
  fi

  lowered="$(printf '%s' "$pull_request" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    n/a|na|none|null|unknown|unlabeled)
      printf '%s' "n/a"
      return
      ;;
  esac

  kind="pr"
  payload="$pull_request"

  if [[ "$lowered" == pr:* || "$lowered" == mr:* ]]; then
    kind="${lowered%%:*}"
    payload="${pull_request#*:}"
  elif [[ "$pull_request" == \#* && "${pull_request#\#}" =~ ^[0-9]+$ ]]; then
    printf 'pr:%s' "${pull_request#\#}"
    return
  elif [[ "$pull_request" == !* && "${pull_request#!}" =~ ^[0-9]+$ ]]; then
    printf 'mr:%s' "${pull_request#!}"
    return
  fi

  payload="$(sanitize_field "$payload")"
  lowered_payload="$(printf '%s' "$payload" | tr '[:upper:]' '[:lower:]')"
  case "$lowered_payload" in
    ""|n/a|na|none|null|unknown|unlabeled)
      printf '%s' "n/a"
      return
      ;;
  esac

  if [[ "$payload" =~ /merge_requests/([0-9]+) ]]; then
    printf 'mr:%s' "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$payload" =~ /pull/([0-9]+) ]]; then
    printf 'pr:%s' "${BASH_REMATCH[1]}"
    return
  fi

  if [[ "$payload" =~ ^[0-9]+$ ]]; then
    printf '%s:%s' "$kind" "$payload"
    return
  fi

  candidate="$(truncate_text "$payload" 12)"
  printf '%s:%s' "$kind" "$candidate"
}

# Cache for branch→PR lookups via gh CLI (avoids repeated API calls).
# Uses two parallel indexed arrays for keys and values since associative arrays have portability issues.
# Successful lookups (pr:<number>) are cached permanently. Failed lookups (n/a) are cached with a
# timestamp and retried after _BRANCH_PR_MISS_TTL seconds so the PR becomes discoverable once created.
_BRANCH_PR_CACHE_KEYS=()
_BRANCH_PR_CACHE_VALS=()
_BRANCH_PR_CACHE_EPOCH=()
_BRANCH_PR_MISS_TTL=120
GH_CLI_AVAILABLE=""

_branch_pr_cache_get() {
  local key="$1" i now
  for (( i = 0; i < ${#_BRANCH_PR_CACHE_KEYS[@]}; i++ )); do
    if [[ "${_BRANCH_PR_CACHE_KEYS[i]}" == "$key" ]]; then
      # Expire n/a entries after TTL so we retry failed lookups.
      if [[ "${_BRANCH_PR_CACHE_VALS[i]}" == "n/a" ]]; then
        now="$(date +%s)"
        if (( now - ${_BRANCH_PR_CACHE_EPOCH[i]:-0} >= _BRANCH_PR_MISS_TTL )); then
          # Remove stale entry by clearing the key so it won't match again.
          _BRANCH_PR_CACHE_KEYS[i]=""
          return 1
        fi
      fi
      printf '%s' "${_BRANCH_PR_CACHE_VALS[i]}"
      return 0
    fi
  done
  return 1
}

_branch_pr_cache_set() {
  _BRANCH_PR_CACHE_KEYS+=("$1")
  _BRANCH_PR_CACHE_VALS+=("$2")
  _BRANCH_PR_CACHE_EPOCH+=("$(date +%s)")
}

resolve_pr_for_branch() {
  local branch="$1"
  local normalized pr_number cached

  normalized="$(normalize_branch_context "$branch")"
  if [[ -z "$normalized" ]]; then
    printf '%s' "n/a"
    return
  fi

  # Check cache first.
  if cached="$(_branch_pr_cache_get "$normalized")"; then
    printf '%s' "$cached"
    return
  fi

  # Detect gh CLI once.
  if [[ -z "$GH_CLI_AVAILABLE" ]]; then
    if command -v gh >/dev/null 2>&1; then
      GH_CLI_AVAILABLE="yes"
    else
      GH_CLI_AVAILABLE="no"
    fi
  fi

  if [[ "$GH_CLI_AVAILABLE" != "yes" ]]; then
    _branch_pr_cache_set "$normalized" "n/a"
    printf '%s' "n/a"
    return
  fi

  pr_number="$(gh pr list --head "$normalized" --json number --jq '.[0].number' 2>/dev/null || true)"
  pr_number="$(sanitize_field "$pr_number")"

  if [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    _branch_pr_cache_set "$normalized" "pr:${pr_number}"
    printf '%s' "pr:${pr_number}"
  else
    _branch_pr_cache_set "$normalized" "n/a"
    printf '%s' "n/a"
  fi
}

friendly_change_title() {
  local title="$1"
  local lowered

  title="$(sanitize_field "$title")"
  if [[ -z "$title" ]]; then
    printf '%s' "n/a"
    return
  fi

  lowered="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    n/a|na|none|null|unknown|unlabeled)
      printf '%s' "n/a"
      return
      ;;
  esac

  printf '%s' "$title"
}

pull_request_display_label() {
  local pull_request_label="$1"
  local payload

  pull_request_label="$(friendly_pull_request_label "$pull_request_label")"
  if [[ "$pull_request_label" == "n/a" ]]; then
    printf '%s' "n/a"
    return
  fi

  if [[ "$pull_request_label" == pr:* ]]; then
    payload="${pull_request_label#pr:}"
    printf '#%s' "$payload"
    return
  fi

  if [[ "$pull_request_label" == mr:* ]]; then
    payload="${pull_request_label#mr:}"
    printf '!%s' "$payload"
    return
  fi

  printf '%s' "$pull_request_label"
}

pull_request_kind_label() {
  local pull_request_label="$1"

  pull_request_label="$(friendly_pull_request_label "$pull_request_label")"
  case "$pull_request_label" in
    pr:*)
      printf '%s' "PR"
      return
      ;;
    mr:*)
      printf '%s' "MR"
      return
      ;;
  esac

  printf '%s' "n/a"
}

deployment_change_label() {
  local change_title="$1"
  local branch="$2"
  local target="$3"
  local deployment_url="$4"
  local title_label branch_label

  # Target is accepted for callsite consistency with other label builders.
  : "$target"

  title_label="$(friendly_change_title "$change_title")"
  if [[ "$title_label" != "n/a" ]]; then
    printf '%s' "$title_label"
    return
  fi

  branch_label="$(normalize_branch_context "$branch")"
  if [[ -z "$branch_label" ]]; then
    branch_label="$(infer_branch_from_deployment_url "$deployment_url")"
  fi
  if [[ -z "$branch_label" ]]; then
    printf '%s' "n/a"
    return
  fi

  printf '%s' "$branch_label"
}

branch_context_hint() {
  local branch="$1"
  local target="$2"
  local deployment_url="$3"
  local source="$4"
  local commit_sha="$5"
  local normalized inferred

  normalized="$(normalize_branch_context "$branch")"
  if [[ -n "$normalized" ]]; then
    printf '%s' "n/a"
    return
  fi

  inferred="$(infer_branch_from_deployment_url "$deployment_url")"
  if [[ -n "$inferred" ]]; then
    printf '%s (from URL)' "$inferred"
    return
  fi

  if [[ "$target" == "production" || "$target" == "PRODUCTION" ]]; then
    printf '%s' "n/a"
    return
  fi

  if [[ -n "$commit_sha" && "$commit_sha" != "n/a" ]]; then
    printf '%s (commit-only deployment)' "$commit_sha"
    return
  fi

  if [[ -n "$source" && "$source" != "unknown" ]]; then
    printf 'no git branch metadata (source: %s)' "$source"
    return
  fi

  printf '%s' "no git branch metadata"
}

deployment_identity_label() {
  local branch="$1"
  local target="$2"
  local deployment_url="$3"
  local pull_request="$4"
  local commit_sha="$5"
  local source="$6"
  local actor="$7"
  local resolved_branch pr_label source_label actor_label

  resolved_branch="$(friendly_branch_label "$branch" "$target" "$deployment_url")"
  if [[ "$resolved_branch" != "unknown" ]]; then
    printf '%s' "$resolved_branch"
    return
  fi

  pr_label="$(friendly_pull_request_label "$pull_request")"
  if [[ "$pr_label" != "n/a" ]]; then
    printf '%s' "$pr_label"
    return
  fi

  actor_label="$(friendly_actor_label "$actor")"
  if [[ "$actor_label" != "n/a" ]]; then
    printf 'actor:%s' "$actor_label"
    return
  fi

  source_label="$(friendly_source_label "$source")"
  if [[ "$source_label" != "unknown" ]]; then
    printf 'source:%s' "$source_label"
    return
  fi

  printf '%s' "unlabeled"
}

normalize_spoken_context() {
  local text="$1"

  text="$(sanitize_field "$text")"
  if [[ "$text" == *... ]]; then
    text="${text%...}"
  fi
  text="${text//\// }"
  text="${text//-/ }"
  text="${text//_/ }"
  text="${text#${text%%[![:space:]]*}}"
  text="${text%${text##*[![:space:]]}}"
  printf '%s' "$text"
}

spoken_deployment_identity() {
  local identity="$1"
  local payload

  if [[ "$identity" == pr:* ]]; then
    payload="${identity#pr:}"
    payload="$(normalize_spoken_context "$payload")"
    printf 'pull request %s' "$payload"
    return
  fi

  if [[ "$identity" == mr:* ]]; then
    payload="${identity#mr:}"
    payload="$(normalize_spoken_context "$payload")"
    printf 'merge request %s' "$payload"
    return
  fi

  if [[ "$identity" == commit:* ]]; then
    payload="${identity#commit:}"
    printf 'commit %s' "$payload"
    return
  fi

  if [[ "$identity" == actor:* ]]; then
    payload="${identity#actor:}"
    payload="$(normalize_spoken_context "$payload")"
    printf '%s' "$payload"
    return
  fi

  if [[ "$identity" == source:* ]]; then
    payload="${identity#source:}"
    payload="$(normalize_spoken_context "$payload")"
    printf 'source %s' "$payload"
    return
  fi

  if [[ "$identity" == "unlabeled" || -z "$identity" ]]; then
    printf '%s' "unlabeled"
    return
  fi

  printf '%s' "$(spoken_branch_name "$identity")"
}

spoken_branch_name() {
  local branch="$1"
  local normalized leaf

  leaf="${branch##*/}"
  if [[ -z "$leaf" ]]; then
    leaf="$branch"
  fi

  normalized="$leaf"
  normalized="${normalized//-/ }"
  normalized="${normalized//_/ }"
  printf '%s' "$normalized"
}

friendly_host() {
  local deployment_url="$1"
  local host

  host="$(normalize_target "$deployment_url")"
  if [[ -z "$host" ]]; then
    printf '%s' "n/a"
    return
  fi
  printf '%s' "$host"
}

short_deployment_label() {
  local deployment_id="$1"

  if [[ -z "$deployment_id" ]]; then
    printf '%s' "n/a"
    return
  fi
  if (( ${#deployment_id} > 18 )); then
    printf '%s...' "${deployment_id:0:18}"
    return
  fi
  printf '%s' "$deployment_id"
}

format_ms_local() {
  local epoch_ms="$1"
  local epoch_seconds

  if ! [[ "$epoch_ms" =~ ^[0-9]+$ ]]; then
    printf '%s' "n/a"
    return
  fi
  epoch_seconds=$(( epoch_ms / 1000 ))

  # Prefer BSD/macOS `date -r`, then GNU `date -d`.
  if date -r 0 '+%s' >/dev/null 2>&1; then
    if ! date -r "$epoch_seconds" '+%H:%M:%S'; then
      printf '%s' "n/a"
    fi
    return
  fi
  if date -d "@0" '+%s' >/dev/null 2>&1; then
    if ! date -d "@$epoch_seconds" '+%H:%M:%S'; then
      printf '%s' "n/a"
    fi
    return
  fi

  printf '%s' "n/a"
}

relative_time_from_seconds() {
  local elapsed_seconds="$1"

  if ! [[ "$elapsed_seconds" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "n/a"
    return
  fi
  if (( elapsed_seconds < 0 )); then
    elapsed_seconds=0
  fi

  if (( elapsed_seconds < 5 )); then
    printf '%s' "just now"
    return
  fi
  if (( elapsed_seconds < 60 )); then
    printf '%ss ago' "$elapsed_seconds"
    return
  fi
  if (( elapsed_seconds < 3600 )); then
    printf '%sm ago' $(( elapsed_seconds / 60 ))
    return
  fi
  if (( elapsed_seconds < 86400 )); then
    printf '%sh ago' $(( elapsed_seconds / 3600 ))
    return
  fi

  printf '%sd ago' $(( elapsed_seconds / 86400 ))
}

relative_time_from_epoch() {
  local epoch_seconds="$1"
  local now_seconds elapsed_seconds

  if ! [[ "$epoch_seconds" =~ ^[0-9]+$ ]]; then
    printf '%s' "n/a"
    return
  fi
  if (( epoch_seconds <= 0 )); then
    printf '%s' "n/a"
    return
  fi

  now_seconds="$(date +%s)"
  elapsed_seconds=$(( now_seconds - epoch_seconds ))
  relative_time_from_seconds "$elapsed_seconds"
}

relative_time_from_ms() {
  local epoch_ms="$1"
  local epoch_seconds

  if ! [[ "$epoch_ms" =~ ^[0-9]+$ ]]; then
    printf '%s' "n/a"
    return
  fi

  epoch_seconds=$(( epoch_ms / 1000 ))
  relative_time_from_epoch "$epoch_seconds"
}

format_ms_with_relative() {
  local epoch_ms="$1"
  local local_clock relative_time

  local_clock="$(format_ms_local "$epoch_ms")"
  if [[ "$local_clock" == "n/a" ]]; then
    printf '%s' "n/a"
    return
  fi

  relative_time="$(relative_time_from_ms "$epoch_ms")"
  if [[ "$relative_time" == "n/a" ]]; then
    printf '%s' "$local_clock"
    return
  fi

  printf '%s (%s)' "$local_clock" "$relative_time"
}

format_epoch_with_relative() {
  local epoch_seconds="$1"
  local epoch_ms local_clock relative_time

  if ! [[ "$epoch_seconds" =~ ^[0-9]+$ ]]; then
    printf '%s' "n/a"
    return
  fi
  if (( epoch_seconds <= 0 )); then
    printf '%s' "n/a"
    return
  fi

  epoch_ms=$(( epoch_seconds * 1000 ))
  local_clock="$(format_ms_local "$epoch_ms")"
  relative_time="$(relative_time_from_epoch "$epoch_seconds")"

  if [[ "$local_clock" == "n/a" ]]; then
    printf '%s' "$relative_time"
    return
  fi
  if [[ "$relative_time" == "n/a" ]]; then
    printf '%s' "$local_clock"
    return
  fi

  printf '%s (%s)' "$local_clock" "$relative_time"
}

status_icon() {
  local status="$1"

  case "$status" in
    READY) printf '%s' "${C_BOLD_GREEN}✓${C_RESET}" ;;
    ERROR|CANCELED|FAILED) printf '%s' "${C_BOLD_RED}✖${C_RESET}" ;;
    BUILDING|INITIALIZING|QUEUED) printf '%s' "${C_YELLOW}◑${C_RESET}" ;;
    WAITING) printf '%s' "${C_DIM}…${C_RESET}" ;;
    CONNECTION_ISSUE|API_ERROR|TIMED_OUT) printf '%s' "${C_BOLD_YELLOW}⚠${C_RESET}" ;;
    STOPPED) printf '%s' "${C_DIM}■${C_RESET}" ;;
    *) printf '%s' "?" ;;
  esac
}

environment_icon() {
  local target="$1"

  case "$target" in
    production|PRODUCTION) printf '%s' "🚀" ;;
    preview|PREVIEW|"") printf '%s' "🧪" ;;
    *) printf '%s' "•" ;;
  esac
}

alert_icon() {
  local level="$1"

  case "$level" in
    success) printf '%s' "${C_BOLD_GREEN}✓${C_RESET}" ;;
    error) printf '%s' "${C_BOLD_RED}✖${C_RESET}" ;;
    warning) printf '%s' "${C_BOLD_YELLOW}⚠${C_RESET}" ;;
    info|"") printf '%s' "${C_CYAN}ℹ${C_RESET}" ;;
    *) printf '%s' "${C_CYAN}ℹ${C_RESET}" ;;
  esac
}

is_terminal_status() {
  local status="$1"

  case "$status" in
    READY|ERROR|CANCELED|FAILED) return 0 ;;
    *) return 1 ;;
  esac
}

is_active_status() {
  local status="$1"

  case "$status" in
    QUEUED|INITIALIZING|BUILDING) return 0 ;;
    *) return 1 ;;
  esac
}

status_progress_percent() {
  local status="$1"
  local step_text="${2:-}"
  local normalized

  normalized="$(printf '%s' "$step_text" | tr '[:upper:]' '[:lower:]')"

  case "$status" in
    READY) printf '%s' "100" ;;
    ERROR|CANCELED|FAILED) printf '%s' "100" ;;
    QUEUED) printf '%s' "12" ;;
    INITIALIZING) printf '%s' "28" ;;
    BUILDING)
      if [[ "$normalized" == *"clone"* ]] || [[ "$normalized" == *"checkout"* ]]; then
        printf '%s' "32"
      elif [[ "$normalized" == *"install"* ]] || [[ "$normalized" == *"depend"* ]]; then
        printf '%s' "48"
      elif [[ "$normalized" == *"build"* ]] || [[ "$normalized" == *"compile"* ]]; then
        printf '%s' "72"
      elif [[ "$normalized" == *"upload"* ]] || [[ "$normalized" == *"deploy"* ]] || [[ "$normalized" == *"final"* ]]; then
        printf '%s' "88"
      else
        printf '%s' "64"
      fi
      ;;
    WAITING) printf '%s' "5" ;;
    CONNECTION_ISSUE|API_ERROR|TIMED_OUT|STOPPED) printf '%s' "0" ;;
    *) printf '%s' "10" ;;
  esac
}

spinner_frame() {
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local now idx

  now="$(date +%s)"
  idx=$(( now % ${#frames[@]} ))
  printf '%s' "${frames[idx]}"
}

render_progress_bar() {
  local percent="$1"
  local width="${2:-20}"
  local status="${3:-UNKNOWN}"
  local fill_count empty_count i bar fill_char empty_char spinner

  if ! [[ "$percent" =~ ^[0-9]+$ ]]; then
    percent=0
  fi
  if (( percent < 0 )); then
    percent=0
  fi
  if (( percent > 100 )); then
    percent=100
  fi
  if ! [[ "$width" =~ ^[0-9]+$ ]] || (( width <= 0 )); then
    width=20
  fi

  fill_char="█"
  empty_char="░"
  if [[ "$status" == "ERROR" || "$status" == "CANCELED" || "$status" == "FAILED" ]]; then
    fill_char="▓"
  fi

  fill_count=$(( (percent * width) / 100 ))
  empty_count=$(( width - fill_count ))

  bar=""
  for (( i = 0; i < fill_count; i++ )); do
    bar="${bar}${fill_char}"
  done
  for (( i = 0; i < empty_count; i++ )); do
    bar="${bar}${empty_char}"
  done

  if is_active_status "$status"; then
    spinner="$(spinner_frame)"
    printf '%s %s' "$bar" "$spinner"
  else
    printf '%s  ' "$bar"
  fi
}

## Dashboard rendering primitives are provided by lib/monitor-dashboard.sh

duration_seconds_for_record() {
  local created_at_ms="$1"
  local ready_at_ms="$2"
  local first_seen_epoch="$3"
  local now_seconds start_seconds end_seconds

  now_seconds="$(date +%s)"

  if [[ "$created_at_ms" =~ ^[0-9]+$ ]]; then
    start_seconds=$(( created_at_ms / 1000 ))
  else
    start_seconds="$first_seen_epoch"
  fi

  if [[ "$ready_at_ms" =~ ^[0-9]+$ ]]; then
    end_seconds=$(( ready_at_ms / 1000 ))
  else
    end_seconds="$now_seconds"
  fi

  if (( end_seconds < start_seconds )); then
    end_seconds="$now_seconds"
  fi

  echo $(( end_seconds - start_seconds ))
}

## Audio infra is provided by lib/monitor-audio.sh
## Custom audio event handler for the "beat" event (production deploy sound).

play_production_beat_sync() {
  local deployment_target="$1"

  if [[ "$deployment_target" != "production" && "$deployment_target" != "PRODUCTION" ]]; then
    return
  fi

  if command -v afplay >/dev/null 2>&1 && [[ -f "/System/Library/Sounds/Pop.aiff" ]]; then
    afplay "/System/Library/Sounds/Pop.aiff" >/dev/null 2>&1
    sleep 0.12
    afplay "/System/Library/Sounds/Pop.aiff" >/dev/null 2>&1
  else
    printf '\a'
    sleep 0.12
    printf '\a'
  fi
}

_audio_queue_custom_handler() {
  local event_kind="$1"
  local event_payload="$2"
  case "$event_kind" in
    beat)
      _acquire_speech_lock
      play_production_beat_sync "$event_payload"
      _release_speech_lock
      return 0
      ;;
    *) return 1 ;;
  esac
}

play_production_beat() {
  local deployment_target="$1"

  if (( ENABLE_SPEAK == 0 )); then
    return
  fi
  if [[ -z "$SPEAKER_CMD" ]]; then
    return
  fi
  if [[ "$deployment_target" != "production" && "$deployment_target" != "PRODUCTION" ]]; then
    return
  fi

  if (( AUDIO_QUEUE_ENABLED == 1 )); then
    enqueue_audio_event "beat" "$deployment_target" || true
    return
  fi

  (
    play_production_beat_sync "$deployment_target"
  ) &
}

check_timeout_or_exit() {
  local elapsed_seconds

  if (( TIMEOUT_SECONDS == 0 )); then
    return
  fi

  elapsed_seconds=$(( $(date +%s) - START_EPOCH ))
  if (( elapsed_seconds >= TIMEOUT_SECONDS )); then
    warn_line "Timeout reached after ${TIMEOUT_SECONDS}s."
    DASH_STATUS_LABEL="Timed out"
    DASH_STATUS_RAW="TIMED_OUT"
    LAST_ALERT_MESSAGE="Monitor timed out after ${TIMEOUT_SECONDS}s."
    LAST_ALERT_LEVEL="warning"
    LAST_ALERT_EPOCH="$(date +%s)"
    render_dashboard
    exit 124
  fi
}

sleep_for_next_poll() {
  local elapsed_seconds remaining_seconds sleep_seconds

  if (( TIMEOUT_SECONDS == 0 )); then
    sleep "${INTERVAL_SECONDS}"
    return
  fi

  elapsed_seconds=$(( $(date +%s) - START_EPOCH ))
  if (( elapsed_seconds >= TIMEOUT_SECONDS )); then
    warn_line "Timeout reached after ${TIMEOUT_SECONDS}s."
    DASH_STATUS_LABEL="Timed out"
    DASH_STATUS_RAW="TIMED_OUT"
    LAST_ALERT_MESSAGE="Monitor timed out after ${TIMEOUT_SECONDS}s."
    LAST_ALERT_LEVEL="warning"
    LAST_ALERT_EPOCH="$(date +%s)"
    render_dashboard
    exit 124
  fi

  remaining_seconds=$(( TIMEOUT_SECONDS - elapsed_seconds ))
  sleep_seconds="${INTERVAL_SECONDS}"
  if (( remaining_seconds < sleep_seconds )); then
    sleep_seconds="${remaining_seconds}"
  fi

  sleep "${sleep_seconds}"
}

deployment_index_by_id() {
  local deployment_id="$1"
  local i

  for (( i = 0; i < ${#DEP_IDS[@]}; i++ )); do
    if [[ "${DEP_IDS[i]}" == "$deployment_id" ]]; then
      printf '%s' "$i"
      return
    fi
  done

  printf '%s' "-1"
}

stream_worker_index_by_id() {
  local deployment_id="$1"
  local i

  for (( i = 0; i < ${#STREAM_IDS[@]}; i++ )); do
    if [[ "${STREAM_IDS[i]}" == "$deployment_id" ]]; then
      printf '%s' "$i"
      return
    fi
  done

  printf '%s' "-1"
}

remove_stream_worker_by_index() {
  local remove_index="$1"
  local i
  local -a next_ids=()
  local -a next_pids=()

  for (( i = 0; i < ${#STREAM_IDS[@]}; i++ )); do
    if (( i == remove_index )); then
      continue
    fi
    next_ids+=("${STREAM_IDS[i]}")
    next_pids+=("${STREAM_PIDS[i]}")
  done

  STREAM_IDS=("${next_ids[@]-}")
  STREAM_PIDS=("${next_pids[@]-}")
}

stop_stream_worker_by_index() {
  local stop_index="$1"
  local pid

  if (( stop_index < 0 || stop_index >= ${#STREAM_PIDS[@]} )); then
    return
  fi

  pid="${STREAM_PIDS[stop_index]}"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi

  remove_stream_worker_by_index "$stop_index"
}

stop_all_event_stream_workers() {
  local i

  for (( i = ${#STREAM_PIDS[@]} - 1; i >= 0; i-- )); do
    stop_stream_worker_by_index "$i"
  done
}

start_event_stream_worker() {
  local deployment_id="$1"
  local since_ms="${2:-}"
  local stream_url backoff_seconds max_backoff_seconds

  if [[ "$EVENT_MODE_ACTIVE" != "stream" ]]; then
    return
  fi
  if [[ -z "$EVENT_BUS_FILE" ]]; then
    return
  fi

  stream_url="$(build_deployment_events_url "$deployment_id" "$since_ms" 1 "forward")"
  backoff_seconds=1
  max_backoff_seconds=30

  (
    set +e
    while true; do
      # Stream disconnects and downstream pipe resets are expected; keep reconnecting quietly.
      if curl --silent --no-buffer --location \
        --header "Authorization: Bearer ${TOKEN}" \
        --header "Accept: application/json" \
        "$stream_url" |
        parse_deployment_events_stream_payload |
        while IFS=$'\x1f' read -r created_ms event_state event_step event_text event_type; do
          if [[ -z "${created_ms}${event_state}${event_step}${event_text}${event_type}" ]]; then
            continue
          fi
          printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
            "$deployment_id" "$created_ms" "$event_state" "$event_step" "$event_text" "$event_type" >>"$EVENT_BUS_FILE"
        done
      then
        backoff_seconds=1
      else
        if (( backoff_seconds < max_backoff_seconds )); then
          backoff_seconds=$(( backoff_seconds * 2 ))
          if (( backoff_seconds > max_backoff_seconds )); then
            backoff_seconds="$max_backoff_seconds"
          fi
        fi
      fi

      sleep "$backoff_seconds"
    done
  ) &

  STREAM_IDS+=("$deployment_id")
  STREAM_PIDS+=("$!")
}

record_event_update_for_index() {
  local index="$1"
  local created_ms="$2"
  local event_state="$3"
  local event_step="$4"
  local event_text="$5"
  local _source="${6:-poll}"
  local previous_event_ms event_epoch event_message short_id

  previous_event_ms="${DEP_LAST_EVENT_MS[index]:-0}"

  event_step="$(sanitize_field "$event_step")"
  event_text="$(sanitize_field "$event_text")"

  if [[ "$created_ms" =~ ^[0-9]+$ ]] && (( created_ms > previous_event_ms )); then
    DEP_LAST_EVENT_MS[index]="$created_ms"
    event_epoch=$(( created_ms / 1000 ))
    if (( event_epoch > 0 )); then
      LAST_EVENT_EPOCH="$event_epoch"
    fi

    event_message="$event_step"
    if [[ -z "$event_message" ]]; then
      event_message="$event_text"
    fi
    if [[ -n "$event_message" ]]; then
      event_message="$(truncate_text "$event_message" 88)"
      short_id="$(short_deployment_label "${DEP_IDS[index]}")"
      LAST_EVENT_MESSAGE="[${short_id}] ${event_message}"
    fi
  fi

  if [[ -n "$event_step" ]]; then
    # Record step transition in history only when the derived phase changes,
    # not on every raw step string change (many steps map to the same phase).
    local _prev_step="${DEP_STEP[index]:-}"
    local _new_phase_idx _prev_phase_idx
    _new_phase_idx="$(_step_phase_index "$event_step")"
    _prev_phase_idx="$(_step_phase_index "$_prev_step")"
    if [[ "$_new_phase_idx" != "$_prev_phase_idx" ]] && (( _new_phase_idx >= 0 )); then
      local _phase_key
      _phase_key="$(printf '%s' "$event_step" | tr '[:upper:]' '[:lower:]')"
      local _now_epoch
      _now_epoch="$(date +%s)"
      # Only record if this phase hasn't been recorded yet (preserve first start time)
      local _already_recorded=0
      if [[ -n "${DEP_STEP_HISTORY[index]:-}" ]]; then
        local _existing_entry
        local _existing_IFS="$IFS"
        IFS='|'
        for _existing_entry in ${DEP_STEP_HISTORY[index]}; do
          local _existing_key="${_existing_entry%%:*}"
          if [[ "$(_step_phase_index "$_existing_key")" == "$_new_phase_idx" ]]; then
            _already_recorded=1
            break
          fi
        done
        IFS="$_existing_IFS"
      fi
      if (( _already_recorded == 0 )); then
        if [[ -z "${DEP_STEP_HISTORY[index]:-}" ]]; then
          DEP_STEP_HISTORY[index]="${_phase_key}:${_now_epoch}"
        else
          DEP_STEP_HISTORY[index]="${DEP_STEP_HISTORY[index]}|${_phase_key}:${_now_epoch}"
        fi
      fi
    fi
    DEP_STEP[index]="$event_step"
  fi
  if [[ -n "$event_text" ]]; then
    DEP_LAST_EVENT_TEXT[index]="$event_text"
  fi

  if [[ -n "$event_state" ]]; then
    if [[ "${DEP_STATUS[index]}" == "UNKNOWN" || "${DEP_STATUS[index]}" == "WAITING" ]]; then
      DEP_STATUS[index]="$event_state"
    fi
  fi
}

consume_event_bus_updates() {
  local total_lines start_line line deployment_id created_ms event_state event_step event_text event_type index

  if [[ -z "$EVENT_BUS_FILE" || ! -f "$EVENT_BUS_FILE" ]]; then
    return
  fi

  total_lines="$(wc -l < "$EVENT_BUS_FILE" | tr -d ' ')"
  if ! [[ "$total_lines" =~ ^[0-9]+$ ]]; then
    return
  fi
  if (( total_lines <= EVENT_BUS_OFFSET )); then
    return
  fi

  start_line=$(( EVENT_BUS_OFFSET + 1 ))
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      continue
    fi

    IFS=$'\x1f' read -r deployment_id created_ms event_state event_step event_text event_type <<<"$line"
    if [[ -z "$deployment_id" ]]; then
      continue
    fi

    index="$(deployment_index_by_id "$deployment_id")"
    if (( index < 0 )); then
      continue
    fi

    record_event_update_for_index "$index" "$created_ms" "$event_state" "$event_step" "$event_text" "stream"
  done < <(sed -n "${start_line},${total_lines}p" "$EVENT_BUS_FILE")

  EVENT_BUS_OFFSET="$total_lines"
  if (( EVENT_BUS_OFFSET >= EVENT_BUS_TRUNCATE_LINES )); then
    : >"$EVENT_BUS_FILE" || true
    EVENT_BUS_OFFSET=0
  fi
}

reconcile_event_stream_workers() {
  local i worker_id worker_pid idx dep_id dep_status since_ms existing_idx

  if [[ "$EVENT_MODE_ACTIVE" != "stream" ]]; then
    stop_all_event_stream_workers
    return
  fi

  # Drop workers that already exited.
  for (( i = ${#STREAM_PIDS[@]} - 1; i >= 0; i-- )); do
    worker_pid="${STREAM_PIDS[i]}"
    if ! kill -0 "$worker_pid" >/dev/null 2>&1; then
      remove_stream_worker_by_index "$i"
    fi
  done

  # Stop workers for deployments that no longer exist or are terminal.
  for (( i = ${#STREAM_IDS[@]} - 1; i >= 0; i-- )); do
    worker_id="${STREAM_IDS[i]}"
    idx="$(deployment_index_by_id "$worker_id")"
    if (( idx < 0 )); then
      stop_stream_worker_by_index "$i"
      continue
    fi

    if is_terminal_status "${DEP_STATUS[idx]}"; then
      stop_stream_worker_by_index "$i"
      continue
    fi
  done

  # Start workers for active deployments, up to MAX_STREAM_WORKERS.
  for (( i = 0; i < ${#DEP_IDS[@]}; i++ )); do
    if (( ${#STREAM_IDS[@]} >= MAX_STREAM_WORKERS )); then
      break
    fi

    dep_id="${DEP_IDS[i]}"
    dep_status="${DEP_STATUS[i]}"
    if is_terminal_status "$dep_status"; then
      continue
    fi

    existing_idx="$(stream_worker_index_by_id "$dep_id")"
    if (( existing_idx >= 0 )); then
      continue
    fi

    since_ms="${DEP_LAST_EVENT_MS[i]:-0}"
    if [[ "$since_ms" =~ ^[0-9]+$ ]] && (( since_ms > 0 )); then
      since_ms=$(( since_ms + 1 ))
    else
      since_ms=""
    fi

    start_event_stream_worker "$dep_id" "$since_ms"
  done
}

refresh_project_deployments() {
  local response parsed record
  local dep_id dep_status dep_url dep_created_at dep_ready_at dep_target dep_branch dep_error dep_source dep_actor dep_commit_sha dep_pull_request dep_change_title
  local old_idx first_seen last_status announced step_label step_history last_event_ms last_event_text project_name source_label actor_label commit_label pull_request_label change_title_label
  local -a next_ids=()
  local -a next_status=()
  local -a next_url=()
  local -a next_created_at=()
  local -a next_ready_at=()
  local -a next_target=()
  local -a next_branch=()
  local -a next_error=()
  local -a next_source=()
  local -a next_actor=()
  local -a next_commit_sha=()
  local -a next_pull_request=()
  local -a next_change_title=()
  local -a next_first_seen=()
  local -a next_last_status=()
  local -a next_announced=()
  local -a next_step=()
  local -a next_step_history=()
  local -a next_last_event_ms=()
  local -a next_last_event_text=()
  local -a next_project_name=()

  if ! response="$(fetch_json "$(build_project_deployments_url)")"; then
    warn_line "Failed to fetch project deployments. Retrying..."
    return 1
  fi

  if ! parsed="$(printf '%s' "$response" | parse_project_deployments_payload 2>&1)"; then
    warn_line "Project deployments API error: ${parsed}"
    return 1
  fi

  if [[ -z "$parsed" ]]; then
    DEP_IDS=()
    DEP_STATUS=()
    DEP_URL=()
    DEP_CREATED_AT_MS=()
    DEP_READY_AT_MS=()
    DEP_TARGET=()
    DEP_BRANCH=()
    DEP_ERROR_MESSAGE=()
    DEP_SOURCE=()
    DEP_ACTOR=()
    DEP_COMMIT_SHA=()
    DEP_PULL_REQUEST=()
    DEP_CHANGE_TITLE=()
    DEP_FIRST_SEEN_EPOCH=()
    DEP_LAST_STATUS=()
    DEP_TERMINAL_ANNOUNCED=()
    DEP_STEP=()
    DEP_STEP_HISTORY=()
    DEP_LAST_EVENT_MS=()
    DEP_LAST_EVENT_TEXT=()
    DEP_PROJECT_NAME=()
    return 0
  fi

  while IFS= read -r record; do
    if [[ -z "$record" ]]; then
      continue
    fi

    IFS=$'\x1f' read -r dep_id dep_status dep_url dep_created_at dep_ready_at dep_target dep_branch dep_error dep_source dep_actor dep_commit_sha dep_pull_request dep_change_title <<<"$record"

    if [[ -z "$dep_id" ]]; then
      continue
    fi

    # Skip non-production deployments — previews are disabled in Vercel.
    # The API is already filtered to target=production by default, but
    # this guards against edge cases (e.g., empty target on cancelled previews).
    if [[ "$dep_target" != "production" ]]; then
      continue
    fi

    # Skip deployments instantly cancelled by Vercel's "Ignored Build Step".
    # These are production-target entries that never actually built — they
    # arrive already CANCELED with the characteristic error message.
    if [[ "$dep_status" == "CANCELED" && "$dep_error" == *"Ignored Build Step"* ]]; then
      continue
    fi

    old_idx="$(deployment_index_by_id "$dep_id")"
    if (( old_idx >= 0 )); then
      first_seen="${DEP_FIRST_SEEN_EPOCH[old_idx]}"
      last_status="${DEP_LAST_STATUS[old_idx]}"
      announced="${DEP_TERMINAL_ANNOUNCED[old_idx]}"
      step_label="${DEP_STEP[old_idx]}"
      step_history="${DEP_STEP_HISTORY[old_idx]:-}"
      last_event_ms="${DEP_LAST_EVENT_MS[old_idx]}"
      last_event_text="${DEP_LAST_EVENT_TEXT[old_idx]}"
      project_name="${DEP_PROJECT_NAME[old_idx]}"
    else
      first_seen="$(date +%s)"
      last_status=""
      announced="0"
      step_label=""
      step_history=""
      last_event_ms="0"
      last_event_text=""
      project_name="$(derive_short_project_name "$dep_url" "$dep_id")"
    fi

    dep_status="${dep_status:-UNKNOWN}"

    source_label="$(friendly_source_label "$dep_source")"
    actor_label="$(friendly_actor_label "$dep_actor")"
    commit_label="$(friendly_commit_label "$dep_commit_sha")"
    pull_request_label="$(friendly_pull_request_label "$dep_pull_request")"
    if [[ "$pull_request_label" == "n/a" && -n "$dep_branch" ]]; then
      pull_request_label="$(resolve_pr_for_branch "$dep_branch")"
    fi
    change_title_label="$(friendly_change_title "$dep_change_title")"

    next_ids+=("$dep_id")
    next_status+=("$dep_status")
    next_url+=("$dep_url")
    next_created_at+=("$dep_created_at")
    next_ready_at+=("$dep_ready_at")
    next_target+=("$dep_target")
    next_branch+=("$dep_branch")
    next_error+=("$dep_error")
    next_source+=("$source_label")
    next_actor+=("$actor_label")
    next_commit_sha+=("$commit_label")
    next_pull_request+=("$pull_request_label")
    next_change_title+=("$change_title_label")
    next_first_seen+=("$first_seen")
    next_last_status+=("$last_status")
    next_announced+=("$announced")
    next_step+=("$step_label")
    next_step_history+=("$step_history")
    next_last_event_ms+=("$last_event_ms")
    next_last_event_text+=("$last_event_text")
    next_project_name+=("$project_name")
  done <<<"$parsed"

  DEP_IDS=("${next_ids[@]-}")
  DEP_STATUS=("${next_status[@]-}")
  DEP_URL=("${next_url[@]-}")
  DEP_CREATED_AT_MS=("${next_created_at[@]-}")
  DEP_READY_AT_MS=("${next_ready_at[@]-}")
  DEP_TARGET=("${next_target[@]-}")
  DEP_BRANCH=("${next_branch[@]-}")
  DEP_ERROR_MESSAGE=("${next_error[@]-}")
  DEP_SOURCE=("${next_source[@]-}")
  DEP_ACTOR=("${next_actor[@]-}")
  DEP_COMMIT_SHA=("${next_commit_sha[@]-}")
  DEP_PULL_REQUEST=("${next_pull_request[@]-}")
  DEP_CHANGE_TITLE=("${next_change_title[@]-}")
  DEP_FIRST_SEEN_EPOCH=("${next_first_seen[@]-}")
  DEP_LAST_STATUS=("${next_last_status[@]-}")
  DEP_TERMINAL_ANNOUNCED=("${next_announced[@]-}")
  DEP_STEP=("${next_step[@]-}")
  DEP_STEP_HISTORY=("${next_step_history[@]-}")
  DEP_LAST_EVENT_MS=("${next_last_event_ms[@]-}")
  DEP_LAST_EVENT_TEXT=("${next_last_event_text[@]-}")
  DEP_PROJECT_NAME=("${next_project_name[@]-}")

  return 0
}

refresh_single_deployment() {
  local response parsed
  local dep_status dep_id dep_url dep_created_at dep_ready_at dep_target dep_branch dep_error dep_source dep_actor dep_commit_sha dep_pull_request dep_change_title
  local old_idx first_seen last_status announced step_label step_history last_event_ms last_event_text project_name

  if [[ -z "$ACTIVE_SINGLE_TARGET" ]]; then
    ACTIVE_SINGLE_TARGET="$TARGET"
  fi

  if ! response="$(fetch_json "$(build_deployment_url "$ACTIVE_SINGLE_TARGET")")"; then
    warn_line "Failed to fetch deployment '${ACTIVE_SINGLE_TARGET}'. Retrying..."
    return 1
  fi

  if ! parsed="$(printf '%s' "$response" | parse_deployment_payload 2>&1)"; then
    warn_line "Deployment API error for '${ACTIVE_SINGLE_TARGET}': ${parsed}"
    return 1
  fi

  IFS=$'\x1f' read -r dep_status dep_id dep_url dep_created_at dep_ready_at dep_target dep_branch dep_error dep_source dep_actor dep_commit_sha dep_pull_request dep_change_title <<<"$parsed"
  if [[ -n "$dep_id" ]]; then
    ACTIVE_SINGLE_TARGET="$dep_id"
  else
    dep_id="$ACTIVE_SINGLE_TARGET"
  fi

  old_idx="$(deployment_index_by_id "$dep_id")"
  if (( old_idx >= 0 )); then
    first_seen="${DEP_FIRST_SEEN_EPOCH[old_idx]}"
    last_status="${DEP_LAST_STATUS[old_idx]}"
    announced="${DEP_TERMINAL_ANNOUNCED[old_idx]}"
    step_label="${DEP_STEP[old_idx]}"
    step_history="${DEP_STEP_HISTORY[old_idx]:-}"
    last_event_ms="${DEP_LAST_EVENT_MS[old_idx]}"
    last_event_text="${DEP_LAST_EVENT_TEXT[old_idx]}"
    project_name="${DEP_PROJECT_NAME[old_idx]}"
  else
    first_seen="$(date +%s)"
    last_status=""
    announced="0"
    step_label=""
    step_history=""
    last_event_ms="0"
    last_event_text=""
    project_name="$(derive_short_project_name "$dep_url" "$dep_id")"
  fi

  dep_status="${dep_status:-UNKNOWN}"

  DEP_IDS=("$dep_id")
  DEP_STATUS=("$dep_status")
  DEP_URL=("$dep_url")
  DEP_CREATED_AT_MS=("$dep_created_at")
  DEP_READY_AT_MS=("$dep_ready_at")
  DEP_TARGET=("$dep_target")
  DEP_BRANCH=("$dep_branch")
  DEP_ERROR_MESSAGE=("$dep_error")
  DEP_SOURCE=("$(friendly_source_label "$dep_source")")
  DEP_ACTOR=("$(friendly_actor_label "$dep_actor")")
  DEP_COMMIT_SHA=("$(friendly_commit_label "$dep_commit_sha")")
  local _single_pr_label
  _single_pr_label="$(friendly_pull_request_label "$dep_pull_request")"
  if [[ "$_single_pr_label" == "n/a" && -n "$dep_branch" ]]; then
    _single_pr_label="$(resolve_pr_for_branch "$dep_branch")"
  fi
  DEP_PULL_REQUEST=("$_single_pr_label")
  DEP_CHANGE_TITLE=("$(friendly_change_title "$dep_change_title")")
  DEP_FIRST_SEEN_EPOCH=("$first_seen")
  DEP_LAST_STATUS=("$last_status")
  DEP_TERMINAL_ANNOUNCED=("$announced")
  DEP_STEP=("$step_label")
  DEP_STEP_HISTORY=("$step_history")
  DEP_LAST_EVENT_MS=("$last_event_ms")
  DEP_LAST_EVENT_TEXT=("$last_event_text")
  DEP_PROJECT_NAME=("$project_name")

  return 0
}

update_events_for_index() {
  local index="$1"
  local deployment_id since_ms request_since direction response parsed
  local created_ms event_state event_step event_text

  deployment_id="${DEP_IDS[index]}"
  since_ms="${DEP_LAST_EVENT_MS[index]:-0}"
  request_since=""
  direction="backward"

  if [[ "$since_ms" =~ ^[0-9]+$ ]] && (( since_ms > 0 )); then
    request_since=$(( since_ms + 1 ))
    direction="forward"
  fi

  if ! response="$(fetch_json "$(build_deployment_events_url "$deployment_id" "$request_since" 0 "$direction")")"; then
    return 1
  fi

  if ! parsed="$(printf '%s' "$response" | parse_deployment_events_snapshot_payload 2>/dev/null)"; then
    return 1
  fi

  IFS=$'\x1f' read -r created_ms event_state event_step event_text <<<"$parsed"
  if [[ -z "${created_ms}${event_state}${event_step}${event_text}" ]]; then
    return 0
  fi

  record_event_update_for_index "$index" "$created_ms" "$event_state" "$event_step" "$event_text" "poll"
  return 0
}

deployment_step_label() {
  local index="$1"
  local step_text event_text

  step_text="$(sanitize_field "${DEP_STEP[index]:-}")"
  event_text="$(sanitize_field "${DEP_LAST_EVENT_TEXT[index]:-}")"

  if [[ -n "$step_text" ]]; then
    printf '%s' "$step_text"
    return
  fi
  if [[ -n "$event_text" ]]; then
    printf '%s' "$event_text"
    return
  fi

  printf '%s' "$(friendly_status "${DEP_STATUS[index]:-UNKNOWN}")"
}

process_deployment_transitions_and_alerts() {
  local i status old_status dep_id env_label identity_label spoken_identity duration_seconds duration_text duration_mmss spoken_duration
  local target_label target_lower pr_display_label pr_kind_label change_label main_ref_label
  local alert_message spoken_alert error_message

  for (( i = 0; i < ${#DEP_IDS[@]}; i++ )); do
    dep_id="${DEP_IDS[i]}"
    status="${DEP_STATUS[i]:-UNKNOWN}"
    old_status="${DEP_LAST_STATUS[i]:-}"

    # Compute shared labels once per deployment iteration
    env_label="$(friendly_environment_label "${DEP_TARGET[i]:-preview}")"
    identity_label="$(deployment_identity_label "${DEP_BRANCH[i]:-}" "${DEP_TARGET[i]:-preview}" "${DEP_URL[i]:-}" "${DEP_PULL_REQUEST[i]:-}" "${DEP_COMMIT_SHA[i]:-}" "${DEP_SOURCE[i]:-}" "${DEP_ACTOR[i]:-}")"
    spoken_identity="$(spoken_deployment_identity "$identity_label")"
    target_label="$(sanitize_field "${DEP_TARGET[i]:-preview}")"
    target_lower="$(printf '%s' "$target_label" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "$target_lower" ]]; then
      target_lower="preview"
    fi
    pr_display_label="$(pull_request_display_label "${DEP_PULL_REQUEST[i]:-}")"
    pr_kind_label="$(pull_request_kind_label "${DEP_PULL_REQUEST[i]:-}")"
    change_label="$(deployment_change_label "${DEP_CHANGE_TITLE[i]:-}" "${DEP_BRANCH[i]:-}" "${DEP_TARGET[i]:-preview}" "${DEP_URL[i]:-}")"

    if [[ -z "$old_status" ]]; then
      log_line "Watching deployment id=${dep_id} state=${status}"

      # Announce newly discovered deployments that are actively building.
      # Skip voice/alerts on the initial poll — those are pre-existing deployments.
      if is_active_status "$status" && (( _MONITOR_INITIAL_POLL == 0 )); then
        local spoken_change
        if [[ "$change_label" != "n/a" ]]; then
          spoken_change="$change_label"
        else
          # Fall back to branch last segment when no title is available
          spoken_change="${DEP_BRANCH[i]:-}"
          spoken_change="${spoken_change##*/}"
          spoken_change="${spoken_change//[-_]/ }"
        fi

        case "$target_lower" in
          production)
            if [[ -n "$spoken_change" && "$change_label" != "n/a" ]]; then
              alert_message="Starting Main ${spoken_change}."
              spoken_alert="Starting Main ${spoken_change}."
            else
              alert_message="Starting Main."
              spoken_alert="Starting Main."
            fi
            ;;
          preview|"")
            if [[ "$pr_display_label" != "n/a" && -n "$spoken_change" ]]; then
              alert_message="Starting PR ${pr_display_label} ${spoken_change}."
              spoken_alert="Starting PR ${pr_display_label} ${spoken_change}."
            elif [[ "$pr_display_label" != "n/a" ]]; then
              alert_message="Starting PR ${pr_display_label}."
              spoken_alert="Starting PR ${pr_display_label}."
            elif [[ -n "$spoken_change" ]]; then
              alert_message="Starting ${spoken_change}."
              spoken_alert="Starting ${spoken_change}."
            else
              alert_message="Starting ${spoken_identity}."
              spoken_alert="Starting ${spoken_identity}."
            fi
            ;;
          *)
            alert_message="Starting ${spoken_identity}."
            spoken_alert="Starting ${spoken_identity}."
            ;;
        esac

        LAST_ALERT_MESSAGE="$alert_message"
        LAST_ALERT_EPOCH="$(date +%s)"
        LAST_ALERT_LEVEL="info"
        log_line "Alert: ${alert_message}"
        speak_alert "$spoken_alert"
        notify_desktop "Deploy Monitor" "$alert_message" "info"
      fi
    elif [[ "$status" != "$old_status" ]]; then
      log_line "Transition: ${old_status} -> ${status} (id=${dep_id})"
    fi

    main_ref_label="$pr_display_label"
    if [[ "$pr_kind_label" == "MR" && "$pr_display_label" != "n/a" ]]; then
      main_ref_label="MR ${pr_display_label}"
    fi

    duration_seconds="$(duration_seconds_for_record "${DEP_CREATED_AT_MS[i]:-}" "${DEP_READY_AT_MS[i]:-}" "${DEP_FIRST_SEEN_EPOCH[i]:-$(date +%s)}")"
    duration_text="$(format_duration "$duration_seconds")"
    duration_mmss="$(format_duration_mmss "$duration_seconds")"
    error_message="$(sanitize_field "${DEP_ERROR_MESSAGE[i]:-}")"

    if is_terminal_status "$status"; then
      # Mark pre-existing terminal deployments as announced without firing alerts
      if (( ${DEP_TERMINAL_ANNOUNCED[i]:-0} == 0 )) && (( _MONITOR_INITIAL_POLL == 1 )); then
        DEP_TERMINAL_ANNOUNCED[i]=1
      fi
      if (( ${DEP_TERMINAL_ANNOUNCED[i]:-0} == 0 )); then
        spoken_duration="$(format_spoken_duration "$duration_seconds")"

        case "$status" in
          READY)
            case "$target_lower" in
              production)
                if [[ "$pr_display_label" != "n/a" && "$change_label" != "n/a" ]]; then
                  alert_message="Deployed Main ${main_ref_label} ${change_label} in ${duration_mmss}."
                  spoken_alert="Deployed Main ${main_ref_label} ${change_label} in ${spoken_duration}."
                elif [[ "$pr_display_label" != "n/a" ]]; then
                  alert_message="Deployed Main ${main_ref_label} in ${duration_mmss}."
                  spoken_alert="Deployed Main ${main_ref_label} in ${spoken_duration}."
                elif [[ "$change_label" != "n/a" ]]; then
                  alert_message="Deployed Main ${change_label} in ${duration_mmss}."
                  spoken_alert="Deployed Main ${change_label} in ${spoken_duration}."
                else
                  alert_message="Deployed Main in ${duration_mmss}."
                  spoken_alert="Deployed Main in ${spoken_duration}."
                fi
                ;;
              preview|"")
                if [[ "$pr_display_label" != "n/a" ]]; then
                  if [[ "$pr_kind_label" == "MR" ]]; then
                    alert_message="Deployed MR ${pr_display_label} in ${duration_mmss}."
                    spoken_alert="Deployed MR ${pr_display_label} in ${spoken_duration}."
                  else
                    alert_message="Deployed PR ${pr_display_label} in ${duration_mmss}."
                    spoken_alert="Deployed PR ${pr_display_label} in ${spoken_duration}."
                  fi
                elif [[ "$change_label" != "n/a" ]]; then
                  alert_message="Deployed Preview ${change_label} in ${duration_mmss}."
                  spoken_alert="Deployed Preview ${change_label} in ${spoken_duration}."
                else
                  alert_message="Deployed Preview in ${duration_mmss}."
                  spoken_alert="Deployed Preview in ${spoken_duration}."
                fi
                ;;
              *)
                if [[ "$pr_display_label" != "n/a" ]]; then
                  if [[ "$pr_kind_label" == "MR" ]]; then
                    alert_message="Deployed ${env_label} MR ${pr_display_label} in ${duration_mmss}."
                    spoken_alert="Deployed ${env_label} MR ${pr_display_label} in ${spoken_duration}."
                  else
                    alert_message="Deployed ${env_label} PR ${pr_display_label} in ${duration_mmss}."
                    spoken_alert="Deployed ${env_label} PR ${pr_display_label} in ${spoken_duration}."
                  fi
                elif [[ "$change_label" != "n/a" ]]; then
                  alert_message="Deployed ${env_label} ${change_label} in ${duration_mmss}."
                  spoken_alert="Deployed ${env_label} ${change_label} in ${spoken_duration}."
                else
                  alert_message="Deployed ${env_label} in ${duration_mmss}."
                  spoken_alert="Deployed ${env_label} in ${spoken_duration}."
                fi
                ;;
            esac
            LAST_ALERT_LEVEL="success"
            log_line "Alert: ${alert_message}"
            ;;
          ERROR|CANCELED|FAILED)
            alert_message="${env_label} ${identity_label} deployment ended with ${status} after ${duration_text}."
            spoken_alert="${env_label} ${spoken_identity} deployment ended with ${status} after ${spoken_duration}."
            if [[ -n "$error_message" ]]; then
              alert_message="${alert_message} ${error_message}"
              spoken_alert="${spoken_alert} ${error_message}"
            fi
            LAST_ALERT_LEVEL="error"
            warn_line "Alert: ${alert_message}"
            ;;
          *)
            alert_message="${env_label} ${identity_label} deployment ended with ${status} after ${duration_text}."
            spoken_alert="${env_label} ${spoken_identity} deployment ended with ${status} after ${spoken_duration}."
            LAST_ALERT_LEVEL="warning"
            log_line "Alert: ${alert_message}"
            ;;
        esac

        LAST_ALERT_MESSAGE="$alert_message"
        LAST_ALERT_EPOCH="$(date +%s)"
        play_production_beat "${DEP_TARGET[i]:-preview}"
        speak_alert "$spoken_alert"
        notify_desktop "Deploy Monitor" "$alert_message" "${LAST_ALERT_LEVEL}"
        DEP_TERMINAL_ANNOUNCED[i]=1
      fi
    else
      DEP_TERMINAL_ANNOUNCED[i]=0
    fi

    DEP_LAST_STATUS[i]="$status"
  done
}

update_dashboard_overview() {
  local i status

  DASH_DEPLOYMENTS_TOTAL="${#DEP_IDS[@]}"
  DASH_DEPLOYMENTS_ACTIVE=0
  DASH_DEPLOYMENTS_READY=0
  DASH_DEPLOYMENTS_FAILED=0

  for (( i = 0; i < ${#DEP_IDS[@]}; i++ )); do
    status="${DEP_STATUS[i]:-UNKNOWN}"

    if is_active_status "$status"; then
      DASH_DEPLOYMENTS_ACTIVE=$(( DASH_DEPLOYMENTS_ACTIVE + 1 ))
      continue
    fi

    case "$status" in
      READY)
        DASH_DEPLOYMENTS_READY=$(( DASH_DEPLOYMENTS_READY + 1 ))
        ;;
      ERROR|CANCELED|FAILED)
        DASH_DEPLOYMENTS_FAILED=$(( DASH_DEPLOYMENTS_FAILED + 1 ))
        ;;
    esac
  done

  if (( DASH_DEPLOYMENTS_TOTAL == 0 )); then
    DASH_STATUS_LABEL="Waiting for deployment"
    DASH_STATUS_RAW="WAITING"
  elif (( DASH_DEPLOYMENTS_ACTIVE > 0 && DASH_DEPLOYMENTS_FAILED > 0 )); then
    DASH_STATUS_LABEL="Deploying (with failures)"
    DASH_STATUS_RAW="BUILDING"
  elif (( DASH_DEPLOYMENTS_ACTIVE > 0 )); then
    DASH_STATUS_LABEL="Deploying"
    DASH_STATUS_RAW="BUILDING"
  elif (( DASH_DEPLOYMENTS_FAILED > 0 && DASH_DEPLOYMENTS_READY == 0 )); then
    DASH_STATUS_LABEL="Failed"
    DASH_STATUS_RAW="ERROR"
  elif (( DASH_DEPLOYMENTS_READY > 0 )); then
    DASH_STATUS_LABEL="Ready"
    DASH_STATUS_RAW="READY"
  else
    DASH_STATUS_LABEL="Unknown"
    DASH_STATUS_RAW="UNKNOWN"
  fi

  if [[ -n "$PROJECT_SHORT_NAME" ]]; then
    DASH_PROJECT_NAME="$PROJECT_SHORT_NAME"
  elif [[ "$WATCH_MODE" == "project" ]]; then
    DASH_PROJECT_NAME="${PROJECT_ID#prj_}"
  elif (( ${#DEP_PROJECT_NAME[@]} > 0 )); then
    DASH_PROJECT_NAME="${DEP_PROJECT_NAME[0]}"
  fi

  DASH_UPDATED_AT_LABEL="$(date '+%H:%M:%S')"
}

_is_old_deployment() {
  local created_at_ms="$1"
  local now_seconds age_seconds

  if ! [[ "$created_at_ms" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  now_seconds="$(date +%s)"
  age_seconds=$(( now_seconds - (created_at_ms / 1000) ))
  (( age_seconds >= 14400 ))
}

_step_phase_index() {
  local step_text="$1"
  local normalized
  normalized="$(printf '%s' "$step_text" | tr '[:upper:]' '[:lower:]')"

  if [[ "$normalized" == *"queue"* ]]; then printf '0'; return; fi
  if [[ "$normalized" == *"init"* ]]; then printf '1'; return; fi
  if [[ "$normalized" == *"clone"* ]] || [[ "$normalized" == *"checkout"* ]]; then printf '2'; return; fi
  if [[ "$normalized" == *"install"* ]] || [[ "$normalized" == *"depend"* ]]; then printf '3'; return; fi
  if [[ "$normalized" == *"build"* ]] || [[ "$normalized" == *"compile"* ]]; then printf '4'; return; fi
  if [[ "$normalized" == *"upload"* ]] || [[ "$normalized" == *"deploy"* ]] || [[ "$normalized" == *"final"* ]]; then printf '5'; return; fi
  printf '-1'
}

_current_phase_index() {
  local status="$1"
  local step_text="$2"
  local normalized
  normalized="$(printf '%s' "$step_text" | tr '[:upper:]' '[:lower:]')"

  case "$status" in
    READY)                 printf '6'; return ;;
    ERROR|CANCELED|FAILED) printf '6'; return ;;
    QUEUED)                printf '0'; return ;;
    INITIALIZING)          printf '1'; return ;;
    BUILDING)
      if [[ "$normalized" == *"clone"* ]] || [[ "$normalized" == *"checkout"* ]]; then
        printf '2'; return
      elif [[ "$normalized" == *"install"* ]] || [[ "$normalized" == *"depend"* ]]; then
        printf '3'; return
      elif [[ "$normalized" == *"build"* ]] || [[ "$normalized" == *"compile"* ]]; then
        printf '4'; return
      elif [[ "$normalized" == *"upload"* ]] || [[ "$normalized" == *"deploy"* ]] || [[ "$normalized" == *"final"* ]]; then
        printf '5'; return
      fi
      printf '4'; return
      ;;
  esac
  printf '0'
}

# Render detailed step lines for active deployments.
# Outputs multiple lines showing completed steps with timings, current step, and next steps.
_render_active_steps() {
  local status="$1"
  local step_text="$2"
  local step_history="$3"
  local now_seconds="$4"

  local phases=("Queue" "Init" "Clone" "Install" "Build" "Deploy")
  local current_idx
  current_idx="$(_current_phase_index "$status" "$step_text")"

  # Parse step history into parallel arrays: phase_epochs[phase_idx]=epoch
  local phase_epochs=("" "" "" "" "" "")
  if [[ -n "$step_history" ]]; then
    local IFS='|'
    local entry
    for entry in $step_history; do
      local entry_key="${entry%%:*}"
      local entry_epoch="${entry##*:}"
      local pidx
      pidx="$(_step_phase_index "$entry_key")"
      if (( pidx >= 0 && pidx < 6 )); then
        phase_epochs[pidx]="$entry_epoch"
      fi
    done
  fi

  local p line_prefix phase_color timing_text

  for (( p = 0; p < ${#phases[@]}; p++ )); do
    if (( p < current_idx )); then
      # Completed phase — show with duration
      timing_text=""
      if [[ -n "${phase_epochs[p]}" ]]; then
        local phase_start="${phase_epochs[p]}"
        local phase_end=""
        # Find next phase start as this phase's end
        local np
        for (( np = p + 1; np < 6; np++ )); do
          if [[ -n "${phase_epochs[np]}" ]]; then
            phase_end="${phase_epochs[np]}"
            break
          fi
        done
        if [[ -z "$phase_end" ]]; then
          phase_end="$now_seconds"
        fi
        local phase_dur=$(( phase_end - phase_start ))
        if (( phase_dur >= 0 )); then
          timing_text="$(format_duration "$phase_dur")"
        fi
      fi
      if [[ -n "$timing_text" ]]; then
        print_dashboard_linef '     %s%s %s%s' "${C_GREEN}" "${phases[p]}" "${C_DIM}${timing_text}${C_RESET}" ""
      else
        print_dashboard_linef '     %s%s%s' "${C_GREEN}" "${phases[p]}" "${C_RESET}"
      fi
    elif (( p == current_idx )); then
      # Current phase — highlighted with elapsed time
      timing_text=""
      if [[ -n "${phase_epochs[p]}" ]]; then
        local phase_elapsed=$(( now_seconds - phase_epochs[p] ))
        if (( phase_elapsed >= 0 )); then
          timing_text="$(format_duration "$phase_elapsed")"
        fi
      fi
      local spinner
      spinner="$(spinner_frame)"
      if [[ -n "$timing_text" ]]; then
        print_dashboard_linef '   %s %s%s %s%s' "$spinner" "${C_BOLD_YELLOW}" "${phases[p]}" "${timing_text}${C_RESET}" ""
      else
        print_dashboard_linef '   %s %s%s%s' "$spinner" "${C_BOLD_YELLOW}" "${phases[p]}" "${C_RESET}"
      fi
    else
      # Future phase — dim
      print_dashboard_linef '     %s%s%s' "${C_DIM}" "${phases[p]}" "${C_RESET}"
    fi
  done
}

render_dashboard() {
  local status_mark
  local i status step_label duration_seconds duration_text
  local change_title_label error_text now_seconds

  if (( DASHBOARD_ENABLED == 0 )); then
    return
  fi

  now_seconds="$(date +%s)"
  status_mark="$(status_icon "${DASH_STATUS_RAW:-UNKNOWN}")"

  begin_dashboard_render

  # ── Header ──
  print_dashboard_linef '%s%s%s  %s  %s' \
    "${C_BOLD_CYAN}" "${DASH_PROJECT_NAME:-Vercel}" "${C_RESET}" \
    "$status_mark" \
    "${C_DIM}${DASH_UPDATED_AT_LABEL:-n/a}${C_RESET}"

  # ── Alert banner (only when meaningful) ──
  if [[ "${LAST_ALERT_MESSAGE:-None}" != "None" && "${LAST_ALERT_MESSAGE:-}" != "Starting..." ]]; then
    local alert_age_display alert_mark_icon
    alert_mark_icon="$(alert_icon "${LAST_ALERT_LEVEL:-info}")"
    alert_age_display="$(format_epoch_with_relative "$LAST_ALERT_EPOCH")"
    print_dashboard_linef '%s %s  %s' "$alert_mark_icon" "${LAST_ALERT_MESSAGE}" "${C_DIM}${alert_age_display}${C_RESET}"
  fi

  print_dashboard_line ""

  if (( ${#DEP_IDS[@]} == 0 )); then
    print_dashboard_linef '%sWaiting for deployments...%s' "${C_DIM}" "${C_RESET}"
  else
    # Separate old (>=4h) from recent deployments
    local recent_indices=()
    local old_indices=()
    for (( i = 0; i < ${#DEP_IDS[@]}; i++ )); do
      if _is_old_deployment "${DEP_CREATED_AT_MS[i]:-}"; then
        old_indices+=("$i")
      else
        recent_indices+=("$i")
      fi
    done

    # ── Recent / Active deployments ──
    for i in "${recent_indices[@]}"; do
      status="${DEP_STATUS[i]:-UNKNOWN}"

      change_title_label="$(deployment_change_label "${DEP_CHANGE_TITLE[i]:-}" "${DEP_BRANCH[i]:-}" "${DEP_TARGET[i]:-preview}" "${DEP_URL[i]:-}")"
      local pr_display
      pr_display="$(pull_request_display_label "$(sanitize_field "${DEP_PULL_REQUEST[i]:-}")")"

      # Build concise title: PR#N title or just title
      local title_raw=""
      if [[ "$pr_display" != "n/a" ]]; then
        title_raw="${pr_display} "
      fi
      if [[ "$change_title_label" != "n/a" ]]; then
        title_raw="${title_raw}${change_title_label}"
      fi
      if [[ -z "$title_raw" ]]; then
        title_raw="$(deployment_identity_label "${DEP_BRANCH[i]:-}" "${DEP_TARGET[i]:-preview}" "${DEP_URL[i]:-}" "${DEP_PULL_REQUEST[i]:-}" "${DEP_COMMIT_SHA[i]:-}" "${DEP_SOURCE[i]:-}" "${DEP_ACTOR[i]:-}")"
      fi
      title_raw="$(truncate_text "$title_raw" 120)"

      duration_seconds="$(duration_seconds_for_record "${DEP_CREATED_AT_MS[i]:-}" "${DEP_READY_AT_MS[i]:-}" "${DEP_FIRST_SEEN_EPOCH[i]:-$now_seconds}")"
      duration_text="$(format_duration "$duration_seconds")"

      if is_active_status "$status"; then
        # ── Active: full card with step details ──
        local env_mark status_label
        env_mark="$(environment_icon "${DEP_TARGET[i]:-preview}")"
        status_label="$(friendly_status "$status")"

        print_dashboard_linef '%s %s  %s  %s%s%s' \
          "$env_mark" "$(color_pad "$status_label" 12)" "$(color_pad "$title_raw" 120)" \
          "${C_DIM}" "$duration_text" "${C_RESET}"

        step_label="$(deployment_step_label "$i")"
        _render_active_steps "$status" "$step_label" "${DEP_STEP_HISTORY[i]:-}" "$now_seconds"
        print_dashboard_line ""
      else
        # ── Completed (ready/error/canceled): compact single line ──
        local row_icon started_relative
        row_icon="$(status_icon "$status")"
        started_relative="$(relative_time_from_ms "${DEP_CREATED_AT_MS[i]:-}")"

        print_dashboard_linef '  %s  %s  %s%6s  %s%s' \
          "$row_icon" "$(color_pad "$title_raw" 120)" \
          "${C_DIM}" "$duration_text" "$started_relative" "${C_RESET}"

        error_text="$(sanitize_field "${DEP_ERROR_MESSAGE[i]:-}")"
        if [[ -n "$error_text" && ( "$status" == "ERROR" || "$status" == "FAILED" || "$status" == "CANCELED" ) ]]; then
          error_text="$(truncate_text "$error_text" 80)"
          print_dashboard_linef '    %s%s%s' "${C_RED}" "$error_text" "${C_RESET}"
        fi
      fi
    done

    # ── Old deployments (compact) ──
    if (( ${#old_indices[@]} > 0 )); then
      print_dashboard_linef '%s── older ──%s' "${C_DIM}" "${C_RESET}"
      for i in "${old_indices[@]}"; do
        status="${DEP_STATUS[i]:-UNKNOWN}"
        local row_icon started_time_label old_title old_error

        row_icon="$(status_icon "$status")"
        started_time_label="$(format_ms_local "${DEP_CREATED_AT_MS[i]:-}")"
        old_title="$(deployment_change_label "${DEP_CHANGE_TITLE[i]:-}" "${DEP_BRANCH[i]:-}" "${DEP_TARGET[i]:-preview}" "${DEP_URL[i]:-}")"
        old_title="$(truncate_text "$old_title" 90)"

        duration_seconds="$(duration_seconds_for_record "${DEP_CREATED_AT_MS[i]:-}" "${DEP_READY_AT_MS[i]:-}" "${DEP_FIRST_SEEN_EPOCH[i]:-$now_seconds}")"
        duration_text="$(format_duration "$duration_seconds")"

        if [[ "$status" == "ERROR" || "$status" == "FAILED" ]]; then
          old_error="$(sanitize_field "${DEP_ERROR_MESSAGE[i]:-}")"
          old_error="$(truncate_text "$old_error" 40)"
          print_dashboard_linef '  %s  %s%s%s  %s  %s%6s  %s%s%s' \
            "$row_icon" "${C_DIM}" "$started_time_label" "${C_RESET}" \
            "$(color_pad "$old_title" 90)" \
            "${C_DIM}" "$duration_text" "${C_RED}${old_error}" "${C_RESET}" ""
        else
          print_dashboard_linef '  %s  %s%s%s  %s  %s%6s%s' \
            "$row_icon" "${C_DIM}" "$started_time_label" "${C_RESET}" \
            "$(color_pad "$old_title" 90)" \
            "${C_DIM}" "$duration_text" "${C_RESET}"
        fi
      done
      print_dashboard_line ""
    fi
  fi

  end_dashboard_render
}

cleanup_runtime() {
  _dashboard_leave_alt_screen
  stop_all_event_stream_workers
  cleanup_audio_runtime
}

handle_interrupt() {
  warn_line "Stopped deployment monitor."
  DASH_STATUS_LABEL="Stopped"
  DASH_STATUS_RAW="STOPPED"
  render_dashboard
  if (( DASHBOARD_ENABLED == 1 )); then
    echo
  fi
  exit 0
}

if ! command -v curl >/dev/null 2>&1; then
  print_error "curl is required."
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  print_error "node is required."
  exit 1
fi

INTERVAL_SECONDS=10
TIMEOUT_SECONDS=0
TEAM_ID="${VERCEL_TEAM_ID:-${VERCEL_ORG_ID:-}}"
PROJECT_ID="${VERCEL_PROJECT_ID:-}"
PROJECT_SHORT_NAME="${VERCEL_PROJECT_SHORT_NAME:-}"
REPO_PATH=""
TOKEN="${VERCEL_TOKEN:-}"
TOKEN_FROM_ARG=0
ENABLE_SPEAK=1
FORCE_PLAIN=0
VOICE_NAME="Ava (Premium)"
TARGET=""
TARGET_FILTER="production"
MAX_DEPLOYMENTS=6
EVENT_MODE="auto"

DASH_PROJECT_NAME="n/a"
DASH_MODE_LABEL="n/a"
DASH_STATUS_LABEL="Waiting"
DASH_STATUS_RAW="WAITING"
DASH_FEED_LABEL="Polling"
DASH_UPDATED_AT_LABEL="n/a"
DASH_DEPLOYMENTS_TOTAL=0
DASH_DEPLOYMENTS_ACTIVE=0
DASH_DEPLOYMENTS_READY=0
DASH_DEPLOYMENTS_FAILED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
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
    --repo)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      REPO_PATH="$2"
      shift 2
      ;;
    --project-id)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      PROJECT_ID="$2"
      shift 2
      ;;
    --project-name|--voice-project-name)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      PROJECT_SHORT_NAME="$2"
      shift 2
      ;;
    --team-id|--scope|--org-id)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      TEAM_ID="$2"
      shift 2
      ;;
    --token)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      TOKEN="$2"
      TOKEN_FROM_ARG=1
      shift 2
      ;;
    --target)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      TARGET_FILTER="$2"
      shift 2
      ;;
    --max-deployments)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      MAX_DEPLOYMENTS="$2"
      shift 2
      ;;
    --event-mode)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      EVENT_MODE="$2"
      shift 2
      ;;
    --voice)
      if [[ $# -lt 2 ]]; then
        print_error "$1 requires a value."
        exit 1
      fi
      VOICE_NAME="$2"
      shift 2
      ;;
    --notify)
      DESKTOP_NOTIFICATIONS=1
      shift
      ;;
    --no-speak)
      ENABLE_SPEAK=0
      shift
      ;;
    --plain)
      FORCE_PLAIN=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      print_error "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -n "$TARGET" ]]; then
        print_error "Unexpected argument: $1"
        usage
        exit 1
      fi
      TARGET="$1"
      shift
      ;;
  esac
done

if [[ -z "$TOKEN" && -t 0 ]]; then
  read -r -s -p "Vercel token: " TOKEN
  echo
fi

if [[ -z "$TOKEN" ]]; then
  print_error "Missing token. Use VERCEL_TOKEN, --token, or secure prompt in an interactive terminal."
  exit 1
fi

if (( TOKEN_FROM_ARG == 1 )); then
  warn_line "Warning: --token can leak via shell history/process list. Prefer VERCEL_TOKEN or secure prompt."
fi

if ! [[ "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  print_error "--interval must be a positive integer."
  exit 1
fi

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  print_error "--timeout must be a non-negative integer."
  exit 1
fi

if ! [[ "$MAX_DEPLOYMENTS" =~ ^[1-9][0-9]*$ ]]; then
  print_error "--max-deployments must be a positive integer."
  exit 1
fi

EVENT_MODE="$(printf '%s' "$EVENT_MODE" | tr '[:upper:]' '[:lower:]')"
if [[ "$EVENT_MODE" != "auto" && "$EVENT_MODE" != "stream" && "$EVENT_MODE" != "poll" ]]; then
  print_error "--event-mode must be one of: auto, stream, poll."
  exit 1
fi

TARGET_FILTER="$(printf '%s' "$TARGET_FILTER" | tr '[:upper:]' '[:lower:]')"
if [[ -n "$TARGET_FILTER" && "$TARGET_FILTER" != "production" ]]; then
  if [[ "$TARGET_FILTER" == "preview" ]]; then
    print_error "--target preview is no longer supported (preview deployments are disabled)."
  else
    print_error "--target must be: production."
  fi
  exit 1
fi

# Resolve --repo: read .vercel/project.json for projectId and orgId
if [[ -n "${REPO_PATH:-}" ]]; then
  VERCEL_JSON="${REPO_PATH}/.vercel/project.json"
  if [[ ! -f "$VERCEL_JSON" ]]; then
    print_error "No .vercel/project.json found at '${REPO_PATH}'. Run 'vercel link' in that repo first."
    exit 1
  fi
  if [[ -z "$PROJECT_ID" ]]; then
    PROJECT_ID="$(node -e "const p=require('${VERCEL_JSON}'); process.stdout.write(p.projectId||'')" 2>/dev/null)"
  fi
  if [[ -z "$TEAM_ID" ]]; then
    TEAM_ID="$(node -e "const p=require('${VERCEL_JSON}'); process.stdout.write(p.orgId||'')" 2>/dev/null)"
  fi
  if [[ -z "$PROJECT_SHORT_NAME" ]]; then
    PROJECT_SHORT_NAME="$(node -e "const p=require('${VERCEL_JSON}'); process.stdout.write(p.projectName||'')" 2>/dev/null)"
  fi
fi

WATCH_MODE="deployment"
if [[ -n "$TARGET" ]]; then
  TARGET="$(normalize_target "$TARGET")"
  if [[ -z "$TARGET" ]]; then
    print_error "Deployment target is empty after normalization."
    exit 1
  fi
else
  if [[ -z "$PROJECT_ID" ]]; then
    print_error "Provide a deployment id/url or set --project-id (or VERCEL_PROJECT_ID)."
    usage
    exit 1
  fi
  WATCH_MODE="project"
fi

if (( FORCE_PLAIN == 0 )) && [[ -t 1 ]]; then
  DASHBOARD_ENABLED=1
fi

EVENT_MODE_ACTIVE="$EVENT_MODE"
if [[ "$EVENT_MODE_ACTIVE" == "auto" ]]; then
  if (( DASHBOARD_ENABLED == 1 )); then
    EVENT_MODE_ACTIVE="stream"
  else
    EVENT_MODE_ACTIVE="poll"
  fi
fi

if (( ENABLE_SPEAK == 1 )); then
  detect_speaker_cmd
  if [[ "$SPEAKER_CMD" == "say" && -n "$VOICE_NAME" ]]; then
    SPEAKER_ARGS=(-v "$VOICE_NAME")
  fi
fi

DASH_MODE_LABEL="$(friendly_mode_label)"
if [[ -n "$PROJECT_SHORT_NAME" ]]; then
  DASH_PROJECT_NAME="$PROJECT_SHORT_NAME"
elif [[ "$WATCH_MODE" == "project" ]]; then
  DASH_PROJECT_NAME="${PROJECT_ID#prj_}"
elif [[ -n "$TARGET" ]]; then
  DASH_PROJECT_NAME="$(derive_short_project_name "$TARGET" "$TARGET")"
fi

if [[ "$EVENT_MODE_ACTIVE" == "stream" ]]; then
  DASH_FEED_LABEL="Streaming"
else
  DASH_FEED_LABEL="Polling"
fi

MAX_STREAM_WORKERS=4
if (( MAX_DEPLOYMENTS < MAX_STREAM_WORKERS )); then
  MAX_STREAM_WORKERS="$MAX_DEPLOYMENTS"
fi
if (( MAX_STREAM_WORKERS < 1 )); then
  MAX_STREAM_WORKERS=1
fi

DEP_IDS=()
DEP_STATUS=()
DEP_URL=()
DEP_CREATED_AT_MS=()
DEP_READY_AT_MS=()
DEP_TARGET=()
DEP_BRANCH=()
DEP_ERROR_MESSAGE=()
DEP_SOURCE=()
DEP_ACTOR=()
DEP_COMMIT_SHA=()
DEP_PULL_REQUEST=()
DEP_CHANGE_TITLE=()
DEP_FIRST_SEEN_EPOCH=()
DEP_LAST_STATUS=()
DEP_TERMINAL_ANNOUNCED=()
DEP_STEP=()
DEP_STEP_HISTORY=()    # "phase:epoch_s|phase:epoch_s|..." — tracks step transitions with timestamps
DEP_LAST_EVENT_MS=()
DEP_LAST_EVENT_TEXT=()
DEP_PROJECT_NAME=()

STREAM_IDS=()
STREAM_PIDS=()
EVENT_BUS_OFFSET=0
EVENT_BUS_TRUNCATE_LINES=2000
EVENT_RECONCILE_EVERY=6
EVENT_RECONCILE_CYCLE=0
EVENT_BUS_FILE=""
RUNTIME_DIR_PREFIX="vercel-deploy-monitor"
ACTIVE_SINGLE_TARGET=""

if [[ "$EVENT_MODE_ACTIVE" == "stream" ]]; then
  if ensure_runtime_dir "$RUNTIME_DIR_PREFIX"; then
    EVENT_BUS_FILE="${RUNTIME_DIR}/events.log"
    : >"$EVENT_BUS_FILE"
  else
    warn_line "Failed to create runtime dir for event streaming. Falling back to polling mode."
    EVENT_MODE_ACTIVE="poll"
    DASH_FEED_LABEL="Polling"
  fi
fi

start_audio_queue_worker

if [[ "$WATCH_MODE" == "deployment" ]]; then
  log_line "Monitoring deployment '${TARGET}' every ${INTERVAL_SECONDS}s (Ctrl+C to stop)..."
else
  log_line "Monitoring latest ${MAX_DEPLOYMENTS} deployments for project '${PROJECT_ID}' every ${INTERVAL_SECONDS}s (Ctrl+C to stop)..."
fi

if [[ -n "$TEAM_ID" ]]; then
  log_line "Using team id: ${TEAM_ID}"
fi

if [[ -n "$SPEAKER_CMD" ]]; then
  if [[ "$SPEAKER_CMD" == "say" ]]; then
    log_line "Spoken alerts enabled via '${SPEAKER_CMD}' (voice: ${VOICE_NAME})."
  else
    log_line "Spoken alerts enabled via '${SPEAKER_CMD}'."
  fi
  if (( AUDIO_QUEUE_ENABLED == 1 )); then
    log_line "Voice alerts are serialized via audio queue."
  fi
fi
if [[ -n "$PROJECT_SHORT_NAME" ]]; then
  log_line "Using spoken project name: ${PROJECT_SHORT_NAME}"
fi
log_line "Event mode: ${EVENT_MODE_ACTIVE}"

update_dashboard_overview
render_dashboard

trap 'handle_interrupt' INT TERM
trap 'cleanup_runtime' EXIT

START_EPOCH="$(date +%s)"
NO_DEPLOYMENTS_REPORTED=0
_MONITOR_INITIAL_POLL=1

while true; do
  local_refresh_ok=1

  check_timeout_or_exit

  if [[ "$WATCH_MODE" == "project" ]]; then
    if ! refresh_project_deployments; then
      local_refresh_ok=0
    fi

    if (( local_refresh_ok == 0 )); then
      DASH_STATUS_LABEL="Connection issue"
      DASH_STATUS_RAW="CONNECTION_ISSUE"
      update_dashboard_overview
      render_dashboard
      sleep_for_next_poll
      continue
    fi

    if (( ${#DEP_IDS[@]} == 0 )); then
      if (( NO_DEPLOYMENTS_REPORTED == 0 )); then
        log_line "No deployments found yet for project '${PROJECT_ID}'."
        NO_DEPLOYMENTS_REPORTED=1
      fi
      DASH_STATUS_LABEL="Waiting for deployment"
      DASH_STATUS_RAW="WAITING"
      update_dashboard_overview
      render_dashboard
      sleep_for_next_poll
      continue
    fi
    NO_DEPLOYMENTS_REPORTED=0
  else
    if ! refresh_single_deployment; then
      DASH_STATUS_LABEL="Connection issue"
      DASH_STATUS_RAW="CONNECTION_ISSUE"
      update_dashboard_overview
      render_dashboard
      sleep_for_next_poll
      continue
    fi
  fi

  if [[ "$EVENT_MODE_ACTIVE" == "stream" ]]; then
    reconcile_event_stream_workers
    consume_event_bus_updates
    EVENT_RECONCILE_CYCLE=$(( EVENT_RECONCILE_CYCLE + 1 ))
  fi

  # In stream mode, poll only for deployments without active streams, plus periodic reconciliation.
  for (( i = 0; i < ${#DEP_IDS[@]}; i++ )); do
    should_poll_events=1
    if [[ "$EVENT_MODE_ACTIVE" == "stream" ]]; then
      should_poll_events=0
      stream_index_for_dep="$(stream_worker_index_by_id "${DEP_IDS[i]}")"
      if (( stream_index_for_dep < 0 )); then
        should_poll_events=1
      elif (( EVENT_RECONCILE_CYCLE % EVENT_RECONCILE_EVERY == 0 )); then
        should_poll_events=1
      fi
    fi

    if (( should_poll_events == 1 )); then
      update_events_for_index "$i" >/dev/null 2>&1 || true
    fi
  done

  process_deployment_transitions_and_alerts
  _MONITOR_INITIAL_POLL=0
  update_dashboard_overview
  render_dashboard
  sleep_for_next_poll
done
