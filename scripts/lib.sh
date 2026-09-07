#!/usr/bin/env bash
# Shared helpers. Source this: `source "$(dirname "$0")/lib.sh"`
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATE_DIR="$ROOT/.state"
mkdir -p "$STATE_DIR"

# ── logging ────────────────────────────────────────────────────────────────────
_c() { printf '\033[%sm' "$1"; }
log()  { echo -e "$(_c '1;36')▶$(_c 0) $*"; }
ok()   { echo -e "$(_c '1;32')✔$(_c 0) $*"; }
warn() { echo -e "$(_c '1;33')!$(_c 0) $*" >&2; }
die()  { echo -e "$(_c '1;31')x$(_c 0) $*" >&2; exit 1; }

# ── env ───────────────────────────────────────────────────────────────────────
load_env() {
  [[ -f "$ROOT/.env" ]] || die "no $ROOT/.env — copy .env.example and fill it in (see SETUP.md)"
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
  : "${KIND_CLUSTER_NAME:?}" "${K8S_NAMESPACE:?}" "${HELM_RELEASE:?}" "${KESTRA_IMAGE:?}"
  : "${KESTRA_TENANT:?}" "${FLOW_NAMESPACE:?}" "${FLOW_ID:?}" "${WEBHOOK_KEY:?}"
  : "${WORKER_THREADS:?}"
  KCTX="kind-${KIND_CLUSTER_NAME}"
  KESTRA_IMAGE_REPO="${KESTRA_IMAGE%:*}"
  KESTRA_IMAGE_TAG="${KESTRA_IMAGE##*:}"
  IS_EE=true
  [[ "$KESTRA_IMAGE_REPO" == registry.kestra.io/* ]] || IS_EE=false
  export KCTX KESTRA_IMAGE_REPO KESTRA_IMAGE_TAG IS_EE
}

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

preflight() {
  for t in docker kind kubectl helm curl jq; do require "$t"; done
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"
}

kctl() { kubectl --context "$KCTX" -n "$K8S_NAMESPACE" "$@"; }
hlm()  { helm --kube-context "$KCTX" -n "$K8S_NAMESPACE" "$@"; }

# Resolve chart resource names by label (the chart's fullname is release-name-
# dependent: "kestra" when the release is called kestra, "<release>-kestra" otherwise).
kestra_deploy() {  # kestra_deploy <component>
  kctl get deploy -l "app.kubernetes.io/name=kestra,app.kubernetes.io/component=$1" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}
kestra_webserver_svc() {
  kctl get svc -l "app.kubernetes.io/name=kestra,app.kubernetes.io/component=webserver" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# wait_for "<description>" <timeout-seconds> <command...>
wait_for() {
  local desc="$1" timeout="$2"; shift 2
  local deadline=$(( SECONDS + timeout ))
  log "waiting for: $desc (timeout ${timeout}s)"
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "timed out waiting for: $desc"
    sleep 3
  done
  ok "ready: $desc"
}

# Base URLs once the port-forward is up.
KESTRA_HTTP="http://127.0.0.1:8080"
KESTRA_MGMT="http://127.0.0.1:8081"
api() { echo "${KESTRA_HTTP}/api/v1/${KESTRA_TENANT}$1"; }
webhook_url() { echo "$(api "/executions/webhook/${FLOW_NAMESPACE}/${FLOW_ID}/${WEBHOOK_KEY}")"; }
