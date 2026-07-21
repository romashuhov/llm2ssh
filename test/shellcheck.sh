#!/usr/bin/env bash
# test/shellcheck.sh — lint every shell script in the project. Run in CI and by
# test/90_shellcheck.bats. Must exit clean at -S warning.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mapfile -t files < <(
  printf '%s\n' \
    bin/llm2ssh install.sh uninstall.sh update.sh \
    lib/*.sh lib/agents/*.sh \
    wrappers/llm2ssh-svc wrappers/llm2ssh-approve wrappers/llm2ssh-ctx wrappers/llm2ssh-bot-admin wrappers/llm2ssh-request wrappers/llm2ssh-du \
    hooks/pretooluse-gate \
    bot/llm2ssh-botd bot/relay-exec bot/tg-api.sh bot/handlers.sh bot/menus.sh
)

exec shellcheck -S warning -x "${files[@]}"
