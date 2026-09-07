#!/usr/bin/env bash
# Tear down the demo. Two modes:
#
#   down.sh          SOFT (default): helm-uninstall Kestra, remove the scaler, stop
#                    the trigger app and the port-forwards — but KEEP the kind
#                    cluster and its warm image cache (~4 GB) and PVCs. The next
#                    `make up` reinstalls in ~1 min with no image re-pull.
#
#   down.sh hard     Also `kind delete cluster` — a full clean slate. The next
#                    `make up` recreates the node with an empty image store and
#                    re-pulls the EE image (10-30 min on a cold node, unless
#                    Docker Desktop's containerd image store is disabled so
#                    `kind load` works — see SETUP.md).
source "$(dirname "$0")/lib.sh"
load_env

MODE="${1:-soft}"
[[ "$MODE" == soft || "$MODE" == hard ]] || die "usage: down.sh [soft|hard]"

log "stopping trigger app"
docker compose -f "$ROOT/app/docker-compose.yml" --env-file "$ROOT/.env" down -v 2>/dev/null || true

log "removing Workstream 1 scaler"
# Named resources rather than `-f k8s/` (those files carry a {{NAMESPACE}} placeholder).
kctl delete deploy/worker-scaler cm/worker-scaler-config sa/worker-scaler \
  role/worker-scaler rolebinding/worker-scaler --ignore-not-found 2>/dev/null || true

"$HERE/portforward.sh" stop || true          # kill the background kubectl tunnels

if [[ "$MODE" == hard ]]; then
  if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    log "deleting kind cluster '$KIND_CLUSTER_NAME' (full clean slate)"
    kind delete cluster --name "$KIND_CLUSTER_NAME"
  fi
  rm -f "$STATE_DIR"/*.pid "$STATE_DIR"/values.rendered.yaml "$STATE_DIR"/metric-names.env
  ok "torn down (hard) — next 'make up' recreates the cluster and re-pulls images"
else
  if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    log "helm uninstall '$HELM_RELEASE' (keeping the kind cluster + warm image cache)"
    helm --kube-context "$KCTX" -n "$K8S_NAMESPACE" uninstall "$HELM_RELEASE" 2>/dev/null || true
  fi
  # Leave the namespace, the kestra-registry pull secret, and the postgres PVC in
  # place — a soft `make up` reuses them (DB is already migrated => faster start).
  rm -f "$STATE_DIR"/*.pid "$STATE_DIR"/values.rendered.yaml
  ok "torn down (soft) — kind cluster kept; 'make up' reinstalls fast (no image re-pull)"
  warn "for a full clean slate incl. the DB volume: make down-hard"
fi
