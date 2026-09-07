#!/usr/bin/env bash
# One-command bring-up: kind cluster -> secrets -> Helm -> port-forwards ->
# readiness -> flow import -> metric discovery -> trigger app -> print URLs.
# Every step is idempotent; re-running `make up` reconciles rather than duplicates.
source "$(dirname "$0")/lib.sh"
load_env
preflight

# 1. kind cluster (skip if it already exists)
if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
  ok "kind cluster '$KIND_CLUSTER_NAME' already exists"
else
  log "creating kind cluster '$KIND_CLUSTER_NAME'"
  kind create cluster --name "$KIND_CLUSTER_NAME" --config "$ROOT/kind/cluster.yaml"
fi
kubectl config use-context "$KCTX" >/dev/null   # make it the current context for convenience

# 2. namespace + 3. image-pull secret (EE only) — see create-secrets.sh
"$HERE/create-secrets.sh"

# 4. Helm repo
log "helm repo add/update ($HELM_REPO_URL)"
helm repo add kestra "$HELM_REPO_URL" >/dev/null 2>&1 || true      # already-added is fine
helm repo update kestra >/dev/null || die "helm repo update failed — try HELM_REPO_URL=https://charts.kestra.io in .env"
helm search repo kestra/kestra >/dev/null || die "chart kestra/kestra not found at $HELM_REPO_URL"

# 5. Render helm/values.yaml and install.
# The committed values file has ${TOKENS} for anything secret or environment
# specific. We substitute only our known set with sed (no envsubst -> portable on
# macOS, and Kestra's own ${...} refs, if any, are left untouched).
RENDERED="$STATE_DIR/values.rendered.yaml"
render_values() {
  local src="$1" out="$2" v
  cp "$src" "$out"
  for v in KESTRA_IMAGE_REPO KESTRA_IMAGE_TAG POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
           KESTRA_JDBC_SECRET KESTRA_ENCRYPTION_SECRET_KEY KESTRA_JWT_SECRET \
           KESTRA_ADMIN_USER KESTRA_ADMIN_PASSWORD \
           KESTRA_EE_LICENSE_ID KESTRA_EE_LICENSE_FINGERPRINT KESTRA_EE_LICENSE_KEY; do
    local val="${!v-}"          # indirect expansion: value of the var named by $v
    val="${val//&/\\&}"         # escape & (sed replacement metachar); the base64 license key can contain it
    # `|` delimiter so the value's / and + (base64) don't need escaping.
    LC_ALL=C sed -i.bak "s|\${${v}}|${val}|g" "$out" && rm -f "$out.bak"
  done
}
render_values "$ROOT/helm/values.yaml" "$RENDERED"

# --wait blocks until all workloads are Ready; the timeout must cover the first
# EE image pull, which can take 20-30 min on a cold node / slow link. If it still
# times out, the webserver gate + wait-ready.sh below re-check.
HELM_ARGS=(upgrade --install "$HELM_RELEASE" kestra/kestra -n "$K8S_NAMESPACE" --create-namespace -f "$RENDERED" --wait --timeout 40m)
[[ -n "${HELM_CHART_VERSION:-}" ]] && HELM_ARGS+=(--version "$HELM_CHART_VERSION")   # pin the chart if set
[[ "$IS_EE" == "true" ]] || HELM_ARGS+=(--set-json 'imagePullSecrets=[]')            # OSS: no pull secret

log "helm ${HELM_ARGS[*]}"
helm --kube-context "$KCTX" "${HELM_ARGS[@]}" || warn "helm --wait returned non-zero (slow pull?) — wait-ready.sh will confirm"

# 6. Gate on the webserver being Ready before port-forwarding — this is what
#    actually absorbs the long image pull if `helm --wait` bailed early. The
#    port-forward target (the webserver Service endpoint) must exist first.
log "waiting for the webserver (covers the image pull; up to 40m on a cold node)"
kctl rollout status "deploy/$(kestra_deploy webserver)" --timeout=2400s

# 7. Port-forwards — steps 8/9/10 all talk to 127.0.0.1:{8080,8082}.
"$HERE/portforward.sh" start

# 8. Readiness: rollout status for every component + an authenticated API probe.
"$HERE/wait-ready.sh"

# 9. Import the workload flow and fire one smoke webhook.
"$HERE/import-flow.sh"

# 10. Discover + pin the exact worker metric names into .state/metric-names.env.
"$HERE/verify-metrics.sh" || warn "metric discovery incomplete — re-run 'make metrics' after a few executions"

# 11. Trigger app (Node container: slider UI + rate loop + /stats).
log "starting trigger app"
docker compose -f "$ROOT/app/docker-compose.yml" --env-file "$ROOT/.env" up -d --build

# 12. Print the URLs and next step.
"$HERE/urls.sh"
ok "bring-up complete. Open the trigger app and try the presets. 'make scaler' adds Workstream 1."
