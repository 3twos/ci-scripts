#!/usr/bin/env node
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { execFile, spawn } = require('node:child_process');

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const config = {
  repo: '',
  port: 8420,
  interval: 120,
  maxPrs: 10,
  author: '',
  branch: '',
  autoUpdate: false,
  noVoice: false,
  noWebhook: false,
};

function usage() {
  console.log(`
PR Monitor — real-time GitHub PR dashboard

Usage: node server.js [options]

Options:
  --repo <owner/repo>    Repository (auto-detected from git remote if omitted)
  --port <number>        HTTP port (default: 8420)
  --interval <seconds>   Poll fallback interval (default: 120)
  --max-prs <count>      Max PRs to track (default: 10)
  --author <login>       Filter by author (@me for yourself)
  --branch <branch>      Filter by head branch
  --auto-update          Auto-update PRs behind base branch
  --no-voice             Disable voice alerts in browser
  --no-webhook           Skip webhook forwarder, polling only
  -h, --help             Show this help
`.trim());
}

function parseArgs(argv) {
  const args = argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-h': case '--help': usage(); process.exit(0);
      case '--repo': config.repo = args[++i] || ''; break;
      case '--port': config.port = parseInt(args[++i], 10) || 8420; break;
      case '--interval': config.interval = parseInt(args[++i], 10) || 120; break;
      case '--max-prs': config.maxPrs = parseInt(args[++i], 10) || 10; break;
      case '--author': config.author = args[++i] || ''; break;
      case '--branch': config.branch = args[++i] || ''; break;
      case '--auto-update': config.autoUpdate = true; break;
      case '--no-voice': config.noVoice = true; break;
      case '--no-webhook': config.noWebhook = true; break;
      default:
        // Positional: treat as repo if it looks like owner/repo
        if (!config.repo && args[i].includes('/') && !args[i].startsWith('-')) {
          config.repo = args[i];
        } else {
          console.error(`Unknown option: ${args[i]}`);
          usage();
          process.exit(1);
        }
    }
  }
}

// ---------------------------------------------------------------------------
// gh CLI wrapper
// ---------------------------------------------------------------------------

function gh(args, { timeout = 30000 } = {}) {
  return new Promise((resolve, reject) => {
    execFile('gh', args, { timeout, maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) {
        const msg = stderr?.trim() || err.message;
        reject(new Error(`gh ${args.slice(0, 3).join(' ')}: ${msg}`));
      } else {
        resolve(stdout);
      }
    });
  });
}

async function ghJson(args, opts) {
  const out = await gh(args, opts);
  return JSON.parse(out);
}

function detectRepoFromGit() {
  return new Promise((resolve, reject) => {
    execFile('git', ['remote', 'get-url', 'origin'], { timeout: 5000 }, (err, stdout) => {
      if (err) return reject(new Error('Could not detect repo from git remote'));
      let url = stdout.trim();
      url = url.replace(/^git@github\.com:/, '').replace(/^https?:\/\/github\.com\//, '').replace(/\.git$/, '');
      if (!url.includes('/')) return reject(new Error('Could not parse repo slug'));
      resolve(url);
    });
  });
}

async function checkPrereqs() {
  try {
    await gh(['auth', 'status']);
  } catch {
    console.error('Error: gh CLI not authenticated. Run: gh auth login');
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// PR State Store
// ---------------------------------------------------------------------------

/** @type {Map<number, object>} */
const prStore = new Map();
const alertLog = [];
const MAX_ALERTS = 50;
const STILL_THRESHOLD_MS = 60_000;
const STILL_REPEAT_MS = 60_000;

function makePrState(raw) {
  return {
    number: raw.number,
    title: raw.title || '',
    author: raw.author?.login || raw.author || '',
    branch: raw.headRefName || '',
    url: raw.url || '',
    isDraft: !!raw.isDraft,
    mergeable: 'UNKNOWN',
    mergeStateStatus: 'UNKNOWN',
    ciStatus: 'none',
    reviewDecision: '',
    reviewState: 'none',
    reviewCount: 0,
    reviewers: [],
    unresolvedThreads: 0,
    totalThreads: 0,
    requestedReviewers: [],
    additions: 0,
    deletions: 0,
    changedFiles: 0,
    sizeLabel: '',
    humanReviewed: false,
    commentSeverity: { critical: 0, suggestion: 0, note: 0 },
    isReady: false,
    isUpdating: false,
    updatedAt: Date.now(),
    _prev: null,
    _announced: { created: false, conflicts: false, ciFail: false, noReview: false, ready: false },
    _issueSinceEpoch: 0,
    _lastStillEpoch: 0,
  };
}

// ---------------------------------------------------------------------------
// GitHub Data Fetching
// ---------------------------------------------------------------------------

async function fetchPrList() {
  const jsonFields = 'number,title,headRefName,author,isDraft,url';
  const args = ['pr', 'list', '-R', config.repo, '--state', 'open', '--limit', String(config.maxPrs), '--json', jsonFields];
  if (config.author) args.push('--author', config.author);
  if (config.branch) args.push('--head', config.branch);
  return ghJson(args);
}

async function fetchPrDetail(number) {
  const fields = 'number,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,reviews,reviewRequests,isDraft,additions,deletions,changedFiles';
  return ghJson(['pr', 'view', String(number), '-R', config.repo, '--json', fields]);
}

async function fetchReviewInsights(number) {
  const [owner, name] = config.repo.split('/');
  const query = `query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){pullRequest(number:$num){reviewThreads(first:100){nodes{isResolved,comments(first:1){nodes{body,author{login}}}}}}}}`;
  try {
    const result = await ghJson(['api', 'graphql', '-f', `query=${query}`, '-F', `o=${owner}`, '-F', `n=${name}`, '-F', `num=${number}`]);
    const threads = result.data?.repository?.pullRequest?.reviewThreads?.nodes || [];
    const total = threads.length;
    const unresolved = threads.filter(t => !t.isResolved).length;

    // Classify comment severity
    const severity = { critical: 0, suggestion: 0, note: 0 };
    const criticalRe = /\b(bug|security|vulnerability|crash|data.?loss|breaking|critical|must fix|error handling|race.?condition|injection|xss|overflow|undefined|null.?pointer|incorrect|wrong)\b/i;
    const suggestionRe = /\b(nit|suggestion|consider|optional|minor|style|typo|rename|cosmetic|could|might|prefer|cleanup|formatting|naming)\b/i;

    for (const t of threads) {
      const body = t.comments?.nodes?.[0]?.body || '';
      if (criticalRe.test(body)) severity.critical++;
      else if (suggestionRe.test(body)) severity.suggestion++;
      else if (body.length > 0) severity.note++;
    }

    // Detect if any human (non-bot) reviewed
    const humanAuthors = new Set();
    for (const t of threads) {
      const login = t.comments?.nodes?.[0]?.author?.login || '';
      if (login && !login.includes('bot') && !login.includes('copilot') && !login.startsWith('github-actions')) {
        humanAuthors.add(login);
      }
    }

    return { unresolved, total, severity, humanReviewed: humanAuthors.size > 0 };
  } catch {
    return { unresolved: 0, total: 0, severity: { critical: 0, suggestion: 0, note: 0 }, humanReviewed: false };
  }
}

function derivePrState(pr, detail) {
  pr.mergeable = detail.mergeable || 'UNKNOWN';
  pr.mergeStateStatus = detail.mergeStateStatus || 'UNKNOWN';
  pr.isDraft = !!detail.isDraft;

  // Size
  pr.additions = detail.additions || 0;
  pr.deletions = detail.deletions || 0;
  pr.changedFiles = detail.changedFiles || 0;
  const lines = pr.additions + pr.deletions;
  pr.sizeLabel = lines <= 30 ? 'XS' : lines <= 100 ? 'S' : lines <= 300 ? 'M' : lines <= 800 ? 'L' : 'XL';

  // CI status
  const checks = detail.statusCheckRollup || [];
  if (checks.length === 0) {
    pr.ciStatus = 'none';
  } else if (checks.some(c => ['FAILURE', 'ERROR'].includes(c.conclusion || c.state))) {
    pr.ciStatus = 'failing';
  } else if (checks.some(c => c.state === 'PENDING' || (!c.conclusion && c.state !== 'SUCCESS' && c.conclusion !== 'SUCCESS'))) {
    pr.ciStatus = 'pending';
  } else {
    pr.ciStatus = 'passing';
  }

  // Review state
  const reviews = detail.reviews || [];
  const reviewerSet = new Set();
  for (const r of reviews) {
    if (r.author?.login) reviewerSet.add(r.author.login);
  }
  pr.reviewCount = reviews.length;
  pr.reviewers = [...reviewerSet];

  const reviewRequests = detail.reviewRequests || [];
  pr.requestedReviewers = reviewRequests.map(r => r.login || r.name || '').filter(Boolean);

  pr.reviewDecision = detail.reviewDecision || '';
  if (pr.reviewDecision === 'APPROVED') pr.reviewState = 'approved';
  else if (pr.reviewDecision === 'CHANGES_REQUESTED') pr.reviewState = 'changes';
  else if (reviewRequests.length > 0 || pr.reviewDecision === 'REVIEW_REQUIRED') pr.reviewState = 'pending';
  else if (reviews.length > 0) pr.reviewState = 'pending';
  else pr.reviewState = 'none';

  // Ready: CI passing + mergeable + clean merge state + not draft + reviewed + no unresolved threads
  const reviewed = pr.reviewDecision === 'APPROVED' || (pr.reviewCount > 0 && pr.reviewState !== 'changes');
  const mergeClean = pr.mergeable === 'MERGEABLE' && pr.mergeStateStatus === 'CLEAN';
  pr.isReady = pr.ciStatus === 'passing' && mergeClean
    && reviewed && pr.unresolvedThreads === 0 && !pr.isDraft;
  pr.updatedAt = Date.now();
}

// ---------------------------------------------------------------------------
// Transition Detection
// ---------------------------------------------------------------------------

function detectTransitions(pr) {
  const prev = pr._prev;
  const alerts = [];
  const num = pr.number;

  function alert(level, message) {
    const a = { ts: Date.now(), level, message: `PR ${message}`, prNumber: num };
    alerts.push(a);
    alertLog.push(a);
    if (alertLog.length > MAX_ALERTS) alertLog.shift();
  }

  // PR created
  if (!pr._announced.created) {
    pr._announced.created = true;
    let suffix = '';
    if (pr.mergeable === 'CONFLICTING') { suffix = ', has conflicts'; pr._announced.conflicts = true; }
    else if (pr.ciStatus === 'failing') { suffix = ', CI failing'; pr._announced.ciFail = true; }
    else if (pr.reviewState === 'changes') suffix = ', unresolved comments';
    else if (pr.ciStatus === 'pending') suffix = ', CI pending';
    else if (pr.isReady) { suffix = ', ready to merge'; pr._announced.ready = true; }
    else if (pr.reviewState === 'approved') suffix = ', approved';
    else if (pr.reviewState === 'none' && !pr.isDraft) { suffix = ', no review requested'; pr._announced.noReview = true; }
    else if (['BEHIND', 'BLOCKED', 'DIRTY'].includes(pr.mergeStateStatus)) suffix = ', behind';
    alert('info', `${num} created${suffix}`);
    if (['BEHIND', 'BLOCKED', 'DIRTY'].includes(pr.mergeStateStatus) && pr.mergeable !== 'CONFLICTING' && config.autoUpdate) tryUpdateBranch(num);
    return alerts;
  }

  if (!prev) return alerts;

  // New reviews
  if (pr.reviewCount > prev.reviewCount) {
    const delta = pr.reviewCount - prev.reviewCount;
    const names = pr.reviewers.map(shortName).join(', ');
    const countStr = delta === 1 ? '1 comment' : `${delta} comments`;
    const msg = names ? `${num} new reviews from ${names}, ${countStr}` : `${num} new reviews, ${countStr}`;
    alert('info', msg);
  }

  // No review requested
  if (pr.reviewState === 'none' && !pr.isDraft && !pr._announced.noReview) {
    pr._announced.noReview = true;
    alert('warning', `${num} no review requested`);
  } else if (pr.reviewState !== 'none') {
    pr._announced.noReview = false;
  }

  // Review state transitions
  if (pr.reviewState !== prev.reviewState) {
    if (pr.reviewState === 'pending' && prev.reviewState === 'none') alert('info', `${num} review requested`);
    else if (pr.reviewState === 'approved') alert('success', `${num} review approved`);
    else if (pr.reviewState === 'changes') alert('warning', `${num} changes requested`);
  }

  // Merge conflicts
  if (pr.mergeable === 'CONFLICTING' && prev.mergeable !== 'CONFLICTING' && !pr._announced.conflicts) {
    pr._announced.conflicts = true;
    alert('warning', `${num} has merge conflicts`);
  }
  if (pr.mergeable === 'MERGEABLE' && prev.mergeable === 'CONFLICTING') {
    pr._announced.conflicts = false;
    alert('success', `${num} conflicts resolved`);
  }

  // Behind / blocked — queue for sequential auto-update
  const needsUpdate = ['BEHIND', 'BLOCKED', 'DIRTY'].includes(pr.mergeStateStatus) && pr.mergeable !== 'CONFLICTING';
  if (needsUpdate && config.autoUpdate) {
    enqueueUpdate(num);
  } else {
    dequeueUpdate(num);
  }

  // CI
  if (pr.ciStatus === 'failing' && prev.ciStatus !== 'failing' && !pr._announced.ciFail) {
    pr._announced.ciFail = true;
    alert('error', `${num} CI failing`);
  }
  if (pr.ciStatus === 'passing' && prev.ciStatus === 'failing') {
    pr._announced.ciFail = false;
    alert('success', `${num} CI resolved`);
  }

  // Comments resolved
  if (prev.reviewState === 'changes' && pr.reviewState === 'pending') {
    alert('success', `${num} comments resolved`);
  }

  // Ready to merge
  if (pr.isReady && !prev.isReady && !pr._announced.ready) {
    pr._announced.ready = true;
    alert('success', `${num} ready to merge`);
  }
  if (!pr.isReady) pr._announced.ready = false;

  // "Still" reminders
  const isBehind = ['BEHIND', 'BLOCKED', 'DIRTY'].includes(pr.mergeStateStatus) && pr.mergeable !== 'CONFLICTING';
  const hasIssue = pr.mergeable === 'CONFLICTING' || pr.ciStatus === 'failing' || pr.reviewState === 'changes' || isBehind;
  const issueDesc = pr.mergeable === 'CONFLICTING' ? 'has conflicts'
    : pr.ciStatus === 'failing' ? 'CI failing'
    : pr.reviewState === 'changes' ? 'unresolved comments'
    : isBehind ? 'behind' : '';

  if (hasIssue) {
    if (pr._issueSinceEpoch === 0) { pr._issueSinceEpoch = Date.now(); pr._lastStillEpoch = 0; }
    const issueAge = Date.now() - pr._issueSinceEpoch;
    const sinceLast = Date.now() - (pr._lastStillEpoch || 0);
    if (issueAge >= STILL_THRESHOLD_MS && sinceLast >= STILL_REPEAT_MS) {
      pr._lastStillEpoch = Date.now();
      alert('warning', `${num} still ${issueDesc}`);
    }
  } else {
    pr._issueSinceEpoch = 0;
    pr._lastStillEpoch = 0;
  }

  return alerts;
}

function shortName(login) {
  if (login.startsWith('copilot')) return 'copilot';
  return login.split(/[-_.]/)[0];
}

// ---------------------------------------------------------------------------
// Sequential Branch Update Queue
// ---------------------------------------------------------------------------
// Updates one PR at a time. Waits for CI to pass (CLEAN) before moving on.
// Prevents the cascade where updating all at once puts each other behind again.

const updateQueue = [];       // PR numbers waiting for update
let updateInFlight = null;    // PR number currently being updated/awaiting CI
let updateRetryTimer = null;

function enqueueUpdate(number) {
  if (updateInFlight === number) return;
  if (updateQueue.includes(number)) return;
  updateQueue.push(number);
  processUpdateQueue();
}

function dequeueUpdate(number) {
  const idx = updateQueue.indexOf(number);
  if (idx >= 0) updateQueue.splice(idx, 1);
  if (updateInFlight === number) {
    const pr = prStore.get(number);
    if (pr) pr.isUpdating = false;
    updateInFlight = null;
    broadcastState();
    processUpdateQueue();
  }
}

function processUpdateQueue() {
  if (updateInFlight !== null) return;
  if (updateQueue.length === 0) return;

  const number = updateQueue.shift();

  const pr = prStore.get(number);
  if (!pr || pr.mergeStateStatus === 'CLEAN') {
    if (pr) pr.isUpdating = false;
    processUpdateQueue();
    return;
  }

  updateInFlight = number;
  pr.isUpdating = true;
  broadcastState();
  log(`Updating branch for PR #${number} (${updateQueue.length} queued)...`);

  gh(['pr', 'update-branch', String(number), '-R', config.repo]).then(
    () => {
      log(`PR #${number} branch updated — waiting for CI`);
      const a = { ts: Date.now(), level: 'info', message: `PR ${number} branch updated`, prNumber: number };
      alertLog.push(a); if (alertLog.length > MAX_ALERTS) alertLog.shift();
      broadcastAlert(a);
      scheduleUpdateCheck(number);
    },
    (e) => {
      log(`PR #${number} branch update failed: ${e.message}`);
      if (pr) pr.isUpdating = false;
      updateInFlight = null;
      broadcastState();
      processUpdateQueue();
    }
  );
}

function scheduleUpdateCheck(number) {
  clearTimeout(updateRetryTimer);
  updateRetryTimer = setTimeout(async () => {
    if (updateInFlight !== number) return;
    try {
      await refreshSinglePr(number);
    } catch {}
    const pr = prStore.get(number);
    if (!pr || pr.mergeStateStatus === 'CLEAN') {
      log(`PR #${number} is clean — next in queue`);
      updateInFlight = null;
      processUpdateQueue();
    } else {
      // Still not clean, check again
      scheduleUpdateCheck(number);
    }
  }, 15000);
}

// ---------------------------------------------------------------------------
// Refresh Logic
// ---------------------------------------------------------------------------

const lastRefreshMs = new Map();
const DEBOUNCE_MS = 3000;
let refreshing = false;

async function refreshAllPrs() {
  if (refreshing) return;
  refreshing = true;
  try {
    const list = await fetchPrList();
    const fetchedNumbers = new Set(list.map(p => p.number));

    // Remove closed PRs
    for (const num of prStore.keys()) {
      if (!fetchedNumbers.has(num)) {
        prStore.delete(num);
        log(`PR #${num} closed/merged`);
      }
    }

    // Add/update PRs
    for (const raw of list) {
      if (!prStore.has(raw.number)) {
        prStore.set(raw.number, makePrState(raw));
      } else {
        const pr = prStore.get(raw.number);
        pr.title = raw.title || pr.title;
        pr.branch = raw.headRefName || pr.branch;
        pr.author = raw.author?.login || raw.author || pr.author;
        pr.isDraft = !!raw.isDraft;
        pr.url = raw.url || pr.url;
      }
    }

    // Fetch details for each PR
    const allAlerts = [];
    for (const [num, pr] of prStore) {
      try {
        pr._prev = snapshot(pr);
        const [detail, insights] = await Promise.all([
          fetchPrDetail(num),
          fetchReviewInsights(num),
        ]);
        pr.unresolvedThreads = insights.unresolved;
        pr.totalThreads = insights.total;
        pr.commentSeverity = insights.severity;
        pr.humanReviewed = insights.humanReviewed;
        derivePrState(pr, detail);
        const alerts = detectTransitions(pr);
        allAlerts.push(...alerts);
        lastRefreshMs.set(num, Date.now());
      } catch (e) {
        log(`Failed to refresh PR #${num}: ${e.message}`);
      }
    }

    broadcastState();
    for (const a of allAlerts) broadcastAlert(a);
  } catch (e) {
    log(`Refresh failed: ${e.message}`);
  } finally {
    refreshing = false;
  }
}

async function refreshSinglePr(number) {
  const last = lastRefreshMs.get(number) || 0;
  if (Date.now() - last < DEBOUNCE_MS) return;

  try {
    // If PR not in store, do a full refresh
    if (!prStore.has(number)) {
      return refreshAllPrs();
    }

    const pr = prStore.get(number);
    pr._prev = snapshot(pr);

    const [detail, insights] = await Promise.all([
      fetchPrDetail(number),
      fetchReviewInsights(number),
    ]);
    pr.unresolvedThreads = insights.unresolved;
    pr.totalThreads = insights.total;
    pr.commentSeverity = insights.severity;
    pr.humanReviewed = insights.humanReviewed;
    derivePrState(pr, detail);

    const alerts = detectTransitions(pr);
    lastRefreshMs.set(number, Date.now());

    broadcastState();
    for (const a of alerts) broadcastAlert(a);
  } catch (e) {
    log(`Failed to refresh PR #${number}: ${e.message}`);
  }
}

function snapshot(pr) {
  return {
    mergeable: pr.mergeable,
    mergeStateStatus: pr.mergeStateStatus,
    ciStatus: pr.ciStatus,
    reviewDecision: pr.reviewDecision,
    reviewState: pr.reviewState,
    reviewCount: pr.reviewCount,
    isReady: pr.isReady,
    isUpdating: pr.isUpdating,
  };
}

// ---------------------------------------------------------------------------
// SSE
// ---------------------------------------------------------------------------

const sseClients = new Set();

function addSseClient(res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
  });

  // Send init
  const prs = [...prStore.values()].map(serializePr);
  sendSse(res, 'init', { prs, alerts: alertLog, config: { repo: config.repo, noVoice: config.noVoice }, startedAt });

  sseClients.add(res);
  res.on('close', () => sseClients.delete(res));
}

function sendSse(res, event, data) {
  if (res.writableEnded) return;
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function broadcast(event, data) {
  for (const client of sseClients) {
    sendSse(client, event, data);
  }
}

function broadcastState() {
  const prs = [...prStore.values()].map(serializePr);
  broadcast('state', { prs });
}

function broadcastAlert(alert) {
  broadcast('alert', alert);
}

function serializePr(pr) {
  return {
    number: pr.number,
    title: pr.title,
    author: pr.author,
    branch: pr.branch,
    url: pr.url,
    isDraft: pr.isDraft,
    mergeable: pr.mergeable,
    mergeStateStatus: pr.mergeStateStatus,
    ciStatus: pr.ciStatus,
    reviewDecision: pr.reviewDecision,
    reviewState: pr.reviewState,
    reviewCount: pr.reviewCount,
    reviewers: pr.reviewers,
    unresolvedThreads: pr.unresolvedThreads,
    totalThreads: pr.totalThreads,
    requestedReviewers: pr.requestedReviewers,
    additions: pr.additions,
    deletions: pr.deletions,
    changedFiles: pr.changedFiles,
    sizeLabel: pr.sizeLabel,
    humanReviewed: pr.humanReviewed,
    commentSeverity: pr.commentSeverity,
    isReady: pr.isReady,
    isUpdating: pr.isUpdating,
    updatedAt: pr.updatedAt,
  };
}

// ---------------------------------------------------------------------------
// Webhook Handling
// ---------------------------------------------------------------------------

let webhookProcess = null;
let webhookRestarts = 0;
const MAX_WEBHOOK_RESTARTS = 5;

function startWebhookForwarder() {
  if (config.noWebhook) return;

  const events = 'pull_request,pull_request_review,pull_request_review_comment,check_run,check_suite,status';
  const url = `http://localhost:${config.port}/webhook`;

  webhookProcess = spawn('gh', ['webhook', 'forward', '--repo', config.repo, '--events', events, '--url', url], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  webhookProcess.stdout.on('data', (d) => log(`[webhook] ${d.toString().trim()}`));
  webhookProcess.stderr.on('data', (d) => {
    const msg = d.toString().trim();
    if (msg) log(`[webhook] ${msg}`);
  });

  webhookProcess.on('error', (err) => {
    log(`Webhook forwarder failed to start: ${err.message}`);
    log('Install with: gh extension install cli/gh-webhook');
    log('Falling back to polling only.');
    webhookProcess = null;
  });

  webhookProcess.on('close', (code) => {
    webhookProcess = null;
    if (code !== 0 && code !== null) {
      webhookRestarts++;
      if (webhookRestarts <= MAX_WEBHOOK_RESTARTS) {
        const delay = Math.min(5000 * webhookRestarts, 30000);
        log(`Webhook forwarder exited (code ${code}). Restarting in ${delay / 1000}s... (${webhookRestarts}/${MAX_WEBHOOK_RESTARTS})`);
        setTimeout(startWebhookForwarder, delay);
      } else {
        log('Webhook forwarder exceeded max restarts. Falling back to polling only.');
      }
    }
  });

  log('Webhook forwarder started');
}

function handleWebhookRequest(req, res) {
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    res.writeHead(200);
    res.end('ok');

    const eventType = req.headers['x-github-event'];
    if (!eventType || !body) return;

    let payload;
    try { payload = JSON.parse(body); } catch { return; }

    broadcast('webhook', { event: eventType, action: payload.action || '' });
    routeWebhookEvent(eventType, payload);
  });
}

function routeWebhookEvent(eventType, payload) {
  const action = payload.action || '';

  switch (eventType) {
    case 'pull_request': {
      const prNum = payload.pull_request?.number;
      if (['opened', 'closed', 'reopened'].includes(action)) {
        refreshAllPrs();
      } else if (prNum) {
        refreshSinglePr(prNum);
      }
      break;
    }
    case 'pull_request_review':
    case 'pull_request_review_comment': {
      const prNum = payload.pull_request?.number;
      if (prNum) refreshSinglePr(prNum);
      break;
    }
    case 'check_run': {
      const prs = payload.check_run?.pull_requests || [];
      for (const pr of prs) {
        if (pr.number) refreshSinglePr(pr.number);
      }
      break;
    }
    case 'check_suite': {
      const prs = payload.check_suite?.pull_requests || [];
      for (const pr of prs) {
        if (pr.number) refreshSinglePr(pr.number);
      }
      break;
    }
    case 'status':
      refreshAllPrs();
      break;
  }
}

// ---------------------------------------------------------------------------
// HTTP Server
// ---------------------------------------------------------------------------

const BUILD_VERSION = new Date().toISOString().replace('T', ' ').slice(0, 16);
const indexHtml = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8')
  .replace('__BUILD_VERSION__', BUILD_VERSION);

function requestHandler(req, res) {
  const url = req.url?.split('?')[0];

  if (req.method === 'GET' && url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(indexHtml);
    return;
  }

  if (req.method === 'GET' && url === '/events') {
    addSseClient(res);
    return;
  }

  if (req.method === 'POST' && url === '/webhook') {
    handleWebhookRequest(req, res);
    return;
  }

  if (req.method === 'GET' && url === '/api/state') {
    const prs = [...prStore.values()].map(serializePr);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ prs, alerts: alertLog, config: { repo: config.repo, noVoice: config.noVoice } }));
    return;
  }

  if (req.method === 'POST' && url === '/api/refresh') {
    refreshAllPrs();
    res.writeHead(200);
    res.end('ok');
    return;
  }

  // POST /api/merge/:number — squash merge a PR
  const mergeMatch = req.method === 'POST' && url.match(/^\/api\/merge\/(\d+)$/);
  if (mergeMatch) {
    const prNumber = mergeMatch[1];
    handleMerge(prNumber, res);
    return;
  }

  // POST /api/update/:number — update branch
  const updateMatch = req.method === 'POST' && url.match(/^\/api\/update\/(\d+)$/);
  if (updateMatch) {
    const prNumber = Number(updateMatch[1]);
    enqueueUpdate(prNumber);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, queued: true }));
    return;
  }

  res.writeHead(404);
  res.end('Not found');
}

async function handleMerge(prNumber, res) {
  try {
    log(`Merging PR #${prNumber} (squash)...`);
    await gh(['pr', 'merge', String(prNumber), '-R', config.repo, '--squash', '--delete-branch']);
    log(`PR #${prNumber} merged successfully`);
    const alert = { ts: Date.now(), level: 'success', message: `${prNumber} merged`, prNumber: Number(prNumber) };
    alertLog.push(alert);
    if (alertLog.length > MAX_ALERTS) alertLog.shift();
    broadcastAlert(alert);
    // Refresh to remove merged PR
    setTimeout(() => refreshAllPrs(), 1000);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true }));
  } catch (e) {
    log(`Merge failed for PR #${prNumber}: ${e.message}`);
    const alert = { ts: Date.now(), level: 'error', message: `${prNumber} merge failed: ${e.message}`, prNumber: Number(prNumber) };
    alertLog.push(alert);
    if (alertLog.length > MAX_ALERTS) alertLog.shift();
    broadcastAlert(alert);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: false, error: e.message }));
  }
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

function log(msg) {
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
  console.log(`[${ts}] ${msg}`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

let startedAt = Date.now();
let pollTimer = null;
let heartbeatTimer = null;

async function main() {
  parseArgs(process.argv);

  if (!config.repo) {
    try {
      config.repo = await detectRepoFromGit();
      log(`Detected repo: ${config.repo}`);
    } catch {
      console.error('Error: --repo required (could not detect from git remote)');
      process.exit(1);
    }
  }

  await checkPrereqs();

  const server = http.createServer(requestHandler);
  server.listen(config.port, () => {
    log(`PR Monitor for ${config.repo}`);
    log(`Dashboard: http://localhost:${config.port}`);
    if (config.author) log(`Author filter: ${config.author}`);
    if (config.branch) log(`Branch filter: ${config.branch}`);
  });

  startedAt = Date.now();

  // Initial fetch
  log('Fetching initial PR state...');
  await refreshAllPrs();
  log(`Tracking ${prStore.size} open PRs`);

  // Poll fallback
  pollTimer = setInterval(() => refreshAllPrs(), config.interval * 1000);

  // Heartbeat
  heartbeatTimer = setInterval(() => broadcast('heartbeat', { ts: Date.now() }), 30000);

  // Webhook forwarder
  startWebhookForwarder();

  // Graceful shutdown
  function shutdown() {
    log('Shutting down...');
    if (webhookProcess) {
      webhookProcess.kill('SIGTERM');
      setTimeout(() => { if (webhookProcess) webhookProcess.kill('SIGKILL'); }, 2000);
    }
    clearInterval(pollTimer);
    clearInterval(heartbeatTimer);
    broadcast('shutdown', {});
    for (const client of sseClients) { client.end(); }
    server.close();
    setTimeout(() => process.exit(0), 500);
  }

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main().catch((e) => {
  console.error(`Fatal: ${e.message}`);
  process.exit(1);
});
