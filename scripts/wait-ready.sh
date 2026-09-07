#!/usr/bin/env bash
# Block until Postgres + every Kestra component is rolled out and the API answers.
# Called by up.sh after `helm --wait` (which can time out on the first image pull,
# hence this belt-and-suspenders re-check with longer per-deployment timeouts).
source "$(dirname "$0")/lib.sh"
load_env

log "waiting for postgres StatefulSet"
kctl rollout status statefulset/kestra-postgres --timeout=600s

# indexer is intentionally NOT in this list — it's disabled in helm/values.yaml
# (only needed with an Elasticsearch backend; postgres repo uses the webserver's
# embedded indexer).
for c in webserver executor scheduler worker; do
  dep="$(kestra_deploy "$c")"                       # resolve real name by label
  [[ -n "$dep" ]] || die "could not find the '$c' deployment by label"
  log "waiting for deployment/${dep}"
  # 40m: covers a cold-node EE image pull if `helm --wait` and the webserver
  # gate in up.sh didn't already absorb it.
  kctl rollout status "deployment/${dep}" --timeout=2400s
done

# Sanity-check that the chart actually rendered the worker thread flag we asked
# for (deployments.worker.workerThreads -> `--thread=N` in the container command).
worker_dep="$(kestra_deploy worker)"
wcmd="$(kctl get deploy "$worker_dep" -o jsonpath='{.spec.template.spec.containers[0].command}' 2>/dev/null || true)"
if [[ "$wcmd" == *"--thread=${WORKER_THREADS}"* ]]; then
  ok "worker command contains --thread=${WORKER_THREADS}"
else
  warn "worker command did not show --thread=${WORKER_THREADS}; got: ${wcmd:-<empty>}"
fi

# Final gate: an authenticated API call succeeds through the port-forward.
# ${VAR:+ -u '...'} only adds the -u flag when KESTRA_ADMIN_USER is set (it always
# is here, but keeps the OSS/no-auth path working).
wait_for "Kestra API" 240 bash -c "curl -fsS ${KESTRA_ADMIN_USER:+-u '${KESTRA_ADMIN_USER}:${KESTRA_ADMIN_PASSWORD}'} '$(api "/flows/search?size=1")' -o /dev/null"
ok "Kestra API is answering at ${KESTRA_HTTP}"
