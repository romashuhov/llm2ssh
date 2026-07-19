# shellcheck shell=bash
# lib/grant.sh — create/grant/revoke/status/delete. Ties together profiles,
# sudoers, the OS user, keys, and per-agent state.

[[ -n "${_LLM2SSH_GRANT_SOURCED:-}" ]] && return 0
_LLM2SSH_GRANT_SOURCED=1

# ttl_to_seconds SPEC -> integer seconds (e.g. 4h, 30m, 2d, 90s). Empty -> 0.
ttl_to_seconds() {
  local s="$1"
  [[ -z "$s" ]] && { printf 0; return 0; }
  [[ "$s" =~ ^([0-9]+)([smhd])$ ]] || { die_usage "bad --ttl '$s' (use e.g. 30m, 4h, 2d)"; }
  local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
  case "$u" in
    s) printf '%s' "$n" ;;
    m) printf '%s' "$((n*60))" ;;
    h) printf '%s' "$((n*3600))" ;;
    d) printf '%s' "$((n*86400))" ;;
  esac
}

# write_agent_keys AGENT  (public key text on stdin) — root-owned keys file.
# Each key gets a restrict,pty prefix (defense in depth even if sshd drop-in lost).
write_agent_keys() {
  local agent="$1" line n=0 out
  out=""
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Only accept plausible SSH public keys.
    case "$line" in
      ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-*\ *|ssh-dss\ *)
        out+="restrict,pty $line"$'\n'; n=$((n+1)) ;;
      restrict*\ ssh-*|command=*\ ssh-*)
        out+="$line"$'\n'; n=$((n+1)) ;;   # already-prefixed line, keep as-is
      *) warn "ignoring line that is not an SSH public key" ;;
    esac
  done
  ensure_dir "$LLM2SSH_KEYS" 0755 "root:root"
  printf '%s' "$out" | atomic_write "$LLM2SSH_KEYS/$agent" 0644 "root:root"
  printf '%s' "$n"
}

# _keys_from_source --github U | --key K | --key-file F  -> key text on stdout.
_keys_from_source() {
  case "${1:-}" in
    --github) [[ -n "${2:-}" ]] || die_usage "--github needs a username"
      have_cmd curl || die "curl required for --github"
      curl -fsSL "https://github.com/$2.keys" || die "could not fetch keys for github user '$2'" ;;
    --key) [[ -n "${2:-}" ]] || die_usage "--key needs a key string"; printf '%s\n' "$2" ;;
    --key-file) [[ -r "${2:-}" ]] || die_usage "--key-file not readable: '${2:-}'"; cat "$2" ;;
    "") : ;;  # no key source
    *) die_usage "unknown key source '$1'" ;;
  esac
}

# _write_services_allow AGENT CSV — validate + persist the unit allowlist.
_write_services_allow() {
  local agent="$1" csv="$2" file unit
  file="$(agent_dir "$agent")/services.allow"
  ensure_dir "$(dirname "$file")" 0700 "root:root"
  local tmp; tmp="$(dirname "$file")/.services.allow.tmp.$$"
  : >"$tmp"
  local IFS=,
  for unit in $csv; do
    unit="${unit#"${unit%%[![:space:]]*}"}"; unit="${unit%"${unit##*[![:space:]]}"}"
    [[ -z "$unit" ]] && continue
    [[ "$unit" =~ ^[A-Za-z0-9_.@-]+$ ]] || { rm -f "$tmp"; die_usage "invalid service unit name: '$unit'"; }
    printf '%s\n' "$unit" >>"$tmp"
  done
  chmod 0644 "$tmp"; mv -f "$tmp" "$file"
}

# profile_apply_to_agent AGENT PROFILE BASE EXPIRES — load, set groups, sudoers.
profile_apply_to_agent() {
  local agent="$1" profile="$2" base="$3" expires="$4"
  profile_load "$profile"
  user_set_groups "$agent" ${P_GROUPS[@]+"${P_GROUPS[@]}"}
  sudoers_apply "$agent" "$base" "$(fmt_epoch "$expires")"
}

cmd_create() {
  local agent="" profile="observer" ksrc=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="${2:?}"; shift 2 ;;
      --github|--key|--key-file) ksrc=("$1" "${2:?}"); shift 2 ;;
      -*) die_usage "unknown flag for create: $1" ;;
      *) [[ -z "$agent" ]] && { agent="$1"; shift; } || die_usage "unexpected arg: $1" ;;
    esac
  done
  [[ -n "$agent" ]] || die_usage "usage: llm2ssh create <agent> [--profile P] [--github U|--key K|--key-file F]"
  require_valid_agent_name "$agent"
  profile_file "$profile" >/dev/null || die_notfound "no such profile: '$profile'"

  os_check
  if agent_exists "$agent"; then
    warn "agent '$agent' already exists — converging its configuration"
  fi
  user_create "$agent"
  state_init "$agent"
  state_set "$agent" base_profile "$profile"
  state_set "$agent" current_profile "$profile"
  state_set "$agent" created_at "$(now_epoch)"
  state_set "$agent" expires_at 0
  state_set "$agent" frozen 0

  # Keys (optional at create; add later with `llm2ssh key add`).
  local nkeys=0
  if [[ ${#ksrc[@]} -gt 0 ]]; then
    nkeys="$(_keys_from_source "${ksrc[@]}" | write_agent_keys "$agent")"
  else
    # Ensure an (empty) root-owned keys file exists so sshd has a target.
    [[ -f "$LLM2SSH_KEYS/$agent" ]] || printf '' | atomic_write "$LLM2SSH_KEYS/$agent" 0644 "root:root"
  fi

  profile_apply_to_agent "$agent" "$profile" "$profile" 0

  # Command audit (execve via auditd) + live context for Mode A/B.
  declare -F audit_install >/dev/null 2>&1 && audit_install "$agent" || true
  declare -F context_render >/dev/null 2>&1 && context_render "$agent" || true

  # Warn if the sshd hardening won't actually apply to this agent.
  if declare -F sshd_effective_ok >/dev/null 2>&1 && have_cmd sshd; then
    sshd_effective_ok "$agent" || warn "sshd hardening not effective for '$agent' — ensure sshd_config has 'Include /etc/ssh/sshd_config.d/*.conf' then: systemctl reload ssh"
  fi

  log "created agent '$agent' (profile: $profile, keys: $nkeys)"
  [[ "$nkeys" -eq 0 ]] && log "add a key: llm2ssh key add $agent --github <user>   (or --key '<pubkey>')"
  return 0
}

cmd_grant() {
  local agent="" profile="" ttl="" services="" kill_on_expiry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ttl) ttl="${2:?}"; shift 2 ;;
      --services) services="${2:?}"; shift 2 ;;
      --kill-on-expiry) kill_on_expiry=1; shift ;;
      -*) die_usage "unknown flag for grant: $1" ;;
      *) if [[ -z "$agent" ]]; then agent="$1"; elif [[ -z "$profile" ]]; then profile="$1"; else die_usage "unexpected arg: $1"; fi; shift ;;
    esac
  done
  [[ -n "$agent" && -n "$profile" ]] || die_usage "usage: llm2ssh grant <agent> <profile> [--ttl 4h] [--services a,b] [--kill-on-expiry] [--yes]"
  require_agent_exists "$agent"
  [[ "$(state_get "$agent" frozen 0)" == "1" ]] && die "agent '$agent' is frozen; run 'llm2ssh unfreeze $agent' first"

  # Load to validate and to inspect flags (needs-services / sudo-all / warns).
  profile_load "$profile"

  if [[ "$P_NEEDS_SERVICES" -eq 1 ]]; then
    [[ -n "$services" ]] || die_usage "profile '$profile' requires --services <unit,...>"
    _write_services_allow "$agent" "$services"
  fi

  if [[ "$P_SUDO_ALL" -eq 1 ]]; then
    warn "'$profile' is UNRESTRICTED ROOT (sudo ALL). The agent can do anything."
    if ! confirm "Type the agent name to confirm granting full root:" "$agent"; then
      die "aborted"
    fi
    [[ -z "$ttl" ]] && warn "no --ttl set on a full grant — consider: llm2ssh grant $agent full --ttl 1h --kill-on-expiry"
  fi

  local base expires=0 secs
  base="$(state_get "$agent" base_profile observer)"
  if [[ -n "$ttl" ]]; then
    secs="$(ttl_to_seconds "$ttl")"
    expires="$(( $(now_epoch) + secs ))"
  fi

  profile_apply_to_agent "$agent" "$profile" "$base" "$expires"

  state_set "$agent" current_profile "$profile"
  state_set "$agent" granted_at "$(now_epoch)"
  state_set "$agent" expires_at "$expires"
  state_set "$agent" kill_on_expiry "$kill_on_expiry"

  # Refresh the live agent-context file if that machinery is present (M3).
  declare -F context_render >/dev/null 2>&1 && context_render "$agent" || true

  local w
  for w in ${P_WARN[@]+"${P_WARN[@]}"}; do warn "$w"; done
  if [[ "$expires" -ne 0 ]]; then
    log "granted '$profile' to '$agent' — expires $(fmt_epoch "$expires")"
  else
    log "granted '$profile' to '$agent' (no expiry)"
  fi
  return 0
}

cmd_revoke() {
  local agent="${1:-}"; [[ -n "$agent" ]] || die_usage "usage: llm2ssh revoke <agent>"
  require_agent_exists "$agent"
  [[ "$(state_get "$agent" frozen 0)" == "1" ]] && die "agent '$agent' is frozen; use 'llm2ssh unfreeze $agent'"
  local base; base="$(state_get "$agent" base_profile observer)"
  profile_apply_to_agent "$agent" "$base" "$base" 0
  state_set "$agent" current_profile "$base"
  state_set "$agent" expires_at 0
  state_set "$agent" kill_on_expiry 0
  declare -F context_render >/dev/null 2>&1 && context_render "$agent" || true
  log "revoked '$agent' back to base profile '$base'"
  return 0
}

cmd_status() {
  local json=0 agent=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      *) agent="$1"; shift ;;
    esac
  done

  _status_one_json() {
    local a="$1" now exp rem
    now="$(now_epoch)"; exp="$(state_get "$a" expires_at 0)"
    rem=0; [[ "$exp" -ne 0 ]] && rem="$(( exp - now ))"
    printf '{"agent":"%s","base_profile":"%s","current_profile":"%s","frozen":%s,"expires_at":%s,"remaining_s":%s}' \
      "$a" "$(state_get "$a" base_profile observer)" "$(state_get "$a" current_profile observer)" \
      "$([[ "$(state_get "$a" frozen 0)" == "1" ]] && echo true || echo false)" \
      "$exp" "$rem"
  }

  if [[ "$json" -eq 1 ]]; then
    if [[ -n "$agent" ]]; then require_agent_exists "$agent"; _status_one_json "$agent"; printf '\n'
    else
      printf '['; local first=1 a
      while IFS= read -r a; do [[ -z "$a" ]] && continue; [[ $first -eq 1 ]] || printf ','; first=0; _status_one_json "$a"; done < <(list_agents)
      printf ']\n'
    fi
    return 0
  fi

  _status_one_human() {
    local a="$1" exp rem sessions
    exp="$(state_get "$a" expires_at 0)"
    printf 'agent      %s\n' "$a"
    printf 'profile    %s   (base: %s)%s\n' \
      "$(state_get "$a" current_profile observer)" "$(state_get "$a" base_profile observer)" \
      "$([[ "$(state_get "$a" frozen 0)" == "1" ]] && echo '   [FROZEN]' || echo '')"
    if [[ "$exp" -ne 0 ]]; then
      rem="$(( exp - $(now_epoch) ))"
      printf 'expires    %s (in %ds)\n' "$(fmt_epoch "$exp")" "$rem"
    else
      printf 'expires    never\n'
    fi
    if [[ -r "$LLM2SSH_KEYS/$a" ]]; then
      printf 'keys       %s\n' "$(grep -c 'ssh-' "$LLM2SSH_KEYS/$a" 2>/dev/null || echo 0)"
    fi
    sessions="$(who 2>/dev/null | awk -v u="$a" '$1==u' | wc -l | tr -d ' ')"
    printf 'sessions   %s\n' "${sessions:-0}"
  }

  if [[ -n "$agent" ]]; then require_agent_exists "$agent"; _status_one_human "$agent"
  else
    local any=0 a
    while IFS= read -r a; do [[ -z "$a" ]] && continue; any=1; _status_one_human "$a"; echo; done < <(list_agents)
    [[ "$any" -eq 0 ]] && log "no managed agents yet"
  fi
  return 0
}

cmd_delete() {
  local agent="" keep=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-home) keep="--keep-home"; shift ;;
      -*) die_usage "unknown flag for delete: $1" ;;
      *) agent="$1"; shift ;;
    esac
  done
  [[ -n "$agent" ]] || die_usage "usage: llm2ssh delete <agent> [--keep-home] [--yes]"
  require_agent_exists "$agent"
  if ! confirm "Delete agent '$agent' (user, keys, sudoers, state)?"; then die "aborted"; fi

  # Kill anything running as the agent (freeze provides the thorough version).
  if declare -F freeze_kill_sessions >/dev/null 2>&1; then
    freeze_kill_sessions "$agent" || true
  else
    pkill -KILL -u "$agent" 2>/dev/null || true
  fi
  sudoers_remove "$agent"
  rm -f "$LLM2SSH_KEYS/$agent" "$LLM2SSH_KEYS/$agent.frozen"
  # Audit rule cleanup (M2) if present.
  declare -F audit_remove >/dev/null 2>&1 && audit_remove "$agent" || true
  rm -f "$LLM2SSH_RUN/agents/$agent.frozen" 2>/dev/null || true
  user_delete "$agent" "$keep"
  rm -rf "$(agent_dir "$agent")"
  log "deleted agent '$agent'"
  return 0
}
