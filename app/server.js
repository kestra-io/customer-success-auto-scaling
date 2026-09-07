'use strict';
// Trigger app for the Kestra auto-scaling example.
// One process: serves the static UI, runs a server-side webhook trigger loop at a
// controllable rate, and exposes /api/stats by scraping Kestra's Prometheus endpoint.
// No dependencies — Node 20 built-ins only (http, fs, global fetch).

const http = require('http');
const fs = require('fs');
const path = require('path');

const env = process.env;
const CFG = {
  kestraBase: (env.KESTRA_BASE_URL || 'http://host.docker.internal:8080').replace(/\/$/, ''),
  kestraMgmt: (env.KESTRA_MGMT_URL || 'http://host.docker.internal:8082').replace(/\/$/, ''),
  // Authoritative source: the scaler sums kestra_worker_job_* across EVERY worker
  // pod and reads the real Deployment replica count. Preferred over kestraMgmt,
  // whose port-forward pins to ONE worker pod so it can never see the count change.
  // Empty = not wired up (compose quickstart, or `make scaler` not run yet).
  scalerState: (env.SCALER_STATE_URL || '').replace(/\/$/, ''),
  tenant: env.KESTRA_TENANT || 'main',
  ns: env.FLOW_NAMESPACE || 'company.autoscaling',
  flow: env.FLOW_ID || 'webhook_sleep',
  key: env.WEBHOOK_KEY || 'demo-key',
  threadsPerWorker: intOr(env.WORKER_THREADS, 4),
  metricPending: env.METRIC_PENDING || 'kestra_worker_job_pending',
  metricRunning: env.METRIC_RUNNING || 'kestra_worker_job_running',
  metricThreads: env.METRIC_THREADS || 'kestra_worker_job_thread',
  rates: {
    baseline: numOr(env.RATE_BASELINE, 8),
    spike: numOr(env.RATE_SPIKE, 24),
    drop: numOr(env.RATE_DROP, 2),
  },
  rateMax: numOr(env.RATE_MAX, 30),
  port: intOr(env.APP_PORT, 5173),
};

function intOr(v, d) { const n = parseInt(v, 10); return Number.isFinite(n) ? n : d; }
function numOr(v, d) { const n = parseFloat(v); return Number.isFinite(n) ? n : d; }

const webhookUrl = () =>
  `${CFG.kestraBase}/api/v1/${CFG.tenant}/executions/webhook/${CFG.ns}/${CFG.flow}/${CFG.key}`;

// ── trigger loop ─────────────────────────────────────────────────────────────
const state = { ratePerMin: CFG.rates.baseline, firedTotal: 0, errorTotal: 0, lastFireTs: 0 };
let loopTimer = null;

function scheduleNext() {
  if (loopTimer) clearTimeout(loopTimer);
  const r = state.ratePerMin;
  if (r <= 0) { loopTimer = setTimeout(scheduleNext, 1000); return; }
  const delayMs = Math.max(50, Math.round(60000 / r));
  loopTimer = setTimeout(fireAndReschedule, delayMs);
}

async function fireAndReschedule() {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 5000);
    const res = await fetch(webhookUrl(), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}',
      signal: ctrl.signal,
    });
    clearTimeout(t);
    if (res.ok) { state.firedTotal++; state.lastFireTs = Date.now(); }
    else state.errorTotal++;
  } catch {
    state.errorTotal++;
  }
  scheduleNext();
}
scheduleNext();

// ── prometheus scrape ───────────────────────────────────────────────────────
function sumMetric(text, name) {
  // matches:  name  value   |   name{labels}  value
  const re = new RegExp(`^${name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\$&')}(\\{[^}]*\\})?\\s+([-+eE0-9.]+|NaN)\\s*$`, 'gm');
  let m, sum = 0, seen = false;
  while ((m = re.exec(text)) !== null) {
    const v = parseFloat(m[2]);
    if (Number.isFinite(v)) { sum += v; seen = true; }
  }
  return seen ? sum : null;
}

// The always-present half of /api/stats: the trigger-loop counters.
function loopStats() {
  return {
    rate_per_min: state.ratePerMin,
    fired_total: state.firedTotal,
    error_total: state.errorTotal,
  };
}

// Preferred path: the scaler's /state — one JSON blob with the cross-pod sums and
// the true replica count already computed. Returns null (and lets getStats fall
// back to the scrape) on any error or before the scaler's first tick (503).
async function fetchScalerState() {
  if (!CFG.scalerState) return null;
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 4000);
    const res = await fetch(`${CFG.scalerState}`, { signal: ctrl.signal });
    clearTimeout(t);
    if (!res.ok) return null;                      // 503 until first tick
    const d = await res.json();
    if (d == null || typeof d.worker_replicas !== 'number') return null;
    return {
      ts: new Date().toISOString(),
      source: 'scaler',
      pending: d.pending ?? null,
      running: d.running ?? null,
      threads_total: (d.worker_replicas ?? 0) * (d.threads_per_worker ?? CFG.threadsPerWorker),
      worker_replicas: d.worker_replicas,
      threads_per_worker: d.threads_per_worker ?? CFG.threadsPerWorker,
      concurrent_capacity: d.concurrent_capacity ?? d.worker_replicas * CFG.threadsPerWorker,
      utilization: d.utilization ?? null,
      decision: d.decision ?? null,
      state_age_s: d.ts ? +(Date.now() / 1000 - d.ts).toFixed(1) : null,
      scrape_error: null,
    };
  } catch {
    return null;
  }
}

// Fallback path: scrape one worker pod's /prometheus (via the :8082 port-forward).
// Correct at 1 replica; during a spike it undercounts and worker_replicas is
// stuck at 1 (the port-forward only ever hits one pod) — hence the scaler path.
async function scrapeStats() {
  let pending = null, running = null, threads = null, err = null;
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 4000);
    const res = await fetch(`${CFG.kestraMgmt}/prometheus`, { signal: ctrl.signal });
    clearTimeout(t);
    if (!res.ok) throw new Error(`prometheus HTTP ${res.status}`);
    const body = await res.text();
    pending = sumMetric(body, CFG.metricPending);
    running = sumMetric(body, CFG.metricRunning);
    threads = sumMetric(body, CFG.metricThreads);
  } catch (e) {
    err = String(e.message || e);
  }
  const workerReplicas =
    threads && CFG.threadsPerWorker ? Math.max(1, Math.round(threads / CFG.threadsPerWorker)) : 1;
  const capacity = workerReplicas * CFG.threadsPerWorker;
  return {
    ts: new Date().toISOString(),
    source: 'worker-metrics',
    pending,
    running,
    threads_total: threads,
    worker_replicas: workerReplicas,
    threads_per_worker: CFG.threadsPerWorker,
    concurrent_capacity: capacity,
    utilization: running != null ? +(running / capacity).toFixed(3) : null,
    decision: null,
    state_age_s: null,
    scrape_error: err,
  };
}

async function getStats() {
  const core = (await fetchScalerState()) || (await scrapeStats());
  return { ...core, ...loopStats() };
}

// ── http ────────────────────────────────────────────────────────────────────
const PUBLIC = path.join(__dirname, 'public');
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };

function send(res, code, body, type = 'application/json') {
  const payload = type === 'application/json' ? JSON.stringify(body) : body;
  res.writeHead(code, { 'content-type': type });
  res.end(payload);
}

async function readJson(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return {}; }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;

  try {
    if (p === '/api/health') return send(res, 200, { ok: true, webhook: webhookUrl(), kestra: CFG.kestraBase });

    if (p === '/api/config') {
      return send(res, 200, {
        webhook_url: webhookUrl(),
        namespace: CFG.ns, flow: CFG.flow,
        rate_per_min: state.ratePerMin,
        rate_max: CFG.rateMax,
        presets: CFG.rates,
        threads_per_worker: CFG.threadsPerWorker,
      });
    }

    if (p === '/api/stats') return send(res, 200, await getStats());

    if (p === '/api/rate' && req.method === 'PUT') {
      const { perMin } = await readJson(req);
      const r = Math.min(CFG.rateMax, Math.max(0, Number(perMin) || 0));
      state.ratePerMin = r;
      scheduleNext();
      return send(res, 200, { rate_per_min: r });
    }

    if (p === '/api/preset' && req.method === 'POST') {
      const { name } = await readJson(req);
      if (!(name in CFG.rates)) return send(res, 400, { error: `unknown preset '${name}'` });
      state.ratePerMin = CFG.rates[name];
      scheduleNext();
      return send(res, 200, { preset: name, rate_per_min: state.ratePerMin });
    }

    // static
    let file = p === '/' ? '/index.html' : p;
    const full = path.join(PUBLIC, path.normalize(file));
    if (!full.startsWith(PUBLIC) || !fs.existsSync(full)) return send(res, 404, 'not found', 'text/plain');
    return send(res, 200, fs.readFileSync(full), MIME[path.extname(full)] || 'application/octet-stream');
  } catch (e) {
    return send(res, 500, { error: String(e.message || e) });
  }
});

server.listen(CFG.port, () => {
  console.log(`[trigger-app] listening on :${CFG.port}`);
  console.log(`[trigger-app] webhook  -> ${webhookUrl()}`);
  console.log(`[trigger-app] stats    <- ${CFG.scalerState ? `${CFG.scalerState} (scaler, preferred)` : '(scaler /state not configured)'}`);
  console.log(`[trigger-app] fallback <- ${CFG.kestraMgmt}/prometheus`);
  console.log(`[trigger-app] rates    -> baseline=${CFG.rates.baseline} spike=${CFG.rates.spike} drop=${CFG.rates.drop} (per min)`);
});
