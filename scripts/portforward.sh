#!/usr/bin/env bash
# Manage two background `kubectl port-forward` tunnels on 127.0.0.1:
#   8080 -> webserver http   (Kestra API + UI)          via svc/<webserver>
#   8081 -> webserver mgmt   (webserver /prometheus)    via svc/<webserver>
#   8082 -> worker  mgmt     (kestra_worker_job_*)       via svc/kestra-worker-metrics
#
#   portforward.sh start | stop | status
#
# `kubectl port-forward svc/X` pins to ONE endpoint pod; if that pod is replaced
# the tunnel dies. Re-run `start` to re-establish (idempotent).
source "$(dirname "$0")/lib.sh"
load_env

WS_PID="$STATE_DIR/portforward-ws.pid"    # webserver tunnel pid
WK_PID="$STATE_DIR/portforward-wk.pid"    # worker-metrics tunnel pid

# true if the pid file exists and that process is alive.
_running() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

# Start one port-forward in the background, record its pid, wait until reachable.
#   _pf <pidfile> <logname> <target> <check-url> <portmap> [<portmap>...]
_pf() {
  local pidfile="$1" logname="$2" target="$3" check="$4"; shift 4   # remaining args = port maps
  if _running "$pidfile"; then ok "port-forward $target already running (pid $(cat "$pidfile"))"; return; fi
  log "port-forward $target  $*"
  nohup kubectl --context "$KCTX" -n "$K8S_NAMESPACE" port-forward --address 127.0.0.1 \
    "$target" "$@" >"$STATE_DIR/${logname}.log" 2>&1 &
  echo $! > "$pidfile"                       # $! = pid of the backgrounded kubectl
  wait_for "port-forward $target" 60 bash -c "curl -fsS -o /dev/null '$check'"
}

start() {
  local ws; ws="$(kestra_webserver_svc)"; [[ -n "$ws" ]] || die "webserver service not found"
  _pf "$WS_PID" portforward-ws "svc/$ws" "${KESTRA_HTTP}/ping" 8080:8080 8081:8081

  # The worker-metrics Service is created by helm/values.yaml; if it's missing the
  # chart hasn't been applied yet (run `make up`).
  if kctl get svc kestra-worker-metrics >/dev/null 2>&1; then
    _pf "$WK_PID" portforward-wk "svc/kestra-worker-metrics" "http://127.0.0.1:8082/prometheus" 8082:8081
  else
    warn "svc/kestra-worker-metrics not found — run 'helm upgrade' (via make up); worker metrics on :8082 unavailable"
  fi
  ok "port-forwards up. If one drops mid-demo, re-run: scripts/portforward.sh start"
}

stop() {
  for f in "$WS_PID" "$WK_PID"; do
    [[ -f "$f" ]] || continue
    kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
  done
  ok "port-forwards stopped"
}

status() {
  _running "$WS_PID" && ok "webserver forward running (pid $(cat "$WS_PID"))" || warn "webserver forward not running"
  _running "$WK_PID" && ok "worker-metrics forward running (pid $(cat "$WK_PID"))" || warn "worker-metrics forward not running"
}

case "${1:-status}" in
  start) start ;;
  stop)  stop ;;
  status) status ;;
  *) die "usage: portforward.sh start|stop|status" ;;
esac
