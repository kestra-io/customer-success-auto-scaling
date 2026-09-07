#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
load_env
cat <<EOF

  Kestra UI      ${KESTRA_HTTP}            (no login — basic auth is off)
  Webhook        $(webhook_url)
  Prometheus     ${KESTRA_MGMT}/prometheus
  Trigger app    http://localhost:${APP_PORT:-5173}

  Watch scaling: kubectl --context ${KCTX} -n ${K8S_NAMESPACE} get deploy -w
  Scaler logs:   kubectl --context ${KCTX} -n ${K8S_NAMESPACE} logs -f deploy/worker-scaler

EOF
