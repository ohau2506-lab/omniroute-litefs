#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://localhost:20128}"

check_health() {
  local base_url="${1:-http://localhost:20128}"
  if curl -fsS --max-time 5 "$base_url/healthz" >/dev/null 2>&1; then
    return 0
  fi
  curl -fsS --max-time 5 "$base_url/api/storage/health"
}

echo "Health..."
check_health "$BASE_URL"

echo "Models..."
curl -fsS "$BASE_URL/v1/models" >/dev/null

echo "Smoke OK"
