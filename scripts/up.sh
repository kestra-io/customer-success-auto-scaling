#!/usr/bin/env bash
# One-command bring-up: kind + Helm + flow + trigger app.
source "$(dirname "$0")/lib.sh"
load_env
preflight

# 1. kind cluster (idempotent)
if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
  ok "kind cluster '$KIND_CLUSTER_NAME' already exists"
else
  log "creating kind cluster '$KIND_CLUSTER_NAME'"
  kind create cluster --name "$KIND_CLUSTER_NAME" --config "$ROOT/kind/cluster.yaml"
fi
kubectl config use-context "$KCTX" >/dev/null

# 2. namespace + 3. secrets
"$HERE/create-secrets.sh"

# 4. helm repo
log "helm repo add/update ($HELM_REPO_URL)"
helm repo add kestra "$HELM_REPO_URL" >/dev/null 2>&1 || true
helm repo update kestra >/dev/null || die "helm repo update failed — try HELM_REPO_URL=https://charts.kestra.io in .env"
helm search repo kestra/kestra >/dev/null || die "chart kestra/kestra not found at $HELM_REPO_URL"

# 5. render values + install
# Substitute only our known ${...} tokens (no envsubst dependency — portable on macOS).
RENDERED="$STATE_DIR/values.rendered.yaml"
render_values() {
  local src="$1" out="$2" v
  cp "$src" "$out"
  for v in KESTRA_IMAGE_REPO KESTRA_IMAGE_TAG POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
           KESTRA_JDBC_SECRET KESTRA_ENCRYPTION_SECRET_KEY KESTRA_JWT_SECRET \
           KESTRA_ADMIN_USER KESTRA_ADMIN_PASSWORD \
           KESTRA_EE_LICENSE_ID KESTRA_EE_LICENSE_FINGERPRINT KESTRA_EE_LICENSE_KEY; do
    # value may contain / and & (base64 license key) -> use a non-/ delimiter and escape &
    local val="${!v-}"
    val="${val//&/\\&}"
    LC_ALL=C sed -i.bak "s|\${${v}}|${val}|g" "$out" && rm -f "$out.bak"
  done
}
render_values "$ROOT/helm/values.yaml" "$RENDERED"

# --wait can time out on the slow first EE image pull; wait-ready.sh re-checks.
HELM_ARGS=(upgrade --install "$HELM_RELEASE" kestra/kestra -n "$K8S_NAMESPACE" --create-namespace -f "$RENDERED" --wait --timeout 12m)
[[ -n "${HELM_CHART_VERSION:-}" ]] && HELM_ARGS+=(--version "$HELM_CHART_VERSION")
[[ "$IS_EE" == "true" ]] || HELM_ARGS+=(--set-json 'imagePullSecrets=[]')

log "helm ${HELM_ARGS[*]}"
helm --kube-context "$KCTX" "${HELM_ARGS[@]}" || warn "helm --wait returned non-zero (slow pull?) — wait-ready.sh will confirm"

# 6. port-forward first (wait-ready + import + verify all talk to 127.0.0.1)
"$HERE/portforward.sh" start

# 7. readiness (rollouts + API)
"$HERE/wait-ready.sh"

# 8. flow import + smoke
"$HERE/import-flow.sh"

# 9. metric discovery
"$HERE/verify-metrics.sh" || warn "metric discovery incomplete — re-run 'make metrics' after a few executions"

# 10. trigger app
log "starting trigger app"
docker compose -f "$ROOT/app/docker-compose.yml" --env-file "$ROOT/.env" up -d --build

# 11. done
"$HERE/urls.sh"
ok "bring-up complete. Open the trigger app and try the presets. 'make scaler' adds Workstream 1."
