#!/usr/bin/env bash
# llm2ssh — pull the latest and re-install (upgrade-safe). Run from a clone.
#   ./update.sh            # git pull + reinstall
#   ./update.sh --no-tools # pass flags through to install.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

before="$(git rev-parse HEAD 2>/dev/null || echo none)"
git pull --ff-only
after="$(git rev-parse HEAD 2>/dev/null || echo none)"
[ "$before" = "$after" ] && echo "[update] no new commits — reinstalling to be safe"

# install.sh is the upgrade path; it only replaces code, never state.
exec sudo bash ./install.sh "$@"
