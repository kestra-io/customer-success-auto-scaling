#!/usr/bin/env bash
# Shared helpers sourced by every other script:  source "$(dirname "$0")/lib.sh"
#
# Provides: strict mode, coloured logging, .env loading + validation, a kubectl
# context wrapper, chart-resource name resolution, a generic wait_for(), the
# host-side base URLs, and an auth-aware curl.

set -euo pipefail        # -e: exit on error  -u: error on unset var  -o pipefail: fail a pipe if any stage fails

# Absolute paths, independent of the caller's CWD. BASH_SOURCE[0] is *this* file
# even when sourced.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../scripts
ROOT="$(cd "$HERE/.." && pwd)"                         # the initiative root
STATE_DIR="$ROOT/.state"                               # gitignored scratch (pids, rendered values, scrapes)
mkdir -p "$STATE_DIR"

# ── logging ────────────────────────────────────────────────────────────────────
_c()   { printf '\033[%sm' "$1"; }                        # raw ANSI colour code
log()  { echo -e "$(_c '1;36')▶$(_c 0) $*"; }             # cyan  ▶  step / progress
ok()   { echo -e "$(_c '1;32')✔$(_c 0) $*"; }             # green ✔  success
warn() { echo -e "$(_c '1;33')!$(_c 0) $*" >&2; }         # yellow ! non-fatal, to stderr
die()  { echo -e "$(_c '1;31')x$(_c 0) $*" >&2; exit 1; } # red x  fatal, to stderr, exit 1

# ── env ───────────────────────────────────────────────────────────────────────
# Load .env, export every var in it, then assert the ones nothing can run without.
load_env() {
  [[ -f "$ROOT/.env" ]] || die "no $ROOT/.env — copy .env.example and fill it in (see SETUP.md)"
  set -a                                   # auto-export everything defined until `set +a`
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
  # ${VAR:?} aborts with an error if VAR is unset or empty — cheap required-field check.
  : "${KIND_CLUSTER_NAME:?}" "${K8S_NAMESPACE:?}" "${HELM_RELEASE:?}" "${KESTRA_IMAGE:?}"
  : "${KESTRA_TENANT:?}" "${FLOW_NAMESPACE:?}" "${FLOW_ID:?}" "${WEBHOOK_KEY:?}"
  : "${WORKER_THREADS:?}"

  KCTX="kind-${KIND_CLUSTER_NAME}"          # kubectl context kind always creates
  KESTRA_IMAGE_REPO="${KESTRA_IMAGE%:*}"    # strip ":tag"  -> registry.kestra.io/docker/kestra-ee
  KESTRA_IMAGE_TAG="${KESTRA_IMAGE##*:}"    # keep after last ":"  -> v1.3.24
  # EE vs OSS is inferred from the registry host: EE lives on registry.kestra.io,
  # OSS is kestra/kestra on Docker Hub. Controls the pull secret + license path.
  IS_EE=true
  [[ "$KESTRA_IMAGE_REPO" == registry.kestra.io/* ]] || IS_EE=false
  export KCTX KESTRA_IMAGE_REPO KESTRA_IMAGE_TAG IS_EE
}

# Fail early if a CLI dependency is missing.
require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

preflight() {
  for t in docker kind kubectl helm curl jq; do require "$t"; done
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"
}

# Pin every kubectl/helm call to this cluster + namespace so a stray current-context
# can never touch the wrong cluster.
kctl() { kubectl --context "$KCTX" -n "$K8S_NAMESPACE" "$@"; }
hlm()  { helm --kube-context "$KCTX" -n "$K8S_NAMESPACE" "$@"; }

# The Helm chart's resource names depend on the release name (fullname == "kestra"
# when the release is called kestra, "<release>-kestra" otherwise), and the shared
# Service carries no `component` label. So resolve names by label / shape, not by
# string-building.
kestra_deploy() {  # kestra_deploy <component>   e.g. kestra_deploy worker -> kestra-worker
  kctl get deploy -l "app.kubernetes.io/name=kestra,app.kubernetes.io/component=$1" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}
kestra_webserver_svc() {
  # The chart's main Service fronts the webserver on 8080 + 8081 but has only
  # name=kestra (no component label). Try the usual names first...
  local s
  for s in "$HELM_RELEASE" "${HELM_RELEASE}-kestra" "${HELM_RELEASE}-webserver"; do
    kctl get "svc/$s" >/dev/null 2>&1 && { echo "$s"; return; }
  done
  # ...then fall back to "a kestra-labelled Service whose first port is 8080,
  # excluding the worker-metrics and postgres Services".
  kctl get svc -l "app.kubernetes.io/name=kestra" \
    -o jsonpath='{range .items[?(@.spec.ports[0].port==8080)]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -v -e worker-metrics -e postgres | head -1
}

# Poll a command until it succeeds or the timeout elapses.
#   wait_for "<description>" <timeout-seconds> <command...>
wait_for() {
  local desc="$1" timeout="$2"; shift 2
  local deadline=$(( SECONDS + timeout ))   # SECONDS = bash builtin, seconds since shell start
  log "waiting for: $desc (timeout ${timeout}s)"
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "timed out waiting for: $desc"
    sleep 3
  done
  ok "ready: $desc"
}

# Host-side endpoints, valid once portforward.sh has started the tunnels.
KESTRA_HTTP="http://127.0.0.1:8080"          # webserver: API + UI
KESTRA_MGMT="http://127.0.0.1:8081"          # webserver management: jdbc/queue metrics (NOT worker metrics)
KESTRA_WORKER_MGMT="http://127.0.0.1:8082"   # worker management: kestra_worker_job_* (via svc/kestra-worker-metrics, ONE pod)
KESTRA_SCALER_STATE="http://127.0.0.1:8083"  # worker-scaler GET /state: authoritative multi-worker sum + replica count
api()         { echo "${KESTRA_HTTP}/api/v1/${KESTRA_TENANT}$1"; }        # build a tenant-scoped API URL
webhook_url() { echo "$(api "/executions/webhook/${FLOW_NAMESPACE}/${FLOW_ID}/${WEBHOOK_KEY}")"; }

# curl for the AUTHENTICATED data/management API (EE keeps an auth layer even with
# basicAuth off). The webhook and :8082/prometheus are anonymous — call those
# with plain `curl`, not kcurl.
kcurl() {
  if [[ -n "${KESTRA_ADMIN_USER:-}" ]]; then
    curl -u "${KESTRA_ADMIN_USER}:${KESTRA_ADMIN_PASSWORD}" "$@"
  else
    curl "$@"
  fi
}
