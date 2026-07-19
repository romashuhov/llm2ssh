#!/usr/bin/env bash
# test/run.sh — run the bats suite inside throwaway containers (root),
# across the supported OS matrix. Usage: test/run.sh [image ...]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES=("$@")
[[ ${#IMAGES[@]} -eq 0 ]] && IMAGES=("ubuntu:24.04" "debian:12")

# Prevent MSYS/Git-Bash from mangling container-side paths on Windows.
export MSYS_NO_PATHCONV=1

fail=0
for img in "${IMAGES[@]}"; do
  echo "############ $img ############"
  if ! docker run --rm \
        -v "$REPO":/src:ro \
        -w /src \
        "$img" \
        bash /src/test/docker-entry.sh; then
    echo "!!!! FAILED on $img" >&2
    fail=1
  fi
done

[[ "$fail" -eq 0 ]] && echo "ALL GREEN" || echo "SOME FAILURES" >&2
exit "$fail"
