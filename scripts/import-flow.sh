#!/usr/bin/env bash
# Import flows/webhook_sleep.yaml, verify it, and fire one smoke webhook.
source "$(dirname "$0")/lib.sh"
load_env

FLOW_FILE="$ROOT/flows/webhook_sleep.yaml"
[[ -f "$FLOW_FILE" ]] || die "missing $FLOW_FILE"

log "importing $(basename "$FLOW_FILE")"
kcurl -fsS -X POST -F "fileUpload=@${FLOW_FILE}" "$(api "/flows/import")" >/dev/null
ok "import accepted"

wait_for "flow ${FLOW_NAMESPACE}.${FLOW_ID} registered" 30 \
  bash -c "curl -fsS ${KESTRA_ADMIN_USER:+-u '${KESTRA_ADMIN_USER}:${KESTRA_ADMIN_PASSWORD}'} '$(api "/flows/${FLOW_NAMESPACE}/${FLOW_ID}")' -o /dev/null"

# The webhook is URL-keyed and anonymous — plain curl on purpose.
log "smoke webhook -> $(webhook_url)"
resp="$(curl -fsS -X POST -H 'Content-Type: application/json' -d '{}' "$(webhook_url)")"
exec_id="$(jq -r '.id // empty' <<<"$resp")"
[[ -n "$exec_id" ]] || die "webhook did not return an execution id; body: $resp"
ok "execution $exec_id created"

log "polling execution state (Sleep is ${SLEEP_DURATION:-PT15S})"
for _ in $(seq 1 20); do
  state="$(kcurl -fsS "$(api "/executions/${exec_id}")" | jq -r '.state.current')"
  echo "  state=$state"
  [[ "$state" == "SUCCESS" ]] && { ok "smoke execution SUCCESS"; exit 0; }
  [[ "$state" == "FAILED" || "$state" == "KILLED" ]] && die "smoke execution $state"
  sleep 3
done
warn "smoke execution still $state after ~60s — check the UI"
