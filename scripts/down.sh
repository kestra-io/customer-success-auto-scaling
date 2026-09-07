#!/usr/bin/env bash
# Tear everything down: trigger app, scaler, port-forwards, kind cluster.
# Deleting the cluster is what makes this fully clean (and sidesteps the
# Helm-vs-scaler .spec.replicas field-manager conflict on the next `make up`).
source "$(dirname "$0")/lib.sh"
load_env

log "stopping trigger app"
# -v also drops the compose network/volumes. `|| true`: fine if it was never up.
docker compose -f "$ROOT/app/docker-compose.yml" --env-file "$ROOT/.env" down -v 2>/dev/null || true

log "removing Workstream 1 scaler"
# Cosmetic — `kind delete cluster` below removes it anyway; this just makes a
# scaler-only teardown possible. --ignore-not-found so a partial deploy is fine.
kctl delete -f "$ROOT/workstream-1-prometheus-worker-scaling/k8s/" --ignore-not-found 2>/dev/null || true

"$HERE/portforward.sh" stop || true          # kill the background kubectl tunnels

if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
  log "deleting kind cluster '$KIND_CLUSTER_NAME'"
  kind delete cluster --name "$KIND_CLUSTER_NAME"
fi

rm -f "$STATE_DIR"/*.pid "$STATE_DIR"/values.rendered.yaml   # leave logs/scrapes for post-mortem
ok "torn down"
