#!/usr/bin/env bash
# Scrape a worker's /prometheus, confirm the three queue gauges exist, and pin
# their EXACT names into .state/metric-names.env — which deploy-scaler.sh and the
# trigger app then read. This makes the demo survive a Kestra build that renames
# the metrics (defaults assume EE 1.3.24: kestra_worker_job_pending/_running/_thread).
#
# In EE these gauges live ONLY on each worker pod's :8081 — never the webserver.
source "$(dirname "$0")/lib.sh"
load_env

PROM="$STATE_DIR/prometheus-worker.txt"
log "scraping ${KESTRA_WORKER_MGMT}/prometheus (worker metrics)"
# Preferred path: the :8082 port-forward to svc/kestra-worker-metrics.
if ! curl -fsS "${KESTRA_WORKER_MGMT}/prometheus" -o "$PROM"; then
  # Fallback if the port-forward isn't up: exec into a worker pod and curl locally.
  warn "port-forward :8082 not up — trying a worker pod directly via kubectl exec"
  wp="$(kctl get pod -l app.kubernetes.io/component=worker -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$wp" ]] || die "no worker pod found"
  kctl exec "$wp" -- sh -c 'curl -s http://localhost:8081/prometheus' > "$PROM" || die "could not scrape worker $wp"
fi

# Return <preferred> if it's present as a series; else the first kestra_worker_*
# series containing <substr>; else <preferred> unchanged.
pick() {  # pick <preferred> <substr>
  local pref="$1" rx="$2" hit
  if grep -qE "^${pref}(\{|[[:space:]])" "$PROM"; then echo "$pref"; return; fi
  hit="$(grep -oE "^kestra_worker_[a-z_]*${rx}[a-z_]*" "$PROM" | head -1 || true)"
  echo "${hit:-$pref}"
}

M_PENDING="$(pick "${METRIC_PENDING:-kestra_worker_job_pending}" 'pending')"
M_RUNNING="$(pick "${METRIC_RUNNING:-kestra_worker_job_running}" 'running')"
M_THREADS="$(pick "${METRIC_THREADS:-kestra_worker_job_thread}"  'thread')"

{
  echo "# written by verify-metrics.sh $(date -u +%FT%TZ)"
  echo "METRIC_PENDING=${M_PENDING}"
  echo "METRIC_RUNNING=${M_RUNNING}"
  echo "METRIC_THREADS=${M_THREADS}"
} > "$STATE_DIR/metric-names.env"

echo
# Confirm all three resolved names are actually present as series.
if grep -E "^(${M_PENDING}|${M_RUNNING}|${M_THREADS})(\{|[[:space:]])" "$PROM"; then
  echo
  ok "metric names pinned -> $STATE_DIR/metric-names.env"
  cat "$STATE_DIR/metric-names.env"
else
  # Common cause: the worker hasn't run a task yet so the gauges aren't emitted.
  warn "expected worker metrics not found. Present kestra_worker_* series:"
  grep -oE '^kestra_worker_[a-z_]+' "$PROM" | sort -u | sed 's/^/  /' | head -30
  exit 1
fi
