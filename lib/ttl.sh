# shellcheck shell=bash
# lib/ttl.sh — the TTL garbage collector run by the gc timer.
# State is the source of truth (reboot-safe); the timer merely enforces it.

[[ -n "${_LLM2SSH_TTL_SOURCED:-}" ]] && return 0
_LLM2SSH_TTL_SOURCED=1

# event_log MESSAGE — append to the root-only event log (and syslog).
event_log() {
  ensure_dir "$LLM2SSH_LOG" 0700 "root:root"
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LLM2SSH_LOG/events.log"
  logger -t llm2ssh -p auth.info -- "$*" 2>/dev/null || true
  # Best-effort owner notification (M4 bot picks these up).
  declare -F notify_emit >/dev/null 2>&1 && notify_emit info "$*" || true
}

# cmd__gc — expire any grant whose deadline has passed. Idempotent; safe to run
# every minute. Frozen agents are skipped (nothing to regenerate).
cmd__gc() {
  local a now exp base cur kill_on
  now="$(now_epoch)"
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    [[ "$(state_get "$a" frozen 0)" == "1" ]] && continue
    exp="$(state_get "$a" expires_at 0)"
    [[ "$exp" -eq 0 ]] && continue
    [[ "$now" -lt "$exp" ]] && continue
    # Expired: fall back to the base profile.
    base="$(state_get "$a" base_profile observer)"
    cur="$(state_get "$a" current_profile observer)"
    kill_on="$(state_get "$a" kill_on_expiry 0)"
    profile_apply_to_agent "$a" "$base" "$base" 0
    state_set "$a" current_profile "$base"
    state_set "$a" expires_at 0
    state_set "$a" kill_on_expiry 0
    declare -F context_render >/dev/null 2>&1 && context_render "$a" || true
    if [[ "$kill_on" == "1" ]] && declare -F freeze_kill_sessions >/dev/null 2>&1; then
      freeze_kill_sessions "$a" || true
    fi
    event_log "TTL expired for '$a': '$cur' -> base '$base'$([[ "$kill_on" == 1 ]] && echo ' (sessions killed)')"
  done < <(list_agents)
  return 0
}
