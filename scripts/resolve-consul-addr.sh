#!/usr/bin/env bash
set -euo pipefail

# Resolve a reachable Consul HTTP endpoint from the current shell context.
# Priority:
# 1) CONSUL_HTTP_ADDR if healthy
# 2) local docker-compose service
# 3) localhost fallback
#
# Note:
# - For app containers in local compose mode, keep CONSUL_HTTP_ADDR=http://consul:8500.
# - This script may return localhost-style URLs when run on the host machine.

normalize_url() {
  local raw="$1"
  if [[ "$raw" =~ ^https?:// ]]; then
    echo "$raw"
  elif [[ "$raw" == *:* ]]; then
    echo "http://$raw"
  else
    echo "http://$raw:8500"
  fi
}

is_consul_healthy() {
  local base="$1"
  local leader
  leader="$(curl -fsS --max-time 3 "$base/v1/status/leader" 2>/dev/null || true)"
  # consul returns quoted address string when healthy, empty string when no leader
  if [ -n "$leader" ] && [ "$leader" != '""' ]; then
    return 0
  fi
  return 1
}

if [ -n "${CONSUL_HTTP_ADDR:-}" ]; then
  C_URL="$(normalize_url "$CONSUL_HTTP_ADDR")"
  if is_consul_healthy "$C_URL"; then
    echo "$C_URL"
    exit 0
  fi
fi

for default_consul in "http://consul:8500" "http://127.0.0.1:8500" "http://localhost:8500"; do
  if is_consul_healthy "$default_consul"; then
    echo "$default_consul"
    exit 0
  fi
done

echo "Unable to resolve healthy CONSUL_HTTP_ADDR. Start docker compose consul or set CONSUL_HTTP_ADDR explicitly." >&2
exit 1
