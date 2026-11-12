#!/usr/bin/env bash
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  printf 'Usage: bash %s <target-ip> [port]\n' "${0##*/}" >&2
  exit 2
fi

exec curl --noproxy '*' --silent --show-error --fail \
  --connect-timeout 5 --max-time 15 --output /dev/null \
  --write-out 'HTTP %{http_code} from %{url_effective}\n' \
  -- "http://$1:${2:-3000}/"
