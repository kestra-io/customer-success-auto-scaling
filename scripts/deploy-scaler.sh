#!/usr/bin/env bash
# Build the scaler image, load it into the kind node, apply RBAC, render the
# config ConfigMap from .env + .state/metric-names.env, and deploy it. (= `make scaler`)
source "$(dirname "$0")/lib.sh"
load_env

WS1="$ROOT/workstream-1-prometheus-worker-scaling"
IMAGE="kestra-autoscaling/worker-scaler:local"     # local tag; never pushed, always `kind load`ed

# Prefer the metric names pinned by verify-metrics.sh; fall back to .env defaults.
[[ -f "$STATE_DIR/metric-names.env" ]] && { set -a; source "$STATE_DIR/metric-names.env"; set +a; }

WORKER_DEPLOYMENT_NAME="$(kestra_deploy worker)"
[[ -n "$WORKER_DEPLOYMENT_NAME" ]] || die "could not find the worker deployment by label"
# The scaler discovers worker pods by this selector and scrapes each pod's :8081
# directly (PROMETHEUS_URL left empty on the ConfigMap = discovery mode).
WORKER_SELECTOR="app.kubernetes.io/name=kestra,app.kubernetes.io/component=worker"
log "worker deployment: ${WORKER_DEPLOYMENT_NAME}   scrape: pods matching '${WORKER_SELECTOR}' :8081"

log "build $IMAGE"
docker build -t "$IMAGE" "$WS1"
log "kind load $IMAGE"
kind load docker-image "$IMAGE" --name "$KIND_CLUSTER_NAME"   # copy into the node's containerd

log "apply RBAC"
# The k8s manifests carry a {{NAMESPACE}} placeholder (kubectl -n can't set
# metadata.namespace or a RoleBinding subject namespace).
for m in serviceaccount role rolebinding; do
  sed "s/{{NAMESPACE}}/${K8S_NAMESPACE}/g" "$WS1/k8s/${m}.yaml" | kctl apply -f -
done

log "verify the ServiceAccount can scale the worker Deployment"
# --subresource=scale is the modern syntax; `deployments/scale` (slash) doesn't
# parse in `auth can-i` on newer kubectl even when the Role grants it.
if kctl auth can-i patch deployments --subresource=scale \
     --as="system:serviceaccount:${K8S_NAMESPACE}:worker-scaler" >/dev/null; then
  ok "RBAC ok (can patch deployments/scale)"
else
  warn "RBAC check returned non-yes — the scaler may not be able to patch deployments/scale"
fi

log "render + apply scaler config"
# Every knob the scaler reads (scaler/config.py). dry-run|apply so re-running
# `make scaler` just updates the ConfigMap. ${VAR:-default} mirrors config.py's
# defaults so an unset .env var still produces a sane value.
kctl create configmap worker-scaler-config \
  --from-literal=PROMETHEUS_URL="" \
  --from-literal=WORKER_LABEL_SELECTOR="$WORKER_SELECTOR" \
  --from-literal=WORKER_METRICS_PORT="8081" \
  --from-literal=METRIC_PENDING="${METRIC_PENDING:-kestra_worker_job_pending}" \
  --from-literal=METRIC_RUNNING="${METRIC_RUNNING:-kestra_worker_job_running}" \
  --from-literal=METRIC_THREADS="${METRIC_THREADS:-kestra_worker_job_thread}" \
  --from-literal=NAMESPACE="$K8S_NAMESPACE" \
  --from-literal=WORKER_DEPLOYMENT_NAME="$WORKER_DEPLOYMENT_NAME" \
  --from-literal=THREADS_PER_WORKER="${WORKER_THREADS}" \
  --from-literal=POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-15}" \
  --from-literal=SCALE_UP_WINDOW_SECONDS="${SCALE_UP_WINDOW_SECONDS:-60}" \
  --from-literal=SCALE_DOWN_WINDOW_SECONDS="${SCALE_DOWN_WINDOW_SECONDS:-180}" \
  --from-literal=PENDING_SCALE_UP_THRESHOLD="${PENDING_SCALE_UP_THRESHOLD:-1}" \
  --from-literal=RUNNING_SCALE_DOWN_RATIO="${RUNNING_SCALE_DOWN_RATIO:-0.5}" \
  --from-literal=SCALE_STEP="${SCALE_STEP:-1}" \
  --from-literal=MIN_REPLICAS="${MIN_REPLICAS:-1}" \
  --from-literal=MAX_REPLICAS="${MAX_REPLICAS:-2}" \
  --from-literal=COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-90}" \
  --from-literal=DRY_RUN="${SCALER_DRY_RUN:-false}" \
  --from-literal=LOG_LEVEL="${SCALER_LOG_LEVEL:-INFO}" \
  --dry-run=client -o yaml | kctl apply -f -

sed "s/{{NAMESPACE}}/${K8S_NAMESPACE}/g" "$WS1/k8s/deployment.yaml" | kctl apply -f -
kctl rollout status deploy/worker-scaler --timeout=120s

ok "scaler deployed. Watch it:  kubectl -n ${K8S_NAMESPACE} logs -f deploy/worker-scaler"
ok "Now drive load from the trigger app and watch:  kubectl -n ${K8S_NAMESPACE} get deploy ${WORKER_DEPLOYMENT_NAME} -w"
