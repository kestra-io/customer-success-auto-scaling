#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
load_env
cat <<EOF

  Kestra UI          ${KESTRA_HTTP}      login: ${KESTRA_ADMIN_USER} / (KESTRA_ADMIN_PASSWORD in .env)
  Webhook            $(webhook_url)
  Webserver metrics  ${KESTRA_MGMT}/prometheus        (jdbc / queue)
  Worker metrics     ${KESTRA_WORKER_MGMT}/prometheus        (kestra_worker_job_*)
  Trigger app        http://localhost:${APP_PORT:-5173}

  Watch scaling: kubectl --context ${KCTX} -n ${K8S_NAMESPACE} get deploy -w
  Scaler logs:   kubectl --context ${KCTX} -n ${K8S_NAMESPACE} logs -f deploy/worker-scaler

EOF
