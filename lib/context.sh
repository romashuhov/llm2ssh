# shellcheck shell=bash
# lib/context.sh — render the agent's LIVE permission context. The agent reads
# it over SSH via `llm2ssh-ctx`. It contains only a description of the agent's
# OWN permissions (not sensitive), so the file is world-readable. Regenerated on
# every permission change so Mode A always sees current rules with zero client
# action. M3 enriches this with Claude-specific guidance.

[[ -n "${_LLM2SSH_CONTEXT_SOURCED:-}" ]] && return 0
_LLM2SSH_CONTEXT_SOURCED=1

context_file() { printf '%s/context/%s.md' "$LLM2SSH_ETC" "$1"; }

# context_render AGENT — (re)generate the agent's context markdown.
# Loads the agent's current profile; safe to call at the end of a mutation.
context_render() {
  local agent="$1" cur frozen exp
  cur="$(state_get "$agent" current_profile observer)"
  frozen="$(state_get "$agent" frozen 0)"
  exp="$(state_get "$agent" expires_at 0)"

  # Load the current profile to enumerate what it allows (best-effort).
  if ! profile_load "$cur" 2>/dev/null; then
    P_NAME="$cur"; P_DESC=""; P_SUDO=(); P_WARN=(); P_SUDO_ALL=0
  fi

  ensure_dir "$(dirname "$(context_file "$agent")")" 0755 "root:root"
  {
    printf '# llm2ssh context for `%s`\n\n' "$agent"
    printf '_Generated %s. This is the authoritative, live view of your permissions._\n\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
    if [[ "$frozen" == "1" ]]; then
      printf '## STATUS: FROZEN\n\nAll privileges are revoked and sessions are being terminated. Stop work.\n\n'
    fi
    printf '## Current profile: `%s`\n\n%s\n\n' "$P_NAME" "${P_DESC:-}"
    if [[ "$exp" -ne 0 ]]; then
      printf 'This grant EXPIRES at %s; afterwards you fall back to a lower profile.\n\n' "$(fmt_epoch "$exp")"
    fi
    if [[ "${P_SUDO_ALL:-0}" -eq 1 ]]; then
      printf '## What you may do\n\nUNRESTRICTED ROOT: `sudo` any command.\n\n'
    elif [[ "${#P_SUDO[@]}" -gt 0 ]]; then
      printf '## Commands you may run with sudo (NOPASSWD)\n\n'
      local s; for s in "${P_SUDO[@]}"; do printf -- '- `sudo %s`\n' "$s"; done
      printf '\n'
    else
      printf '## Commands you may run with sudo\n\nNone. You have a normal unprivileged shell (you can still read /proc, run ps/df/free/ss, etc.).\n\n'
    fi
    local w
    for w in ${P_WARN[@]+"${P_WARN[@]}"}; do printf '> NOTE: %s\n' "$w"; done
    printf '\n## Rules\n\n'
    printf '1. Do NOT try to escalate privileges or work around a denied command. Denials are policy, not bugs.\n'
    printf '2. If a command is denied, re-run `llm2ssh-ctx` — your profile may have changed — then adapt.\n'
    printf '3. All your commands are logged and visible to the owner.\n'
    # List a few monitoring tools that are actually installed, so the agent
    # knows to reach for them (most need no sudo).
    local htools="" t
    for t in htop iostat pidstat lsof ncdu sensors lspci lsusb lshw ss dig tree; do
      have_cmd "$t" && htools+=" $t"
    done
    [[ -n "$htools" ]] && printf '\n## Monitoring tools available\n\nInstalled and ready (no sudo needed for most):%s.\n' "$htools"
  } | atomic_write "$(context_file "$agent")" 0644 "root:root"

  # Regenerate the derived broker/agent-layer policy from the same profile (M3).
  declare -F policy_compile >/dev/null 2>&1 && policy_compile "$agent" || true
}
