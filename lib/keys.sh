# shellcheck shell=bash
# lib/keys.sh — manage an agent's SSH public keys. Keys live in the ROOT-OWNED
# file /etc/llm2ssh/keys/<agent> (AuthorizedKeysFile target), so the agent can
# never add its own key to persist access. M2 adds the sshd Match drop-in.

[[ -n "${_LLM2SSH_KEYS_SOURCED:-}" ]] && return 0
_LLM2SSH_KEYS_SOURCED=1

cmd_key() {
  local action="${1:-}"; shift || true
  case "$action" in
    add)    _cmd_key_add "$@" ;;
    list)   _cmd_key_list "$@" ;;
    remove) _cmd_key_remove "$@" ;;
    *) die_usage "usage: llm2ssh key add|list|remove <agent> ..." ;;
  esac
}

_cmd_key_add() {
  local agent="" src=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --github|--key|--key-file) src=("$1" "${2:?}"); shift 2 ;;
      -*) die_usage "unknown flag: $1" ;;
      *) agent="$1"; shift ;;
    esac
  done
  [[ -n "$agent" && ${#src[@]} -gt 0 ]] || die_usage "usage: llm2ssh key add <agent> --github U|--key K|--key-file F"
  require_agent_exists "$agent"
  local existing="" new
  [[ -r "$LLM2SSH_KEYS/$agent" ]] && existing="$(cat "$LLM2SSH_KEYS/$agent")"
  new="$(_keys_from_source "${src[@]}")"
  local n
  n="$(printf '%s\n%s\n' "$existing" "$new" | write_agent_keys "$agent")"
  declare -F sshd_reload >/dev/null 2>&1 && sshd_reload || true
  # If the root-owned AuthorizedKeysFile drop-in isn't actually in effect, the
  # agent's own ~/.ssh/authorized_keys would be honored — warn loudly.
  if declare -F sshd_effective_ok >/dev/null 2>&1 && have_cmd sshd; then
    sshd_effective_ok "$agent" || warn "sshd is NOT reading /etc/llm2ssh/keys/$agent — add 'Include /etc/ssh/sshd_config.d/*.conf' to sshd_config and reload, or the agent can self-persist keys"
  fi
  log "agent '$agent' now has $n key(s)"
}

_cmd_key_list() {
  local agent="${1:-}"; [[ -n "$agent" ]] || die_usage "usage: llm2ssh key list <agent>"
  require_agent_exists "$agent"
  local f="$LLM2SSH_KEYS/$agent" i=0 line
  [[ -r "$f" ]] || { log "no keys for '$agent'"; return 0; }
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    i=$((i+1))
    # print index + comment/last field for readability
    printf '%2d  %s\n' "$i" "$(printf '%s' "$line" | awk '{print $(NF)}')"
  done <"$f"
  [[ "$i" -eq 0 ]] && log "no keys for '$agent'"
}

_cmd_key_remove() {
  local agent="" idx="" all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all=1; shift ;;
      *) if [[ -z "$agent" ]]; then agent="$1"; else idx="$1"; fi; shift ;;
    esac
  done
  [[ -n "$agent" ]] || die_usage "usage: llm2ssh key remove <agent> <index>|--all"
  require_agent_exists "$agent"
  local f="$LLM2SSH_KEYS/$agent"
  if [[ "$all" -eq 1 ]]; then
    printf '' | atomic_write "$f" 0644 "root:root"
    declare -F sshd_reload >/dev/null 2>&1 && sshd_reload || true
    log "removed all keys for '$agent'"
    return 0
  fi
  [[ "$idx" =~ ^[0-9]+$ ]] || die_usage "index must be a number (see: llm2ssh key list $agent)"
  [[ -r "$f" ]] || die_notfound "no keys for '$agent'"
  local tmp i=0 line
  tmp="$(dirname "$f")/.$(basename "$f").tmp.$$"
  : >"$tmp"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    i=$((i+1))
    [[ "$i" -eq "$idx" ]] && continue
    printf '%s\n' "$line" >>"$tmp"
  done <"$f"
  chmod 0644 "$tmp"; chown root:root "$tmp" 2>/dev/null || true; mv -f "$tmp" "$f"
  declare -F sshd_reload >/dev/null 2>&1 && sshd_reload || true
  log "removed key #$idx from '$agent'"
}
