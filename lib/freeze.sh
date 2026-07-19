# shellcheck shell=bash
# lib/freeze.sh — the kill switch. freeze revokes all privilege and severs
# every session for an agent in under a second, with no network and no prompts.
# Order matters: remove privilege FIRST, then clean up.

[[ -n "${_LLM2SSH_FREEZE_SOURCED:-}" ]] && return 0
_LLM2SSH_FREEZE_SOURCED=1

freeze_flag() { printf '%s/agents/%s.frozen' "$LLM2SSH_RUN" "$1"; }

# freeze_kill_sessions AGENT — terminate every process attributable to the agent:
# processes running AS the agent, plus root-side children spawned via sudo
# (matched by loginuid, which survives sudo like auditd's auid). Reused by delete
# and TTL kill-on-expiry.
#
# Known limit (documented in docs/SECURITY.md #7): a process running as ROOT with
# its loginuid RESET/unset (e.g. a systemd service or at/cron job) is NOT killed —
# we cannot distinguish agent-planted root persistence from legitimate system
# daemons without killing PID 1's children. Planting such a process requires a
# prior root-capable grant (full), for which freeze/TTL are already best-effort.
freeze_kill_sessions() {
  local agent="$1" uid p lu pid
  uid="$(id -u "$agent" 2>/dev/null)" || return 0
  systemctl stop "llm2ssh-agent@$agent" 2>/dev/null || true
  loginctl terminate-user "$agent" 2>/dev/null || true
  # Kill by real uid first (a few passes in case of fork races).
  for _ in 1 2 3 4 5; do
    pkill -KILL -u "$agent" 2>/dev/null || true
    pgrep -u "$agent" >/dev/null 2>&1 || break
  done
  # Kill root-side descendants by loginuid == the agent's uid.
  for p in /proc/[0-9]*; do
    [[ -r "$p/loginuid" ]] || continue
    lu="$(cat "$p/loginuid" 2>/dev/null || echo '')"
    [[ "$lu" == "$uid" ]] || continue
    pid="${p#/proc/}"
    [[ "$pid" == "$$" ]] && continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  return 0
}

_freeze_one() {
  local agent="$1" reason="$2"
  # 1. Privilege gone immediately: sudo re-reads sudoers on every invocation.
  sudoers_remove "$agent"
  # 2. No new key logins.
  [[ -f "$LLM2SSH_KEYS/$agent" ]] && mv -f "$LLM2SSH_KEYS/$agent" "$LLM2SSH_KEYS/$agent.frozen"
  # 3. Block EVERY auth method. usermod -L does NOT block pubkey SSH; account
  #    expiry does. Date 1 == 1970-01-02, safely in the past.
  usermod --expiredate 1 "$agent" 2>/dev/null || true
  # 4. Sever running sessions and root-side sudo children.
  freeze_kill_sessions "$agent"
  # 5. Record: world-readable flag for enforcers + audited reason in state.
  ensure_dir "$LLM2SSH_RUN/agents" 0755 "root:root"
  : >"$(freeze_flag "$agent")"; chmod 0644 "$(freeze_flag "$agent")" 2>/dev/null || true
  state_set "$agent" frozen 1
  state_set "$agent" frozen_at "$(now_epoch)"
  state_set "$agent" frozen_reason "$reason"
  declare -F event_log >/dev/null 2>&1 && event_log "FROZEN '$agent'${reason:+ — $reason}" || true
}

cmd_freeze() {
  local target="" reason="" all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all=1; shift ;;
      --reason) reason="${2:-}"; shift 2 ;;
      -*) die_usage "unknown flag for freeze: $1" ;;
      *) target="$1"; shift ;;
    esac
  done

  if [[ "$all" -eq 1 ]]; then
    local a n=0
    while IFS= read -r a; do [[ -z "$a" ]] && continue; _freeze_one "$a" "$reason"; n=$((n+1)); done < <(list_agents)
    log "froze $n agent(s)"
    return 0
  fi
  [[ -n "$target" ]] || die_usage "usage: llm2ssh freeze <agent>|--all [--reason ...]"
  require_agent_exists "$target"
  _freeze_one "$target" "$reason"
  log "FROZEN '$target' — restore with: llm2ssh unfreeze $target"
  return 0
}

cmd_unfreeze() {
  local agent="${1:-}"; [[ -n "$agent" ]] || die_usage "usage: llm2ssh unfreeze <agent>"
  require_agent_exists "$agent"
  [[ "$(state_get "$agent" frozen 0)" == "1" ]] || { log "'$agent' is not frozen"; return 0; }

  # Restore keys and clear the account expiry.
  [[ -f "$LLM2SSH_KEYS/$agent.frozen" ]] && mv -f "$LLM2SSH_KEYS/$agent.frozen" "$LLM2SSH_KEYS/$agent"
  usermod --expiredate '' "$agent" 2>/dev/null || true

  # Re-check the TTL: never resurrect a grant that expired while frozen.
  local base cur exp now
  base="$(state_get "$agent" base_profile observer)"
  cur="$(state_get "$agent" current_profile observer)"
  exp="$(state_get "$agent" expires_at 0)"
  now="$(now_epoch)"
  if [[ "$exp" -ne 0 && "$now" -ge "$exp" ]]; then
    cur="$base"
    state_set "$agent" current_profile "$base"
    state_set "$agent" expires_at 0
  fi
  profile_apply_to_agent "$agent" "$cur" "$base" "$exp"

  state_set "$agent" frozen 0
  state_del "$agent" frozen_reason
  rm -f "$(freeze_flag "$agent")"
  declare -F context_render >/dev/null 2>&1 && context_render "$agent" || true
  declare -F event_log >/dev/null 2>&1 && event_log "UNFROZEN '$agent' -> '$cur'" || true
  log "unfroze '$agent' (profile: $cur)"
  return 0
}
