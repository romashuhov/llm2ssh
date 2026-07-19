# shellcheck shell=bash
# bot/handlers.sh — command handlers. Each echoes reply TEXT (plain, never a
# shell). Composed from world-readable /proc and `sudo llm2ssh ... --json`.
# Sourced by llm2ssh-botd (runs as llm2ssh-bot).

[[ -n "${_LLM2SSH_BOTHANDLERS_SOURCED:-}" ]] && return 0
_LLM2SSH_BOTHANDLERS_SOURCED=1

L2="/usr/local/bin/llm2ssh"
L2ADMIN="/usr/local/lib/llm2ssh/bin/llm2ssh-bot-admin"

_h() { printf '%s\n' "$*"; }

# _admin VERB ARGS... — run an admin action through the root-owned wrapper (which
# hard-refuses full/delete). Echoes combined output for the reply.
_admin() { sudo -n "$L2ADMIN" "$@" 2>&1; }

bot_cmd_help() {
  local admin="${1:-false}"
  cat <<'EOF'
llm2ssh bot commands:
/status          — server + agent status
/docker          — running containers
/log <agent> [n] — recent audit lines
/freeze <agent>  — kill-switch (revoke + sever sessions)
/unfreeze <agent>
/new             — reset the chat-relay conversation
/help            — this help
EOF
  if [[ "$admin" == "true" ]]; then
    cat <<'EOF'

admin:
/agents               — list managed agents
/onboard <a> [prof]   — create agent + issue a key (sent as a file)
/grant <a> <prof> [ttl] — change permissions (full/delete are terminal-only)
/revoke <a>           — drop back to base profile
/profiles             — available permission profiles
/tools                — install monitoring tools
EOF
  fi
  printf 'Any other text is relayed to the on-server agent.\n'
}

# ---- admin handlers (all go through the hard-limited wrapper) --------------
bot_cmd_agents() {
  local out; out="$(_admin list)"
  local n; n="$(jq 'length' <<<"$out" 2>/dev/null || echo '?')"
  _h "agents: ${n}"
  jq -r '.[]? | "  • \(.agent): \(.profile)\(if .frozen then "  [FROZEN]" else "" end)"' <<<"$out" 2>/dev/null || _h "$out"
}

bot_cmd_profiles() { _h "$(_admin profiles)"; }

bot_cmd_grant() {
  local agent="$1" prof="$2"; shift 2 || true
  [[ -n "$agent" && -n "$prof" ]] || { _h "usage: /grant <agent> <profile> [ttl]"; return; }
  local args=(grant "$agent" "$prof")
  [[ -n "${1:-}" ]] && args+=(--ttl "$1")
  _h "$(_admin "${args[@]}")"
}

bot_cmd_revoke() {
  [[ -n "${1:-}" ]] || { _h "usage: /revoke <agent>"; return; }
  _h "$(_admin revoke "$1")"
}

bot_cmd_tools() { _h "installing tools (may take a minute)…"; _admin tools >/dev/null 2>&1 & }

bot_cmd_status() {
  local up load mem disk
  up="$(awk '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); printf "%dd %dh %dm", d,h,m}' /proc/uptime 2>/dev/null)"
  load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
  mem="$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d/%d MiB", $3, $2}')"
  disk="$(df -h / 2>/dev/null | awk 'NR==2{printf "%s used of %s (%s)", $3,$2,$5}')"
  _h "🖥 $(hostname) — up ${up:-?}"
  _h "load ${load:-?}   mem ${mem:-?}   disk / ${disk:-?}"
  # Agents
  local agents_json
  agents_json="$(sudo -n "$L2" list --json 2>/dev/null || echo '[]')"
  local n; n="$(jq 'length' <<<"$agents_json" 2>/dev/null || echo 0)"
  _h "agents: ${n}"
  local i
  for ((i=0; i<n; i++)); do
    local a prof frozen st
    a="$(jq -r ".[$i].agent" <<<"$agents_json")"
    st="$(sudo -n "$L2" status "$a" --json 2>/dev/null || echo '{}')"
    prof="$(jq -r '.current_profile // "?"' <<<"$st")"
    frozen="$(jq -r '.frozen // false' <<<"$st")"
    local rem; rem="$(jq -r '.remaining_s // 0' <<<"$st")"
    local ttl=""; [[ "$rem" -gt 0 ]] && ttl=" (ttl ${rem}s)"
    _h "  • ${a}: ${prof}${ttl}$([[ "$frozen" == true ]] && echo '  [FROZEN]')"
  done
}

bot_cmd_docker() {
  local dbin; dbin="$(command -v docker 2>/dev/null)"
  [[ -n "$dbin" ]] || { _h "docker not installed"; return; }
  local out; out="$(sudo -n "$dbin" ps --format json 2>/dev/null || true)"
  [[ -n "$out" ]] || { _h "docker: not permitted or no containers"; return; }
  _h "🐳 containers:"
  # docker ps --format json emits one JSON object per line.
  printf '%s\n' "$out" | jq -r '"  • \(.Names)  \(.Image)  [\(.State)] \(.Status)"' 2>/dev/null \
    || _h "(could not parse docker output)"
}

# bot_cmd_log AGENT [N]
bot_cmd_log() {
  local agent="${1:-}" n="${2:-20}"
  [[ -n "$agent" ]] || { _h "usage: /log <agent> [n]"; return; }
  local out; out="$(sudo -n "$L2" log "$agent" --since 6h 2>/dev/null | tail -n "$n" || true)"
  [[ -n "$out" ]] && _h "$out" || _h "no recent audit data for $agent"
}

# bot_cmd_freeze VERB AGENT  (VERB: freeze|unfreeze)
bot_cmd_freeze() {
  local verb="$1" agent="${2:-}"
  [[ -n "$agent" ]] || { _h "usage: /$verb <agent>"; return; }
  if sudo -n "$L2" "$verb" "$agent" >/dev/null 2>&1; then
    _h "✅ ${verb}d $agent"
  else
    _h "⚠️ could not $verb $agent"
  fi
}
