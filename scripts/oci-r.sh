#!/usr/bin/env bash
# Wrapper para `oci` que reintenta automáticamente ante 401 NotAuthenticated —
# la API key recién agregada tarda en propagar de forma pareja entre réplicas/servicios de OCI.
# Uso: scripts/oci-r.sh <mismos argumentos que 'oci'>
set -uo pipefail
MAX_ATTEMPTS=8
SLEEP_SECS=8

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  out=$(oci "$@" 2>&1)
  code=$?
  if [ $code -eq 0 ]; then
    echo "$out" | grep -vE "^(Warning: To increase security|Action completed\.|WARNING: This operation)"
    exit 0
  fi
  if echo "$out" | grep -q "NotAuthenticated"; then
    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
      sleep "$SLEEP_SECS"
      continue
    fi
  fi
  echo "$out" | grep -v "^Warning: To increase security" >&2
  exit "$code"
done
