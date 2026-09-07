#!/usr/bin/env bash
# Curl :8081/prometheus, confirm the worker queue metrics exist, and record their
# exact names in .state/metric-names.env for the app + scaler to consume.
#
# On v1.3.24 the expected names are kestra_worker_job_pending / _running / _thread.
# A future rename (seen on `develop`) would be kestra_worker_pending_count etc.
source "$(dirname "$0")/lib.sh"
load_env

PROM="$STATE_DIR/prometheus.txt"
log "scraping ${KESTRA_MGMT}/prometheus"
curl -fsS "${KESTRA_MGMT}/prometheus" -o "$PROM" || die "could not reach ${KESTRA_MGMT}/prometheus (port-forward up? basic auth off?)"

pick() {  # pick <preferred> <fallback-regex>
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
grep -E "^(${M_PENDING}|${M_RUNNING}|${M_THREADS})(\{|[[:space:]])" "$PROM" || {
  warn "none of the expected worker metrics are present yet."
  warn "run at least one execution, wait ~30s (webserver re-aggregates on a 30s timer), and retry."
  grep -E '^kestra_worker_' "$PROM" | sed 's/^/  seen: /' | head -30 || true
  exit 1
}
echo
ok "metric names pinned -> $STATE_DIR/metric-names.env"
cat "$STATE_DIR/metric-names.env"
