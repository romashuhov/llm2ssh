# shellcheck shell=bash
# bot/handlers.sh — command handlers. Each echoes reply TEXT (plain, never a
# shell). Composed from world-readable /proc and `sudo llm2ssh ... --json`.
# Sourced by llm2ssh-botd (runs as llm2ssh-bot).

[[ -n "${_LLM2SSH_BOTHANDLERS_SOURCED:-}" ]] && return 0
_LLM2SSH_BOTHANDLERS_SOURCED=1

L2="/usr/local/bin/llm2ssh"
L2HUB="/usr/local/lib/llm2ssh/bin/llm2ssh-hub"
CUR_SERVER_FILE="/var/lib/llm2ssh-bot/current_server"

_h() { printf '%s\n' "$*"; }

# Which server the bot currently operates on (default: this host).
_cur_server() { cat "$CUR_SERVER_FILE" 2>/dev/null || echo local; }
_set_server() { printf '%s' "$1" >"$CUR_SERVER_FILE" 2>/dev/null || true; }

# _l2 VERB ARGS... — run an llm2ssh subcommand on the CURRENT server (local or a
# remote node) through the root-owned hub wrapper. The wrapper routes admin verbs
# to llm2ssh-bot-admin (no full/delete) — so multi-server keeps the same limits.
_l2()      { sudo -n "$L2HUB" "$(_cur_server)" "$@"; }        # clean stdout (for JSON)
_admin()   { sudo -n "$L2HUB" "$(_cur_server)" "$@" 2>&1; }   # combined (for display)

bot_cmd_help() {
  local admin="${1:-false}"
  cat <<'EOF'
llm2ssh bot commands:
/menu            — buttons for everything (recommended)
/status          — server + agent overview
/agents          — agents: user, permissions, sessions
/agent <name>    — one agent in detail
hardware:
/disk /mem /cpu /temp /top /hw
/docker          — running containers
/log <agent> [n] — recent audit lines
/instructions    — the agent playbook (to paste into your agent)
/freeze <agent>  — kill-switch (revoke + sever sessions)
/unfreeze <agent>
/new             — reset the chat-relay conversation
/help            — this help
(agents can also request access; you'll get a card with duration buttons)
EOF
  if [[ "$admin" == "true" ]]; then
    cat <<'EOF'

admin:
/onboard <a> [prof]   — create agent + issue a key (sent as a file)
/grant <a> <prof> [ttl] — change permissions (full/delete are terminal-only)
/revoke <a>           — drop back to base profile
/profiles             — available permission profiles
/tools                — install monitoring tools
EOF
  fi
  printf 'Any other text is relayed to the on-server agent.\n'
}

# ---- agent panel (read-only; owner-gated like everything else) -------------
# seconds -> compact human duration (3h58m / 45s)
_fmt_dur() {
  local s="${1:-0}"; [[ "$s" =~ ^[0-9]+$ ]] || { printf '?'; return; }
  local d=$((s/86400)) h=$(((s%86400)/3600)) m=$(((s%3600)/60))
  if   [[ $d -gt 0 ]]; then printf '%dd%dh' "$d" "$h"
  elif [[ $h -gt 0 ]]; then printf '%dh%dm' "$h" "$m"
  elif [[ $m -gt 0 ]]; then printf '%dm' "$m"
  else printf '%ds' "$s"; fi
}

# one-line session summary for an agent (from utmp; unprivileged)
_agent_sessions() {
  local a="$1" hosts
  hosts="$(who 2>/dev/null | awk -v u="$a" '$1==u {h=$NF; gsub(/[()]/,"",h); print h}')"
  [[ -z "$hosts" ]] && { printf 'idle'; return; }
  local n; n="$(printf '%s\n' "$hosts" | grep -c .)"
  printf '%s session(s) from %s' "$n" "$(printf '%s ' $hosts | sed 's/ *$//')"
}

bot_cmd_agents() {
  local srv; srv="$(_cur_server)"
  local arr; arr="$(_l2 status --json 2>/dev/null || echo '[]')"
  local n; n="$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)"
  [[ "$n" -gt 0 ]] || { _h "👥 [$srv] no managed agents. Add one with /onboard <name>."; return; }
  _h "👥 [$srv] agents ($n):"
  local i
  for ((i=0; i<n; i++)); do
    local a prof frozen rem ttl extra=""
    a="$(jq -r ".[$i].agent" <<<"$arr")"
    prof="$(jq -r ".[$i].current_profile // \"?\"" <<<"$arr")"
    frozen="$(jq -r ".[$i].frozen // false" <<<"$arr")"
    rem="$(jq -r ".[$i].remaining_s // 0" <<<"$arr")"
    ttl=""; [[ "$rem" =~ ^[0-9]+$ && "$rem" -gt 0 ]] && ttl="  ttl $(_fmt_dur "$rem")"
    # uid/sessions come from utmp — only meaningful for the local hub box.
    [[ "$srv" == "local" ]] && extra=" (uid $(id -u "$a" 2>/dev/null || echo ?))  · $(_agent_sessions "$a")"
    _h "• $a$extra — $prof$ttl$([[ "$frozen" == true ]] && echo '  ❄️FROZEN')"
  done
  _h "→ /agent <name> for detail"
}

bot_cmd_agent() {
  local a="${1:-}"; [[ -n "$a" ]] || { _h "usage: /agent <name>"; return; }
  local srv; srv="$(_cur_server)"
  local st; st="$(_l2 status "$a" --json 2>/dev/null || echo '{}')"
  [[ "$(jq -r '.agent // empty' <<<"$st")" == "$a" ]] || { _h "[$srv] no such agent: $a"; return; }
  local prof base frozen rem ttl
  prof="$(jq -r '.current_profile // "?"' <<<"$st")"
  base="$(jq -r '.base_profile // "?"' <<<"$st")"
  frozen="$(jq -r '.frozen // false' <<<"$st")"
  rem="$(jq -r '.remaining_s // 0' <<<"$st")"
  ttl="never"; [[ "$rem" =~ ^[0-9]+$ && "$rem" -gt 0 ]] && ttl="$(_fmt_dur "$rem") left"
  _h "🔎 [$srv] $a"
  _h "profile:  $prof (base $base)   ttl: $ttl$([[ "$frozen" == true ]] && echo '   ❄️FROZEN')"
  if [[ "$srv" == "local" ]]; then
    _h "uid:      $(id -u "$a" 2>/dev/null)"
    local who_lines; who_lines="$(who 2>/dev/null | awk -v u="$a" '$1==u {h=$NF; gsub(/[()]/,"",h); printf "  %s  %s  %s %s\n", $2, h, $3, $4}')"
    [[ -n "$who_lines" ]] && { _h "sessions:"; _h "$who_lines"; } || _h "sessions: none"
  fi
  local rec; rec="$(_l2 log "$a" 2>/dev/null | tail -n 5 || true)"
  [[ -n "$rec" ]] && { _h "recent:"; _h "$rec"; }
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
  local srv; srv="$(_cur_server)"
  if [[ "$srv" == "local" ]]; then
    local up load mem disk
    up="$(awk '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); printf "%dd %dh %dm", d,h,m}' /proc/uptime 2>/dev/null)"
    load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    mem="$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d/%d MiB", $3, $2}')"
    disk="$(df -h / 2>/dev/null | awk 'NR==2{printf "%s used of %s (%s)", $3,$2,$5}')"
    _h "🖥 $(hostname) [local] — up ${up:-?}"
    _h "load ${load:-?}   mem ${mem:-?}   disk / ${disk:-?}"
  else
    _h "🖥 [$srv]"
    _l2 hwstat cpu 2>&1 | head -1
  fi
  local arr; arr="$(_l2 status --json 2>/dev/null || echo '[]')"
  local n; n="$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)"
  _h "agents: ${n}"
  local i
  for ((i=0; i<n; i++)); do
    local a prof frozen rem ttl
    a="$(jq -r ".[$i].agent" <<<"$arr")"
    prof="$(jq -r ".[$i].current_profile // \"?\"" <<<"$arr")"
    frozen="$(jq -r ".[$i].frozen // false" <<<"$arr")"
    rem="$(jq -r ".[$i].remaining_s // 0" <<<"$arr")"
    ttl=""; [[ "$rem" =~ ^[0-9]+$ && "$rem" -gt 0 ]] && ttl=" (ttl $(_fmt_dur "$rem"))"
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
  local out; out="$(_l2 log "$agent" 2>/dev/null | tail -n "$n" || true)"
  [[ -n "$out" ]] && _h "$out" || _h "no recent audit data for $agent"
}

# ---- hardware stats — routed to the current server via `llm2ssh hwstat` -----
bot_cmd_disk() { _l2 hwstat disk 2>&1; }
bot_cmd_mem()  { _l2 hwstat mem  2>&1; }
bot_cmd_cpu()  { _l2 hwstat cpu  2>&1; }
bot_cmd_temp() { _l2 hwstat temp 2>&1; }
bot_cmd_top()  { _l2 hwstat top  2>&1; }
bot_cmd_hw()   { _l2 hwstat hw   2>&1; }

# bot_cmd_freeze VERB AGENT  (VERB: freeze|unfreeze)
bot_cmd_freeze() {
  local verb="$1" agent="${2:-}"
  [[ -n "$agent" ]] || { _h "usage: /$verb <agent>"; return; }
  if _l2 "$verb" "$agent" >/dev/null 2>&1; then
    _h "✅ ${verb}d $agent"
  else
    _h "⚠️ could not $verb $agent"
  fi
}

# bot_cmd_servers — the registry, for the /server picker and text list.
bot_cmd_servers() {
  _h "🔀 servers (current: $(_cur_server)):"
  "$L2" servers list 2>/dev/null | sed 's/^/  /'
  _h "switch: /server <name>  ·  add on the server: sudo llm2ssh servers add <name> <ssh-target>"
}
