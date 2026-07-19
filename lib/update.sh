# shellcheck shell=bash
# lib/update.sh — self-update. Pull the latest source and re-run the installer
# (which is upgrade-safe: it never touches /etc, /var/lib, or /var/log), then
# restart the bot if it's running. Mirrors the "control script" update pattern:
# git pull -> if changed, reapply.

[[ -n "${_LLM2SSH_UPDATE_SOURCED:-}" ]] && return 0
_LLM2SSH_UPDATE_SOURCED=1

# Where install.sh recorded the git checkout it was run from.
LLM2SSH_SRC_FILE="$LLM2SSH_LIB/.source"

cmd_update() {
  local src
  src="$(cat "$LLM2SSH_SRC_FILE" 2>/dev/null || true)"
  if [[ -z "$src" || ! -d "$src/.git" ]]; then
    die "no local git checkout recorded for self-update. Update by re-running the installer:
  cd <your llm2ssh clone> && git pull && sudo ./install.sh
  or: curl -fsSL https://raw.githubusercontent.com/romashuhov/llm2ssh/main/install.sh | sudo bash"
  fi
  have_cmd git || die "git not found (needed for 'llm2ssh update')"

  local before after
  before="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo none)"
  log "pulling latest from $src"
  git -C "$src" pull --ff-only || die "git pull failed (uncommitted changes or diverged history in $src?)"
  after="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo none)"
  [[ "$before" == "$after" ]] && log "no new commits — reinstalling to be safe"

  log "re-running installer"
  bash "$src/install.sh" "$@" || die "installer failed"

  # Restart the bot so it picks up new code (the gc timer and sshd drop-in are
  # handled by install.sh itself).
  if have_cmd systemctl && systemctl is-active llm2ssh-bot >/dev/null 2>&1; then
    log "restarting llm2ssh-bot"
    systemctl restart llm2ssh-bot || warn "could not restart llm2ssh-bot (check: journalctl -u llm2ssh-bot)"
  fi
  log "updated — now at version $(cat "$LLM2SSH_LIB/VERSION" 2>/dev/null || echo '?')"
}
