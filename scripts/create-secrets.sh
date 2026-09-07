#!/usr/bin/env bash
# Create the registry image-pull secret (EE only). License + internal secrets are
# rendered into the chart's `kestra-sensitive` Secret by up.sh via envsubst.
source "$(dirname "$0")/lib.sh"
load_env

kctl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml 2>/dev/null \
  | kubectl --context "$KCTX" apply -f - >/dev/null || true

if [[ "$IS_EE" == "true" ]]; then
  : "${KESTRA_REGISTRY_SERVER:?}" "${KESTRA_REGISTRY_USERNAME:?set KESTRA_REGISTRY_USERNAME in .env (or use the OSS image)}" "${KESTRA_REGISTRY_PASSWORD:?set KESTRA_REGISTRY_PASSWORD in .env}"
  : "${KESTRA_EE_LICENSE_ID:?set KESTRA_EE_LICENSE_ID in .env (or use the OSS image)}"
  : "${KESTRA_EE_LICENSE_FINGERPRINT:?}" "${KESTRA_EE_LICENSE_KEY:?}"
  log "creating image-pull secret kestra-registry"
  kctl create secret docker-registry kestra-registry \
    --docker-server="$KESTRA_REGISTRY_SERVER" \
    --docker-username="$KESTRA_REGISTRY_USERNAME" \
    --docker-password="$KESTRA_REGISTRY_PASSWORD" \
    --dry-run=client -o yaml | kctl apply -f - >/dev/null
  ok "kestra-registry secret in place"
else
  warn "OSS image ($KESTRA_IMAGE) — skipping registry secret and EE license"
fi
