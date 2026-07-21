# shellcheck shell=bash
# lib/instructions.sh — `llm2ssh instructions`: prints the paste-into-your-agent
# text that teaches an agent how to work with an llm2ssh-managed server and how
# to REQUEST more access instead of trying to escalate. No privilege needed; the
# Telegram bot can send the same text via /instructions.

[[ -n "${_LLM2SSH_INSTRUCTIONS_SOURCED:-}" ]] && return 0
_LLM2SSH_INSTRUCTIONS_SOURCED=1

# cmd_instructions [agent] — print the agent playbook. If an agent name (and the
# `llm2ssh-ctx` alias) is known it is woven in; otherwise generic wording is used.
cmd_instructions() {
  local agent="${1:-}"
  cat <<'EOF'
# Working on this server (managed by llm2ssh)

You are operating as a restricted user on a server. Your permissions are managed
and can change over time. Follow these rules exactly.

## 1. Always check what you're allowed to do
Run `llm2ssh-ctx` at the start of a session — and again whenever a command is
denied. It prints your CURRENT profile, exactly which commands you may run, and
which extra profiles you can request. Trust it over any assumption.

## 2. Never escalate or work around a denial
If a command fails with "permission denied", that is policy, not a bug. Do NOT
try sudo tricks, alternative binaries, editing config, or any workaround. Every
command you run is logged and visible to the owner.

## 3. If you need more access, REQUEST it
Ask for a higher permission profile — the owner approves it (a Telegram button,
for a chosen duration) and you continue:

    llm2ssh-request <profile> --reason "one short line: why you need it"

- See the profiles you may request at the bottom of `llm2ssh-ctx`.
- The command waits up to ~3 minutes for the owner's decision, then returns.
- If it's granted, re-run whatever was blocked. If no approval channel is
  connected, it prints the exact command for the owner to run — surface that to
  them and continue once they've run it.
- You cannot request root ("full") — that is owner-only, by design.

## 4. Be a good tenant
Prefer read-only investigation first (`llm2ssh-ctx` lists the monitoring tools
installed — htop, df, sensors, docker ps, journalctl, etc.). Ask for the
smallest profile that unblocks you, with a TTL when the task is short-lived.
EOF
  # If we can enumerate requestable profiles, append them so the agent sees the
  # exact menu without an extra round-trip.
  if declare -F list_requestable_profiles >/dev/null 2>&1; then
    local rp rdesc first=1
    while IFS= read -r rp; do
      [[ -z "$rp" ]] && continue
      if [[ "$first" -eq 1 ]]; then printf '\n## Profiles you may request here\n'; first=0; fi
      rdesc="$(sed -n 's/^description[[:space:]]*//p' "$(profile_file "$rp")" 2>/dev/null | head -n1)"
      printf -- '- %s — %s\n' "$rp" "${rdesc:-}"
    done < <(list_requestable_profiles 2>/dev/null)
  fi
  [[ -n "$agent" ]] && printf '\n_(You are the user `%s`. Reach the server as: `ssh <alias> <command>` where the alias was set up at onboarding.)_\n' "$agent"
  return 0
}
