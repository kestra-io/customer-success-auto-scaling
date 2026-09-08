#!/usr/bin/env bash
# Set the namespace-KV values for the sqs-pod-admission flow family:
#   sqs_pod_admission_enabled          intake gate read by the parent trigger
#   sqs_pod_admission_size             batch size (maxRecords) read by the parent
#   sqs_pod_admission_slots_available  available capacity read by the controller;
#                                      optional third arg, adjust it to simulate
#                                      adding/removing cluster capacity
#
# Usage:
#   ./set_sqs_pod_admission_kv.sh false 1
#   ./set_sqs_pod_admission_kv.sh true 32
#   ./set_sqs_pod_admission_kv.sh true 32 8    # also set slots_available=8
#
# Reads KESTRA_HOST, KESTRA_USER, KESTRA_PASSWORD, KESTRA_TENANT, and
# FLOW_NAMESPACE from ./.env when present.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

ENABLED=${1:-}
SIZE=${2:-}
SLOTS_AVAILABLE=${3:-}
case "$ENABLED" in
  true|false) ;;
  *) echo "Usage: $0 <true|false> <positive-batch-size> [slots-available]" >&2; exit 2 ;;
esac
case "$SIZE" in
  ''|*[!0-9]*) echo "ERROR: batch size must be a positive integer" >&2; exit 2 ;;
esac
if [ "$SIZE" -lt 1 ]; then
  echo "ERROR: batch size must be at least 1; use enabled=false to close intake" >&2
  exit 2
fi
if [ -n "$SLOTS_AVAILABLE" ]; then
  case "$SLOTS_AVAILABLE" in
    *[!0-9]*) echo "ERROR: slots-available must be a non-negative integer" >&2; exit 2 ;;
  esac
fi

: "${KESTRA_HOST:?Set KESTRA_HOST}"
: "${KESTRA_USER:?Set KESTRA_USER}"
: "${KESTRA_PASSWORD:?Set KESTRA_PASSWORD}"

KESTRA_HOST=${KESTRA_HOST%/}
KESTRA_TENANT=${KESTRA_TENANT:-default}
FLOW_NAMESPACE=${FLOW_NAMESPACE:-demo}

TOKEN_RESPONSE=$(curl -fsS -u "${KESTRA_USER}:${KESTRA_PASSWORD}" \
  -X POST "${KESTRA_HOST}/api/v1/me/api-tokens" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"sqs-pod-kv-$$\",\"description\":\"temporary test token\",\"extended\":false}")
TOKEN=$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.fullToken // empty')
if [ -z "$TOKEN" ]; then
  echo "ERROR: could not create a Kestra API token" >&2
  exit 1
fi

put_kv() {
  key=$1
  value=$2
  curl -fsS -X PUT \
    "${KESTRA_HOST}/api/v1/${KESTRA_TENANT}/namespaces/${FLOW_NAMESPACE}/kv/${key}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: text/plain' \
    --data-binary "$value"
}

put_kv sqs_pod_admission_enabled "$ENABLED"
put_kv sqs_pod_admission_size "$SIZE"
if [ -n "$SLOTS_AVAILABLE" ]; then
  put_kv sqs_pod_admission_slots_available "$SLOTS_AVAILABLE"
fi
printf 'Set %s KV: intake_enabled=%s, batch_size=%s%s\n' \
  "$FLOW_NAMESPACE" "$ENABLED" "$SIZE" \
  "${SLOTS_AVAILABLE:+, slots_available=$SLOTS_AVAILABLE}"
