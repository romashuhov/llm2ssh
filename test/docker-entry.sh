#!/usr/bin/env bash
# Runs inside the test container. Installs test deps, then runs bats.
# The repo is mounted read-only at /src; we copy to a writable /work so
# install.sh and tests can operate normally.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq bats jq shellcheck git >/dev/null

cp -a /src /work
cd /work

# Files authored on Windows may lack the execute bit; restore it for scripts.
chmod +x bin/llm2ssh install.sh uninstall.sh test/*.sh 2>/dev/null || true
for d in wrappers hooks bot; do
  [[ -d "$d" ]] && chmod +x "$d"/* 2>/dev/null || true
done

echo "=== bats: $(. /etc/os-release; echo "$PRETTY_NAME") ==="
bats test/
