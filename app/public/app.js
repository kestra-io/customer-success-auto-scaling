'use strict';
const $ = (id) => document.getElementById(id);

const rate = $('rate');
const rateVal = $('rate-val');
const presetHint = $('preset-hint');
let presets = { baseline: 8, spike: 24, drop: 2 };

async function j(url, opts) {
  const r = await fetch(url, opts);
  if (!r.ok) throw new Error(`${url} -> ${r.status}`);
  return r.json();
}

async function loadConfig() {
  try {
    const c = await j('/api/config');
    presets = c.presets || presets;
    rate.max = String(c.rate_max ?? 30);
    rate.value = String(c.rate_per_min ?? presets.baseline);
    rateVal.textContent = rate.value;
    $('flow-name').textContent = `${c.namespace}.${c.flow}`;
    markActivePreset(Number(rate.value));
  } catch (e) {
    presetHint.textContent = `config error: ${e.message}`;
  }
}

function markActivePreset(v) {
  document.querySelectorAll('button[data-preset]').forEach((b) => {
    b.classList.toggle('active', presets[b.dataset.preset] === v);
  });
}

let putTimer = null;
rate.addEventListener('input', () => {
  rateVal.textContent = rate.value;
  markActivePreset(Number(rate.value));
  clearTimeout(putTimer);
  putTimer = setTimeout(async () => {
    try { await j('/api/rate', { method: 'PUT', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ perMin: Number(rate.value) }) }); }
    catch (e) { presetHint.textContent = e.message; }
  }, 200);
});

document.querySelectorAll('button[data-preset]').forEach((b) => {
  b.addEventListener('click', async () => {
    try {
      const res = await j('/api/preset', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name: b.dataset.preset }) });
      rate.value = String(res.rate_per_min);
      rateVal.textContent = rate.value;
      markActivePreset(res.rate_per_min);
      const notes = {
        baseline: 'Tuned for ~50% of one 4-thread worker. Queue stays empty.',
        spike: 'Well past one worker’s capacity — pending climbs, then Workstream 1 adds a worker.',
        drop: 'Near idle — Workstream 1 scales the worker back down.',
      };
      presetHint.textContent = notes[b.dataset.preset] || '';
    } catch (e) { presetHint.textContent = e.message; }
  });
});

function fmt(v, d = 0) { return v == null ? '–' : Number(v).toFixed(d); }

// ── refresh cue ──────────────────────────────────────────────────────────────
// Flash the dot on every successful poll, and keep an "updated Ns ago" readout
// ticking between polls so a stalled backend is obvious (age keeps climbing).
let lastOkTs = 0;
const SRC_LABEL = { scaler: 'scaler (all workers)', 'worker-metrics': 'one worker pod' };

function pulse() {
  const d = $('pulse');
  d.classList.remove('beat');
  void d.offsetWidth;          // restart the CSS animation
  d.classList.add('beat');
}

function renderAge() {
  const el = $('refresh-age');
  if (!lastOkTs) return;
  const secs = Math.round((Date.now() - lastOkTs) / 1000);
  el.textContent = secs <= 1 ? 'updated just now' : `updated ${secs}s ago`;
  el.classList.toggle('stale', secs > 8);   // > 4 missed polls
}

async function tick() {
  try {
    const s = await j('/api/stats');
    const cap = s.concurrent_capacity || 1;
    const runningPct = Math.min(100, (100 * (s.running || 0)) / cap);
    const pendingPct = Math.min(100 - runningPct, (100 * (s.pending || 0)) / cap);
    $('bar-running').style.width = runningPct + '%';
    $('bar-pending').style.width = pendingPct + '%';
    $('cap').textContent = cap;
    $('s-running').textContent = fmt(s.running);
    $('s-pending').textContent = fmt(s.pending);
    $('s-replicas').textContent = fmt(s.worker_replicas);
    $('s-threads').textContent = fmt(s.threads_per_worker);
    $('s-util').textContent = s.utilization == null ? '–' : Math.round(s.utilization * 100) + '%';
    $('s-fired').textContent = fmt(s.fired_total);
    document.querySelector('.stats').classList.toggle('over', (s.pending || 0) > 0 || (s.running || 0) >= cap);
    $('scrape-err').textContent = s.scrape_error ? `metrics: ${s.scrape_error}` : '';

    const badge = $('src-badge');
    badge.textContent = `source: ${SRC_LABEL[s.source] || s.source || '–'}`;
    badge.classList.toggle('fallback', s.source !== 'scaler');
    badge.title = s.source === 'scaler'
      ? 'Authoritative: summed across every worker pod, real Deployment replica count.'
      : 'Fallback scrape of a single worker pod — replica count and totals may be low during a spike. Run `make scaler`.';

    lastOkTs = Date.now();
    pulse();
    renderAge();
  } catch (e) {
    $('scrape-err').textContent = e.message;
    renderAge();               // keep the age climbing so a stall is visible
  }
}

loadConfig();
tick();
setInterval(tick, 2000);
setInterval(renderAge, 1000);
