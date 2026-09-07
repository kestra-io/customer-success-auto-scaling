#!/usr/bin/env bash
# Block until every Kestra component + postgres is Ready and the API answers.
source "$(dirname "$0")/lib.sh"
load_env

log "waiting for postgres StatefulSet"
kctl rollout status statefulset/kestra-postgres --timeout=180s

for c in webserver executor indexer scheduler worker; do
  dep="${HELM_RELEASE}-kestra-${c}"
  log "waiting for deployment/${dep}"
  kctl rollout status "deployment/${dep}" --timeout=300s
done

# Confirm the worker really got --thread=4
wcmd="$(kctl get deploy "${HELM_RELEASE}-kestra-worker" -o jsonpath='{.spec.template.spec.containers[0].command}' 2>/dev/null || true)"
if [[ "$wcmd" == *"--thread=${WORKER_THREADS}"* ]]; then
  ok "worker command contains --thread=${WORKER_THREADS}"
else
  warn "worker command did not show --thread=${WORKER_THREADS}; got: ${wcmd:-<empty>}"
fi

wait_for "Kestra API" 180 bash -c "curl -fsS '$(api "/flows/search?size=1")' -o /dev/null"
ok "Kestra API is answering at ${KESTRA_HTTP}"
