#!/usr/bin/env bash
# Manage a background kubectl port-forward for Kestra 8080/8081 on 127.0.0.1.
#   portforward.sh start | stop | status
source "$(dirname "$0")/lib.sh"
load_env

PID_FILE="$STATE_DIR/portforward.pid"

svc_name() {
  # The webserver service carries component=webserver and exposes 8080 + 8081.
  local s
  s="$(kestra_webserver_svc)"
  [[ -n "$s" ]] && { echo "$s"; return; }
  for s in "$HELM_RELEASE" "${HELM_RELEASE}-kestra" "${HELM_RELEASE}-webserver" "${HELM_RELEASE}-kestra-webserver"; do
    kctl get "svc/$s" >/dev/null 2>&1 && { echo "$s"; return; }
  done
}

start() {
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    ok "port-forward already running (pid $(cat "$PID_FILE"))"; return
  fi
  local svc; svc="$(svc_name)"
  [[ -n "$svc" ]] || die "could not find the Kestra service"
  log "port-forward svc/$svc  8080->8080  8081->8081"
  nohup kubectl --context "$KCTX" -n "$K8S_NAMESPACE" port-forward \
    --address 127.0.0.1 "svc/$svc" 8080:8080 8081:8081 \
    >"$STATE_DIR/portforward.log" 2>&1 &
  echo $! > "$PID_FILE"
  wait_for "port-forward :8080" 60 bash -c "curl -fsS -o /dev/null '${KESTRA_HTTP}/ping' || curl -fsS -o /dev/null '$(api "/flows/search?size=1")'"
  ok "port-forward up (pid $(cat "$PID_FILE")). If it drops mid-demo, re-run: scripts/portforward.sh start"
}

stop() {
  [[ -f "$PID_FILE" ]] || { ok "no port-forward pid file"; return; }
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
  rm -f "$PID_FILE"
  ok "port-forward stopped"
}

status() {
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    ok "running (pid $(cat "$PID_FILE"))"
  else
    warn "not running"
  fi
}

case "${1:-status}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  *) die "usage: portforward.sh start|stop|status" ;;
esac
