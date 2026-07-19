# shellcheck shell=bash
# lib/doctor.sh — installation self-check. Base checks live here; later
# milestones add checks by defining doctor_extra_<name> functions, which
# cmd_doctor discovers and runs automatically.

[[ -n "${_LLM2SSH_DOCTOR_SOURCED:-}" ]] && return 0
_LLM2SSH_DOCTOR_SOURCED=1

_DOCTOR_FAILS=0
_DOCTOR_WARNS=0

# doctor_ok/doctor_warn/doctor_fail LABEL DETAIL
doctor_ok()   { printf '  [ ok ] %s\n' "$1" >&2; }
doctor_warn() { printf '  [warn] %s — %s\n' "$1" "${2:-}" >&2; _DOCTOR_WARNS=$((_DOCTOR_WARNS+1)); }
doctor_fail() { printf '  [FAIL] %s — %s\n' "$1" "${2:-}" >&2; _DOCTOR_FAILS=$((_DOCTOR_FAILS+1)); }

# doctor_check LABEL CMD... — run CMD, report ok/fail by exit status.
doctor_check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then doctor_ok "$label"; else doctor_fail "$label" "check failed"; fi
}

# _check_dir DIR EXPECTED_MODE — dir exists and mode matches (best-effort).
_check_dir_mode() {
  local dir="$1" want="$2" got
  [[ -d "$dir" ]] || { doctor_fail "dir $dir" "missing"; return; }
  got="$(stat -c '%a' "$dir" 2>/dev/null || echo '?')"
  if [[ "$got" == "$want" ]]; then
    doctor_ok "dir $dir ($got)"
  else
    doctor_warn "dir $dir" "mode $got, expected $want"
  fi
}

cmd_doctor() {
  printf 'llm2ssh doctor — %s\n' "$LLM2SSH_VERSION" >&2
  _DOCTOR_FAILS=0; _DOCTOR_WARNS=0

  printf 'base:\n' >&2
  doctor_check "OS is Debian/Ubuntu family" os_check
  if getent group "$LLM2SSH_GROUP" >/dev/null 2>&1; then
    doctor_ok "group $LLM2SSH_GROUP exists"
  else
    doctor_fail "group $LLM2SSH_GROUP" "missing (re-run install.sh)"
  fi
  _check_dir_mode "$LLM2SSH_ETC" 0755
  _check_dir_mode "$LLM2SSH_KEYS" 0755
  _check_dir_mode "$LLM2SSH_VAR" 0700
  _check_dir_mode "$LLM2SSH_LOG" 0700
  _check_dir_mode "$LLM2SSH_AGENTS" 0700

  # Critical invariant: no managed agent may be in the docker group (== root).
  if getent group docker >/dev/null 2>&1; then
    local dmembers="" a
    dmembers="$(getent group docker | awk -F: '{print $4}')"
    local bad=""
    while IFS= read -r a; do
      [[ -z "$a" ]] && continue
      if [[ ",$dmembers," == *",$a,"* ]]; then bad="$bad $a"; fi
    done < <(list_agents)
    if [[ -n "$bad" ]]; then
      doctor_fail "docker group" "managed agent(s) in docker group (== root):$bad"
    else
      doctor_ok "no managed agent in docker group"
    fi
  fi

  # Run milestone-provided checks (defined by other lib modules).
  local fn
  for fn in $(declare -F | awk '{print $3}' | grep '^doctor_extra_' || true); do
    printf '%s:\n' "${fn#doctor_extra_}" >&2
    "$fn"
  done

  printf 'result: %d failure(s), %d warning(s)\n' "$_DOCTOR_FAILS" "$_DOCTOR_WARNS" >&2
  [[ "$_DOCTOR_FAILS" -eq 0 ]]
}

cmd_list() {
  local json=0 a
  [[ "${1:-}" == "--json" ]] && json=1
  if [[ "$json" -eq 1 ]]; then
    local first=1
    printf '['
    while IFS= read -r a; do
      [[ -z "$a" ]] && continue
      [[ "$first" -eq 1 ]] || printf ','
      first=0
      printf '{"agent":"%s","profile":"%s","frozen":%s}' \
        "$a" "$(state_get "$a" current_profile observer)" \
        "$([[ "$(state_get "$a" frozen 0)" == "1" ]] && echo true || echo false)"
    done < <(list_agents)
    printf ']\n'
    return 0
  fi
  local any=0
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    any=1
    printf '%-20s profile=%-14s %s\n' \
      "$a" "$(state_get "$a" current_profile observer)" \
      "$([[ "$(state_get "$a" frozen 0)" == "1" ]] && echo '[FROZEN]' || echo '')"
  done < <(list_agents)
  [[ "$any" -eq 0 ]] && log "no managed agents yet (create one: llm2ssh create <agent>)"
  return 0
}
