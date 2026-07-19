# shellcheck shell=bash
# lib/notify.sh — owner-notification emitter. Any root component drops a small
# JSON file into /run/llm2ssh/notify/; the Telegram bot's spool_watcher renders
# it to the owner. Only root/bot may write there (agents must NOT — otherwise a
# prompt-injected agent could phish the owner with fake alerts).

[[ -n "${_LLM2SSH_NOTIFY_SOURCED:-}" ]] && return 0
_LLM2SSH_NOTIFY_SOURCED=1

# notify_emit SEVERITY MESSAGE  (severity: info|warn|alert)
notify_emit() {
  local sev="${1:-info}" msg="${2:-}" dir="$LLM2SSH_RUN/notify"
  [[ -d "$dir" ]] || return 0        # no bot / spool -> nothing to do
  have_cmd jq || return 0
  local stamp tmp
  stamp="$(date +%s%N 2>/dev/null || date +%s)"
  tmp="$dir/.n-$stamp.$$.tmp"
  if jq -n --arg s "$sev" --arg m "$msg" --arg src "${LLM2SSH_COMPONENT:-cli}" \
        --argjson ts "$(date +%s)" \
        '{ts:$ts, severity:$s, source:$src, text:$m}' >"$tmp" 2>/dev/null; then
    chmod 0640 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dir/n-$stamp.$$.json"
  else
    rm -f "$tmp"
  fi
}
