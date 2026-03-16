# ci-scripts

Reusable CI/CD monitoring scripts — GitHub Actions timing, PR status, and Vercel deployments.

## Scripts

| Script | Purpose |
|---|---|
| `monitor-ci-timing.sh` | Monitor GitHub Actions CI run timings, detect regressions vs baseline branch |
| `monitor-gh-prs.sh` | Monitor open PRs with voice alerts on state transitions (CI, review, merge conflicts) |
| `monitor-vercel-deployment.sh` | Monitor Vercel deployments (single or project-wide) with build step tracking |

## Shared libraries (`lib/`)

| File | Purpose |
|---|---|
| `lib/monitor-core.sh` | ANSI colors, logging, time formatting, git/repo detection |
| `lib/monitor-dashboard.sh` | Terminal dashboard rendering primitives (line-by-line overwrite) |
| `lib/monitor-audio.sh` | Audio queue, TTS speaker detection, cross-process speech locking, desktop notifications |

## Usage

All GitHub-based scripts accept a repo as the first positional argument:

```bash
# GitHub Actions CI timing monitor
./monitor-ci-timing.sh owner/repo --branch main --interval 20

# PR status monitor with voice alerts
./monitor-gh-prs.sh owner/repo --author @me --auto-update

# Vercel deployment monitor (uses project-id, not repo)
VERCEL_TOKEN=... ./monitor-vercel-deployment.sh --project-id prj_xxx --project-name "my-app"
```

Run any script with `--help` for full options.

## PR Monitor Web UI (`pr-monitor/`)

Real-time PR dashboard in the browser — webhook-driven, zero npm dependencies.

```bash
# Install the webhook extension (one-time)
gh extension install cli/gh-webhook

# Start the monitor
node pr-monitor/server.js 3twos/inposter
# Open http://localhost:8420
```

Features: real-time updates via GitHub webhooks + SSE, voice alerts (Web Speech API), desktop notifications, dark-mode UI, auto-reconnect. Falls back to polling if webhooks aren't available.

Options: `--port`, `--author`, `--branch`, `--auto-update`, `--no-voice`, `--no-webhook`, `--interval`.

## Prerequisites

- `gh` (GitHub CLI) — authenticated via `gh auth login`
- `node` (Node.js) — for JSON parsing
- `curl` — for Vercel API calls
- macOS `say` (or `spd-say`/`espeak` on Linux) — optional, for voice alerts
