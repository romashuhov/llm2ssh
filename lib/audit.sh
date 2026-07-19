# shellcheck shell=bash
# lib/audit.sh — per-agent command audit.
#   1. sudo layer (always): per-agent logfile via Defaults (set in sudoers.sh).
#   2. execve layer (auditd): rules keyed on auid (login uid), which survives
#      su/sudo — so even root-side execs after `sudo` are attributed to the agent.
# `llm2ssh log` merges both into one timeline.

[[ -n "${_LLM2SSH_AUDIT_SOURCED:-}" ]] && return 0
_LLM2SSH_AUDIT_SOURCED=1

audit_rules_file() { printf '%s/llm2ssh-%s.rules' "$LLM2SSH_AUDITD" "$1"; }
audit_key() { printf 'llm2ssh-%s' "$1"; }
sudo_logfile() { printf '%s/sudo-%s.log' "$LLM2SSH_LOG" "$1"; }

auditd_available() { have_cmd auditctl || have_cmd augenrules; }

# audit_install AGENT — write and load execve rules for the agent's auid.
# Best-effort loading: a container/kernel without audit support still gets the
# rules file (documents intent) but a loud warning if it can't be loaded.
audit_install() {
  local agent="$1" uid key file
  uid="$(id -u "$agent" 2>/dev/null)" || return 0
  key="$(audit_key "$agent")"
  file="$(audit_rules_file "$agent")"
  if ! auditd_available; then
    warn "auditd not installed — non-sudo command audit is DISABLED for '$agent'"
    return 0
  fi
  ensure_dir "$LLM2SSH_AUDITD" 0750 "root:root"
  cat >"$file" <<EOF
# Managed by llm2ssh — execve audit for agent '$agent' (auid=$uid). DO NOT EDIT.
-a always,exit -F arch=b64 -S execve -S execveat -F auid=$uid -F key=$key
-a always,exit -F arch=b32 -S execve -S execveat -F auid=$uid -F key=$key
EOF
  chmod 0640 "$file"
  # Load. Never use immutable mode (-e 2): it would require a reboot to change.
  if have_cmd augenrules; then
    augenrules --load >/dev/null 2>&1 || warn "augenrules --load failed (audit rules written but not active)"
  elif have_cmd auditctl; then
    auditctl -R "$file" >/dev/null 2>&1 || warn "auditctl load failed (audit rules written but not active)"
  fi
}

# audit_remove AGENT — drop the rules file and reload.
audit_remove() {
  local file; file="$(audit_rules_file "$1")"
  [[ -f "$file" ]] || return 0
  rm -f "$file"
  have_cmd augenrules && augenrules --load >/dev/null 2>&1 || true
}

doctor_extra_audit() {
  if ! auditd_available; then
    doctor_warn "auditd" "not installed — non-sudo command audit disabled"
    return
  fi
  if have_cmd systemctl && systemctl is-active auditd >/dev/null 2>&1; then
    doctor_ok "auditd active"
  else
    doctor_warn "auditd" "installed but not active"
  fi
}

# cmd_log AGENT [--since S] [--follow] [--sudo-only] [--denied] [--json]
cmd_log() {
  local agent="" since="" follow=0 sudo_only=0 denied=0 json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:?}"; shift 2 ;;
      --follow|-f) follow=1; shift ;;
      --sudo-only) sudo_only=1; shift ;;
      --denied) denied=1; shift ;;
      --json) json=1; shift ;;
      -*) die_usage "unknown flag for log: $1" ;;
      *) agent="$1"; shift ;;
    esac
  done
  [[ -n "$agent" ]] || die_usage "usage: llm2ssh log <agent> [--since 1h] [--follow] [--sudo-only] [--denied] [--json]"
  require_agent_exists "$agent"
  local slog; slog="$(sudo_logfile "$agent")"

  if [[ "$follow" -eq 1 ]]; then
    [[ -f "$slog" ]] || { log "no sudo activity yet for '$agent' (waiting)…"; : >"$slog" 2>/dev/null || true; }
    exec tail -n 20 -f "$slog"
  fi

  local had=0
  # --- sudo layer ---
  if [[ -f "$slog" ]]; then
    local lines
    if [[ "$denied" -eq 1 ]]; then
      lines="$(grep -i 'command not allowed\|a password is required' "$slog" 2>/dev/null || true)"
    else
      lines="$(cat "$slog" 2>/dev/null || true)"
    fi
    if [[ -n "$lines" ]]; then
      had=1
      if [[ "$json" -eq 1 ]]; then
        while IFS= read -r l; do
          [[ -z "$l" ]] && continue
          printf '{"layer":"sudo","line":%s}\n' "$(_json_str "$l")"
        done <<<"$lines"
      else
        printf '== sudo (%s) ==\n' "$agent" >&2
        printf '%s\n' "$lines"
      fi
    fi
  fi

  # --- execve layer (auditd) ---
  if [[ "$sudo_only" -eq 0 ]] && have_cmd ausearch; then
    local ausearch_args=(-k "$(audit_key "$agent")" -i)
    [[ -n "$since" ]] && ausearch_args+=(-ts "$(_since_to_ausearch "$since")")
    local aout
    aout="$(ausearch "${ausearch_args[@]}" 2>/dev/null | grep -E 'type=EXECVE|proctitle=' || true)"
    if [[ -n "$aout" ]]; then
      had=1
      if [[ "$json" -eq 1 ]]; then
        while IFS= read -r l; do printf '{"layer":"execve","line":%s}\n' "$(_json_str "$l")"; done <<<"$aout"
      else
        printf '== execve (%s) ==\n' "$agent" >&2
        printf '%s\n' "$aout"
      fi
    fi
  fi

  if [[ "$had" -eq 0 ]]; then
    [[ "$json" -eq 1 ]] && printf '' || log "no audit data yet for '$agent'"
  fi
  return 0
}

# Minimal JSON string escaper (quotes + backslashes + control chars).
_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"
  printf '"%s"' "$s"
}

# _since_to_ausearch 1h|30m|2d -> "MM/DD/YYYY HH:MM:SS" (best-effort via date).
_since_to_ausearch() {
  local spec="$1" secs
  case "$spec" in
    *h) secs=$(( ${spec%h} * 3600 )) ;;
    *m) secs=$(( ${spec%m} * 60 )) ;;
    *d) secs=$(( ${spec%d} * 86400 )) ;;
    *s) secs=${spec%s} ;;
    *) secs=3600 ;;
  esac
  date -d "@$(( $(date +%s) - secs ))" '+%m/%d/%Y %H:%M:%S' 2>/dev/null || echo "recent"
}
