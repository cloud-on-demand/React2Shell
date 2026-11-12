#!/usr/bin/env bash
set -euo pipefail

options=()
if [[ ${1:-} == --dump ]]; then
  options=(-dump -width=80)
  shift
fi

if (( $# < 1 || $# > 2 )); then
  printf 'Usage: bash %s [--dump] <target-ip> [port]\n' "${0##*/}" >&2
  exit 2
fi

exec lynx "${options[@]}" "http://$1:${2:-3000}/"
