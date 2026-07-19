# shellcheck shell=bash
# lib/user.sh — create/configure/remove the restricted agent OS user.
# The agent is a normal unprivileged user in group `llm2ssh`; privilege comes
# ONLY from generated sudoers. No restricted shell (trivially escapable).

[[ -n "${_LLM2SSH_USER_SOURCED:-}" ]] && return 0
_LLM2SSH_USER_SOURCED=1

os_user_exists() { getent passwd "$1" >/dev/null 2>&1; }

agent_home() { getent passwd "$1" 2>/dev/null | cut -d: -f6; }

# user_create AGENT — idempotent. Locked password, member of llm2ssh, workspace.
user_create() {
  local agent="$1"
  if ! os_user_exists "$agent"; then
    useradd --create-home --shell /bin/bash --user-group \
            --comment "llm2ssh managed agent" "$agent" \
      || die "useradd failed for $agent"
  fi
  # No password login, ever.
  passwd -l "$agent" >/dev/null 2>&1 || true
  # Ensure membership in the marker group (drives sshd Match Group llm2ssh).
  usermod -aG "$LLM2SSH_GROUP" "$agent" || die "could not add $agent to $LLM2SSH_GROUP"
  # Lock down the home dir and provide a workspace for Mode B.
  local home; home="$(agent_home "$agent")"
  if [[ -n "$home" && -d "$home" ]]; then
    chmod 750 "$home" || true
    install -d -o "$agent" -g "$agent" -m 0750 "$home/workspace" 2>/dev/null || true
  fi
}

# user_set_groups AGENT [GROUP...] — declaratively set supplementary groups to
# exactly {llm2ssh} ∪ GROUPS. Replaces the full supplementary list.
user_set_groups() {
  local agent="$1"; shift || true
  local groups="$LLM2SSH_GROUP" g
  for g in "$@"; do
    # Skip groups that don't exist on this host rather than failing the grant.
    if getent group "$g" >/dev/null 2>&1; then
      groups+=",$g"
    else
      warn "group '$g' does not exist on this host; skipping (profile '${P_NAME:-?}')"
    fi
  done
  usermod -G "$groups" "$agent" || die "could not set groups for $agent"
}

# user_delete AGENT [--keep-home]
user_delete() {
  local agent="$1" keep="${2:-}"
  os_user_exists "$agent" || return 0
  if [[ "$keep" == "--keep-home" ]]; then
    userdel "$agent" 2>/dev/null || true
  else
    userdel -r "$agent" 2>/dev/null || true
  fi
}
