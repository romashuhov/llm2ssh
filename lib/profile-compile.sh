# shellcheck shell=bash
# lib/profile-compile.sh — compile the agent's active profile into the
# broker/agent-layer artifacts:
#   * /etc/llm2ssh/gate-policy/<agent>.json  — provider-agnostic hook policy
#   * provider settings (managed-settings.json, workspace settings) via the
#     active agent provider's agent_compile_settings (e.g. lib/agents/claude.sh)
# Derived mechanically from the SAME profile the sudoers layer uses, so the two
# can never drift.

[[ -n "${_LLM2SSH_PROFILECOMPILE_SOURCED:-}" ]] && return 0
_LLM2SSH_PROFILECOMPILE_SOURCED=1

gate_policy_file() { printf '%s/gate-policy/%s.json' "$LLM2SSH_ETC" "$1"; }

# policy_compile AGENT — regenerate the gate policy + provider settings.
# Called at the end of context_render, so it runs on every permission change.
policy_compile() {
  local agent="$1" cur
  have_cmd jq || return 0
  cur="$(state_get "$agent" current_profile observer)"
  # Ensure P_* reflect the current profile (context_render loaded it already, but
  # be defensive in case we're called standalone). P_SUDO/P_SUDO_ALL are read by
  # the provider's agent_compile_settings.
  # shellcheck disable=SC2034
  profile_load "$cur" 2>/dev/null || { P_NAME="$cur"; P_ASK=(); P_SUDO=(); P_SUDO_ALL=0; }

  local gp asks_json
  gp="$(gate_policy_file "$agent")"
  ensure_dir "$(dirname "$gp")" 0755 "root:root"
  if [[ "${#P_ASK[@]}" -gt 0 ]]; then
    asks_json="$(printf '%s\n' "${P_ASK[@]}" | jq -R . | jq -s .)"
  else
    asks_json='[]'
  fi
  jq -n --arg p "$P_NAME" --argjson ask "${asks_json:-[]}" \
     --argjson to 180 \
     '{profile:$p, default_action:"allow", approval_timeout_s:$to, ask:$ask}' \
    | atomic_write "$gp" 0644 "root:root"

  # Provider-specific settings (Claude Code managed-settings + workspace hints).
  declare -F agent_compile_settings >/dev/null 2>&1 && agent_compile_settings "$agent" || true
  return 0
}
