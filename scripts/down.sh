#!/usr/bin/env bash
# Tear everything down.
source "$(dirname "$0")/lib.sh"
load_env

log "stopping trigger app"
docker compose -f "$ROOT/app/docker-compose.yml" --env-file "$ROOT/.env" down -v 2>/dev/null || true

log "removing Workstream 1 scaler"
kctl delete -f "$ROOT/workstream-1-prometheus-worker-scaling/k8s/" --ignore-not-found 2>/dev/null || true

"$HERE/portforward.sh" stop || true

if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
  log "deleting kind cluster '$KIND_CLUSTER_NAME'"
  kind delete cluster --name "$KIND_CLUSTER_NAME"
fi

rm -f "$STATE_DIR"/*.pid "$STATE_DIR"/values.rendered.yaml
ok "torn down"
