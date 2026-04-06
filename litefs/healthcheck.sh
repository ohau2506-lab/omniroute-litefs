#!/usr/bin/env bash
set -euo pipefail

check_health() {
  local base_url="${1:-http://127.0.0.1:20128}"
  if curl -fsS --max-time 5 "$base_url/healthz" >/dev/null 2>&1; then
    return 0
  fi
  curl -fsS --max-time 5 "$base_url/api/storage/health" >/dev/null 2>&1
}

check_health
test -f /litefs/storage.sqlite || exit 1
exit 0
