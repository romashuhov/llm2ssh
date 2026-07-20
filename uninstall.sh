#!/usr/bin/env bash
# uninstall.sh — remove llm2ssh. Standalone: works even if the installed CLI
# is broken. Deletes all managed agents first (with confirmation), then code.
#
#   sudo ./uninstall.sh [--purge-logs] [--yes]
set -euo pipefail

PREFIX_BIN="/usr/local/bin"
PREFIX_LIB="/usr/local/lib/llm2ssh"

_log() { printf '[uninstall] %s\n' "$*" >&2; }
_die() { printf '[uninstall] error: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || _die "must run as root"

PURGE_LOGS=0; ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --purge-logs) PURGE_LOGS=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    *) _die "unknown option: $arg" ;;
  esac
done

_confirm() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  [[ -t 0 ]] || _die "confirmation required; re-run with --yes"
  local ans; read -r -p "$1 [y/N] " ans; [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# Enumerate agents from state (independent of the CLI).
agents=()
if [[ -d /var/lib/llm2ssh/agents ]]; then
  for d in /var/lib/llm2ssh/agents/*/; do
    [[ -d "$d" ]] && agents+=("$(basename "$d")")
  done
fi

if [[ ${#agents[@]} -gt 0 ]]; then
  _log "managed agents: ${agents[*]}"
  _confirm "delete these agents (users, keys, sudoers) and remove llm2ssh?" || { _log "aborted"; exit 0; }
  for a in "${agents[@]}"; do
    _log "removing agent $a"
    # Prefer the CLI's delete (handles kill/keys/audit); fall back to manual.
    if [[ -x "$PREFIX_BIN/llm2ssh" ]] && "$PREFIX_BIN/llm2ssh" delete "$a" --yes >/dev/null 2>&1; then
      continue
    fi
    rm -f "/etc/sudoers.d/llm2ssh-$a"
    rm -f "/etc/llm2ssh/keys/$a" "/etc/llm2ssh/keys/$a.frozen"
    rm -f "/etc/audit/rules.d/llm2ssh-$a.rules"
    userdel -r "$a" >/dev/null 2>&1 || true
  done
  command -v augenrules >/dev/null && augenrules --load >/dev/null 2>&1 || true
else
  _confirm "remove llm2ssh (no managed agents found)?" || { _log "aborted"; exit 0; }
fi

# sshd drop-in.
if [[ -f /etc/ssh/sshd_config.d/60-llm2ssh.conf ]]; then
  rm -f /etc/ssh/sshd_config.d/60-llm2ssh.conf
  if command -v sshd >/dev/null && sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
fi

# systemd units.
if command -v systemctl >/dev/null; then
  for unit in llm2ssh-gc.timer llm2ssh-gc.service llm2ssh-bot.service; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$unit"
  done
  systemctl daemon-reload || true
fi

# Code + tmpfiles.
rm -f "$PREFIX_BIN/llm2ssh" "$PREFIX_BIN/llm2ssh-ctx" "$PREFIX_BIN/llm2ssh-approve"
rm -rf "$PREFIX_LIB"
rm -f /etc/tmpfiles.d/llm2ssh.conf
rm -rf /run/llm2ssh

# Config/state.
rm -rf /etc/llm2ssh /var/lib/llm2ssh /var/lib/llm2ssh-bot

if [[ "$PURGE_LOGS" -eq 1 ]]; then
  _log "purging logs"
  rm -rf /var/log/llm2ssh
else
  _log "logs kept at /var/log/llm2ssh (use --purge-logs to remove)"
fi

# Bot user (leave the group only if empty of humans; safe to remove both).
userdel llm2ssh-bot >/dev/null 2>&1 || true
groupdel llm2ssh >/dev/null 2>&1 || true

_log "llm2ssh removed"
