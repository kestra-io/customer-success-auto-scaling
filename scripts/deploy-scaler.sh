#!/usr/bin/env bash
# Build, load, configure, and deploy the Workstream 1 scaler.
source "$(dirname "$0")/lib.sh"
load_env

WS1="$ROOT/workstream-1-prometheus-worker-scaling"
IMAGE="kestra-autoscaling/worker-scaler:local"

# metric names discovered at bring-up (fall back to .env defaults)
[[ -f "$STATE_DIR/metric-names.env" ]] && { set -a; source "$STATE_DIR/metric-names.env"; set +a; }

WORKER_DEPLOYMENT_NAME="$(kestra_deploy worker)"
[[ -n "$WORKER_DEPLOYMENT_NAME" ]] || die "could not find the worker deployment by label"
WEBSERVER_SVC="$(kestra_webserver_svc)"
[[ -n "$WEBSERVER_SVC" ]] || die "could not find the webserver service by label"
PROM_URL="http://${WEBSERVER_SVC}.${K8S_NAMESPACE}.svc:8081/prometheus"
log "worker deployment: ${WORKER_DEPLOYMENT_NAME}   prometheus: ${PROM_URL}"

log "build $IMAGE"
docker build -t "$IMAGE" "$WS1"
log "kind load $IMAGE"
kind load docker-image "$IMAGE" --name "$KIND_CLUSTER_NAME"

log "apply RBAC"
for m in serviceaccount role rolebinding; do
  sed "s/{{NAMESPACE}}/${K8S_NAMESPACE}/g" "$WS1/k8s/${m}.yaml" | kctl apply -f -
done

log "verify the ServiceAccount can scale the worker Deployment"
kctl auth can-i patch deployments/scale \
  --as="system:serviceaccount:${K8S_NAMESPACE}:worker-scaler" >/dev/null \
  && ok "RBAC ok" || warn "RBAC check returned non-yes — the scaler may not be able to patch"

log "render + apply scaler config"
kctl create configmap worker-scaler-config \
  --from-literal=PROMETHEUS_URL="$PROM_URL" \
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
