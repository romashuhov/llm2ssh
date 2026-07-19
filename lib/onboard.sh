# shellcheck shell=bash
# lib/onboard.sh — the one-command, minimal-effort path: create the agent (if it
# doesn't exist), generate an SSH keypair ON THE SERVER, and print a single
# paste-into-the-agent's-chat block. The agent runs the block, sets up its key,
# and starts working via `ssh <alias> '<cmd>'`.
#
# Convenience vs. hygiene: this prints a PRIVATE KEY once. That's acceptable here
# because the key grants only the agent's CURRENT profile (observer = read-only
# by default), and can be revoked instantly (`llm2ssh freeze`/`key remove`). For
# a no-private-key-over-the-wire flow, use `create --github` + `connect-info`.

[[ -n "${_LLM2SSH_ONBOARD_SOURCED:-}" ]] && return 0
_LLM2SSH_ONBOARD_SOURCED=1

cmd_onboard() {
  local agent="" profile="observer" replace=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="${2:?}"; shift 2 ;;
      --replace) replace=1; shift ;;
      -*) die_usage "unknown flag for onboard: $1" ;;
      *) agent="$1"; shift ;;
    esac
  done
  [[ -n "$agent" ]] || die_usage "usage: llm2ssh onboard <agent> [--profile P] [--replace]"
  require_valid_agent_name "$agent"
  have_cmd ssh-keygen || die "ssh-keygen not found (install openssh-client)"
  os_check

  # Create the agent (observer base by default) if it isn't there yet.
  if ! agent_exists "$agent"; then
    cmd_create "$agent" --profile "$profile" >&2
  elif [[ "$profile" != "observer" ]]; then
    with_lock_noop_grant "$agent" "$profile"
  fi

  # Optionally invalidate previously issued keys (rotate).
  [[ "$replace" -eq 1 ]] && printf '' | atomic_write "$LLM2SSH_KEYS/$agent" 0644 "root:root"

  # Generate the keypair server-side; the private key is printed once, never stored.
  local tmpd priv
  tmpd="$(mktemp -d)"
  ssh-keygen -t ed25519 -N '' -C "llm2ssh:$agent:$(_detect_host)" -f "$tmpd/k" >/dev/null 2>&1 \
    || { rm -rf "$tmpd"; die "keygen failed"; }
  { [[ -r "$LLM2SSH_KEYS/$agent" ]] && cat "$LLM2SSH_KEYS/$agent"; cat "$tmpd/k.pub"; } \
    | write_agent_keys "$agent" >/dev/null
  priv="$(cat "$tmpd/k")"
  rm -rf "$tmpd"
  declare -F sshd_reload >/dev/null 2>&1 && sshd_reload || true

  local host alias kh
  host="$(_detect_host)"
  alias="llm-$agent"
  kh="$(_known_hosts_line "$host" || true)"

  # Human note -> stderr; the copy-paste block -> stdout.
  warn "generated a one-time PRIVATE KEY for '$agent' (profile: $(state_get "$agent" current_profile "$profile"))."
  warn "it grants only that profile's access and is instantly revocable: llm2ssh freeze $agent"
  if [[ -z "$kh" ]]; then
    warn "no ssh host key found — the agent will be asked to accept the host on first connect."
  fi

  _onboard_blob "$agent" "$host" "$alias" "$kh" "$priv"
  return 0
}

# Apply a starting profile without holding a second lock (we're already locked).
with_lock_noop_grant() {
  local agent="$1" profile="$2"
  profile_apply_to_agent "$agent" "$profile" "$(state_get "$agent" base_profile observer)" 0
  state_set "$agent" current_profile "$profile"
  declare -F context_render >/dev/null 2>&1 && context_render "$agent" || true
}

_onboard_blob() {
  local agent="$1" host="$2" alias="$3" kh="$4" priv="$5"
  cat <<'HDR'
# ═══════════════════════════════════════════════════════════════════════
# Paste EVERYTHING below (including the code block) into your agent's chat.
# ═══════════════════════════════════════════════════════════════════════
HDR
  printf 'You have SSH access to the server "%s" as the restricted user "%s" (managed by llm2ssh).\n' "$host" "$agent"
  printf 'First, run this one-time setup:\n\n'
  printf '```bash\n'
  printf 'mkdir -p ~/.ssh && chmod 700 ~/.ssh\n'
  printf "cat > ~/.ssh/llm2ssh_%s <<'LLM2SSH_KEY'\n" "$agent"
  printf '%s\n' "$priv"
  printf 'LLM2SSH_KEY\n'
  printf 'chmod 600 ~/.ssh/llm2ssh_%s\n' "$agent"
  printf "grep -qs '^Host %s\$' ~/.ssh/config || cat >> ~/.ssh/config <<'LLM2SSH_CFG'\n" "$alias"
  printf '\nHost %s\n    HostName %s\n    User %s\n    IdentityFile ~/.ssh/llm2ssh_%s\n    IdentitiesOnly yes\n    StrictHostKeyChecking yes\n' \
         "$alias" "$host" "$agent" "$agent"
  printf 'LLM2SSH_CFG\n'
  if [[ -n "$kh" ]]; then
    printf "grep -qsF '%s' ~/.ssh/known_hosts || echo '%s' >> ~/.ssh/known_hosts\n" "$kh" "$kh"
  fi
  printf 'ssh %s llm2ssh-ctx    # shows your current permissions\n' "$alias"
  printf '```\n\n'
  printf 'From now on, run any server command with:  ssh %s '"'"'<command>'"'"'\n' "$alias"
  printf 'Your permissions can change over time — if a command is denied, run `ssh %s llm2ssh-ctx` and adapt.\n' "$alias"
  printf 'Never try to escalate privileges or work around a denial: every command is logged and visible to the owner.\n'
}
