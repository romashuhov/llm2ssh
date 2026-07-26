# shellcheck shell=bash
# lib/hub.sh — hub key management + node enrollment for multi-server control.
#   On the HUB:  llm2ssh hub keygen        # make the hub's SSH key
#                llm2ssh hub key           # print it (to authorize on nodes)
#   On each NODE: llm2ssh hub-authorize '<pubkey>'
#                 # create the restricted llm2ssh-hub user (reads + freeze +
#                 # admin wrapper; NEVER full/delete) and trust the hub's key.

[[ -n "${_LLM2SSH_HUB_SOURCED:-}" ]] && return 0
_LLM2SSH_HUB_SOURCED=1

HUB_USER="llm2ssh-hub"
HUB_SUDOERS="$LLM2SSH_SUDOERSD/llm2ssh-hub"

cmd_hub() {
  case "${1:-}" in
    keygen) shift || true; hub_keygen "$@" ;;
    key)    hub_show_key ;;
    *) die_usage "usage: llm2ssh hub keygen [--force] | key    (node side: llm2ssh hub-authorize <pubkey>)" ;;
  esac
}

hub_keygen() {
  require_root; have_cmd ssh-keygen || die "ssh-keygen not found (install openssh-client)"
  ensure_dir "$LLM2SSH_HUB_DIR" 0700 "root:root"
  if [[ -f "$LLM2SSH_HUB_KEY" && "${1:-}" != "--force" ]]; then
    log "hub key already exists (use: llm2ssh hub keygen --force to regenerate)"
  else
    rm -f "$LLM2SSH_HUB_KEY" "$LLM2SSH_HUB_KEY.pub"
    ssh-keygen -t ed25519 -N '' -C "llm2ssh-hub:$(hostname)" -f "$LLM2SSH_HUB_KEY" >/dev/null 2>&1 || die "keygen failed"
    chmod 0600 "$LLM2SSH_HUB_KEY"
  fi
  hub_show_key
}

hub_show_key() {
  [[ -r "$LLM2SSH_HUB_KEY.pub" ]] || die "no hub key yet (run: llm2ssh hub keygen)"
  log "authorize this hub on each NODE by running there:"
  log "    sudo llm2ssh hub-authorize '$(cat "$LLM2SSH_HUB_KEY.pub")'"
  cat "$LLM2SSH_HUB_KEY.pub"
}

# cmd_hub_authorize <pubkey...> — run ON A NODE. Trust the hub key and create the
# restricted control user with the SAME rights as the local bot: reads, freeze,
# and the admin wrapper (which refuses full/delete). No root, no destroy.
cmd_hub_authorize() {
  require_root; os_check
  local pub="$*"
  [[ "$pub" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)[[:print:]]+$ ]] || die "expected an SSH public key argument (from 'llm2ssh hub key' on the hub)"

  getent group "$HUB_USER" >/dev/null || groupadd --system "$HUB_USER"
  if ! getent passwd "$HUB_USER" >/dev/null; then
    log "creating control user $HUB_USER"
    # Supplementary group llm2ssh so the shared sshd Match block + key path apply.
    useradd --system --gid "$HUB_USER" --groups "$LLM2SSH_GROUP" \
            --create-home --home-dir "/var/lib/$HUB_USER" --shell /bin/bash \
            --comment "llm2ssh hub control access" "$HUB_USER"
    passwd -l "$HUB_USER" >/dev/null 2>&1 || true
  fi

  # authorized_keys: ROOT-owned path (sshd Match Group llm2ssh -> /etc/llm2ssh/keys/%u),
  # so the hub user cannot self-persist a different key.
  ensure_dir "$LLM2SSH_KEYS" 0755 "root:root"
  printf 'restrict,pty %s\n' "$pub" | atomic_write "$LLM2SSH_KEYS/$HUB_USER" 0644 "root:root"

  # Sudoers: the exact same surface as the bot — reads + freeze + the admin
  # wrapper. NEVER raw grant/full/delete.
  local dbin; dbin="$(resolve_docker_bin 2>/dev/null || echo /usr/bin/docker)"
  local tmp; tmp="$LLM2SSH_SUDOERSD/.llm2ssh-hub.tmp.$$"
  ensure_dir "$LLM2SSH_SUDOERSD" 0755 "root:root"
  cat >"$tmp" <<EOF
# Managed by llm2ssh — the hub control user's privilege surface. DO NOT EDIT.
Cmnd_Alias LLM2SSH_HUB = /usr/local/bin/llm2ssh status, /usr/local/bin/llm2ssh status *, \\
    /usr/local/bin/llm2ssh list, /usr/local/bin/llm2ssh list *, \\
    /usr/local/bin/llm2ssh log *, /usr/local/bin/llm2ssh hwstat, /usr/local/bin/llm2ssh hwstat *, \\
    /usr/local/bin/llm2ssh version, /usr/local/bin/llm2ssh instructions, /usr/local/bin/llm2ssh instructions *, \\
    /usr/local/bin/llm2ssh profiles, \\
    /usr/local/bin/llm2ssh freeze *, /usr/local/bin/llm2ssh unfreeze *, \\
    $dbin ps --format json, $dbin ps -a --format json, \\
    /usr/local/lib/llm2ssh/bin/llm2ssh-bot-admin *
$HUB_USER ALL=(root) NOPASSWD: LLM2SSH_HUB
EOF
  chmod 0440 "$tmp"; chown root:root "$tmp" 2>/dev/null || true
  if ! sudoers_validate "$tmp"; then rm -f "$tmp"; die_validation "generated hub sudoers failed visudo -cf"; fi
  mv -f "$tmp" "$HUB_SUDOERS"

  # sshd reads /etc/llm2ssh/keys/%u live per connection (shared Match Group block
  # was installed at install time), so no reload is needed for the new key.
  log "hub authorized. This node is now reachable from the hub as '$HUB_USER'."
  log "On the hub: llm2ssh servers add <name> $HUB_USER@$(hostname -I 2>/dev/null | awk '{print $1}')"
}
