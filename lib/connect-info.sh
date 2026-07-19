# shellcheck shell=bash
# lib/connect-info.sh — Mode A: give a LOCAL agent everything it needs to reach
# the server over SSH. Default is bring-your-own key (--github/--add-key), which
# never exposes a private key. Server-side keygen (--rotate-key) is the clearly
# warned fallback.

[[ -n "${_LLM2SSH_CONNECTINFO_SOURCED:-}" ]] && return 0
_LLM2SSH_CONNECTINFO_SOURCED=1

_detect_host() {
  local ip h
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.][0-9.]*\).*/\1/p' | head -n1 || true)"
  h="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  printf '%s' "${ip:-${h:-<server-host>}}"
}

_known_hosts_line() {
  local host="$1" pub="/etc/ssh/ssh_host_ed25519_key.pub"
  [[ -r "$pub" ]] || return 1
  printf '%s %s' "$host" "$(awk '{print $1" "$2}' "$pub")"
}

cmd_connect_info() {
  local agent="" json=0 add_src=() rotate=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --github)     add_src=(--github "${2:?}"); shift 2 ;;
      --add-key)    add_src=(--key "${2:?}"); shift 2 ;;
      --rotate-key) rotate=1; shift ;;
      --json)       json=1; shift ;;
      -*) die_usage "unknown flag for connect-info: $1" ;;
      *) agent="$1"; shift ;;
    esac
  done
  [[ -n "$agent" ]] || die_usage "usage: llm2ssh connect-info <agent> [--github U|--add-key K|--rotate-key] [--json]"
  require_agent_exists "$agent"

  local privkey=""
  if [[ ${#add_src[@]} -gt 0 ]]; then
    # Append the new key(s) to any existing ones and rewrite the root-owned file.
    { [[ -r "$LLM2SSH_KEYS/$agent" ]] && cat "$LLM2SSH_KEYS/$agent"; _keys_from_source "${add_src[@]}"; } \
      | write_agent_keys "$agent" >/dev/null
    declare -F sshd_reload >/dev/null 2>&1 && sshd_reload || true
  elif [[ "$rotate" -eq 1 ]]; then
    have_cmd ssh-keygen || die "ssh-keygen not found"
    warn "server-side key generation: the PRIVATE key will be printed ONCE below. Save it now; it is not stored on the server."
    local tmpd; tmpd="$(mktemp -d)"
    ssh-keygen -t ed25519 -N '' -C "llm2ssh:$agent:$(_detect_host)" -f "$tmpd/k" >/dev/null 2>&1 || die "keygen failed"
    { [[ -r "$LLM2SSH_KEYS/$agent" ]] && cat "$LLM2SSH_KEYS/$agent"; cat "$tmpd/k.pub"; } | write_agent_keys "$agent" >/dev/null
    privkey="$(cat "$tmpd/k")"
    rm -rf "$tmpd"
    declare -F sshd_reload >/dev/null 2>&1 && sshd_reload || true
  fi

  local host alias kh
  host="$(_detect_host)"
  alias="llm-$agent"
  kh="$(_known_hosts_line "$host" || true)"

  local nkeys_now=0
  [[ -r "$LLM2SSH_KEYS/$agent" ]] && nkeys_now="$(grep -c 'ssh-' "$LLM2SSH_KEYS/$agent" 2>/dev/null || echo 0)"

  if [[ "$json" -eq 1 ]]; then
    printf '{"agent":"%s","host":"%s","user":"%s","alias":"%s","keys":%s,"known_hosts":%s}\n' \
      "$agent" "$host" "$agent" "$alias" "$nkeys_now" "$(_json_str "${kh:-}")"
    return 0
  fi

  if [[ "$nkeys_now" -eq 0 ]]; then
    warn "agent '$agent' has no SSH key yet. Add one:"
    warn "  llm2ssh connect-info $agent --github <you>      # recommended (your existing key)"
    warn "  llm2ssh connect-info $agent --add-key 'ssh-ed25519 AAAA... you@laptop'"
    warn "  llm2ssh connect-info $agent --rotate-key        # generate one on the server (fallback)"
  fi

  # Everything below is the copy-paste deliverable -> stdout.
  cat <<EOF
# ── llm2ssh connect-info: agent '$agent' ─────────────────────────────
EOF
  if [[ -n "$privkey" ]]; then
    cat <<EOF

# ▶ PRIVATE KEY (shown ONCE — save to ~/.ssh/llm2ssh_$agent, chmod 600):
$privkey
EOF
  fi

  cat <<EOF

# ▶ ~/.ssh/config  (append this):
Host $alias
    HostName $host
    Port 22
    User $agent
    IdentityFile ~/.ssh/llm2ssh_$agent
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    ServerAliveInterval 15
    ServerAliveCountMax 4
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
EOF

  if [[ -n "$kh" ]]; then
    cat <<EOF

# ▶ ~/.ssh/known_hosts  (append this to avoid a TOFU prompt):
$kh
EOF
  fi

  cat <<EOF

# ▶ Add to your local agent's CLAUDE.md (the project it runs in):
## Remote server '$host' (managed by llm2ssh)
You can run commands on a remote server: \`ssh $alias '<command>'\`.
You are the restricted user '$agent'; your permissions are profile-based and
CHANGE OVER TIME. At the start of a session — and again whenever a command fails
with "permission denied" — run: \`ssh $alias llm2ssh-ctx\`. It prints your CURRENT
profile and exactly which commands are allowed. Trust it over this file. Never
try to escalate privileges or work around a denied command; all commands are
logged and reported to the owner.
# ─────────────────────────────────────────────────────────────────────
EOF
  return 0
}
