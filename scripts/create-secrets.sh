#!/usr/bin/env bash
# Create the namespace and, for the EE image, the registry image-pull secret.
#
# NOTE: the Kestra config secret (license, jdbc/encryption keys, admin creds) is
# NOT created here — it's the `kestra-sensitive` Secret inside helm/values.yaml
# `extraManifests`, rendered from .env by up.sh's render_values().
source "$(dirname "$0")/lib.sh"
load_env

# Idempotent namespace create (dry-run -> apply). `|| true`: already-exists is fine.
kctl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml 2>/dev/null \
  | kubectl --context "$KCTX" apply -f - >/dev/null || true

if [[ "$IS_EE" == "true" ]]; then
  # Required for EE: registry creds (username = LICENSE ID, password = FINGERPRINT)
  # and the three license fields (they flow into kestra-sensitive via up.sh).
  : "${KESTRA_REGISTRY_SERVER:?}" "${KESTRA_REGISTRY_USERNAME:?set KESTRA_REGISTRY_USERNAME in .env (or use the OSS image)}" "${KESTRA_REGISTRY_PASSWORD:?set KESTRA_REGISTRY_PASSWORD in .env}"
  : "${KESTRA_EE_LICENSE_ID:?set KESTRA_EE_LICENSE_ID in .env (or use the OSS image)}"
  : "${KESTRA_EE_LICENSE_FINGERPRINT:?}" "${KESTRA_EE_LICENSE_KEY:?}"

  log "creating image-pull secret kestra-registry"
  # dry-run|apply so re-running just updates it. helm/values.yaml references this
  # secret name in `imagePullSecrets`.
  kctl create secret docker-registry kestra-registry \
    --docker-server="$KESTRA_REGISTRY_SERVER" \
    --docker-username="$KESTRA_REGISTRY_USERNAME" \
    --docker-password="$KESTRA_REGISTRY_PASSWORD" \
    --dry-run=client -o yaml | kctl apply -f - >/dev/null
  ok "kestra-registry secret in place"
else
  # OSS path: kestra/kestra on Docker Hub, no auth, no license. up.sh also passes
  # --set-json 'imagePullSecrets=[]' so the chart doesn't reference the missing secret.
  warn "OSS image ($KESTRA_IMAGE) — skipping registry secret and EE license"
fi
