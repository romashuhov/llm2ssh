# shellcheck shell=bash
# lib/ssh.sh — sshd drop-in management and effective-config verification.
# The drop-in itself is installed by install.sh (static content in
# templates/sshd-match.conf). Here we provide reload + verification used by
# key management, create, and doctor.

[[ -n "${_LLM2SSH_SSH_SOURCED:-}" ]] && return 0
_LLM2SSH_SSH_SOURCED=1

SSHD_DROPIN="${LLM2SSH_SSHDD}/60-llm2ssh.conf"

sshd_present() { have_cmd sshd; }

# sshd -t/-T need the privilege-separation dir even for a config check.
_sshd_ensure_privsep() { [[ -d /run/sshd ]] || mkdir -p /run/sshd 2>/dev/null || true; }

# sshd_reload — validate then reload (service name differs across distros).
sshd_reload() {
  sshd_present || return 0
  _sshd_ensure_privsep
  if ! sshd -t 2>/dev/null; then
    warn "sshd -t failed; NOT reloading (fix sshd config first)"
    return 1
  fi
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || \
    { warn "could not reload the ssh service"; return 1; }
  return 0
}

# sshd_effective_ok AGENT — verify the drop-in actually applies to this agent
# (it won't if the main sshd_config lacks an Include for sshd_config.d, or a
# later global directive overrides it). This is the M7 fix: sshd -t alone can
# pass while the drop-in is silently ignored.
sshd_effective_ok() {
  local agent="$1" out
  sshd_present || return 0
  _sshd_ensure_privsep
  out="$(sshd -T -C "user=$agent,host=probe.invalid,addr=203.0.113.1" 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  grep -qi '^authorizedkeysfile .*[/ ]etc/llm2ssh/keys/' <<<"$out" \
    && grep -qi '^passwordauthentication no' <<<"$out"
}

doctor_extra_ssh() {
  if ! sshd_present; then
    doctor_warn "sshd" "not installed — SSH access (Mode A/B) unavailable until openssh-server is present"
    return
  fi
  _sshd_ensure_privsep
  if [[ -f "$SSHD_DROPIN" ]]; then doctor_ok "sshd drop-in present"; else doctor_warn "sshd drop-in" "missing"; fi
  if sshd -t 2>/dev/null; then doctor_ok "sshd -t"; else doctor_fail "sshd -t" "config invalid"; fi
  # Per-agent effective check.
  local a
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    if sshd_effective_ok "$a"; then
      doctor_ok "sshd effective for $a"
    else
      doctor_fail "sshd effective for $a" "drop-in not applied — ensure main sshd_config has 'Include /etc/ssh/sshd_config.d/*.conf'"
    fi
  done < <(list_agents)
}
