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
  local arr; arr="$(sudo -n "$L2" status --json 2>/dev/null || echo '[]')"
  local n; n="$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)"
  [[ "$n" -gt 0 ]] || { _h "👥 no managed agents. Add one with /onboard <name>."; return; }
  _h "👥 agents ($n):"
  local i
  for ((i=0; i<n; i++)); do
    local a prof frozen rem uid ttl
    a="$(jq -r ".[$i].agent" <<<"$arr")"
    prof="$(jq -r ".[$i].current_profile // \"?\"" <<<"$arr")"
    frozen="$(jq -r ".[$i].frozen // false" <<<"$arr")"
    rem="$(jq -r ".[$i].remaining_s // 0" <<<"$arr")"
    uid="$(id -u "$a" 2>/dev/null || echo '?')"
    ttl=""; [[ "$rem" =~ ^[0-9]+$ && "$rem" -gt 0 ]] && ttl="  ttl $(_fmt_dur "$rem")"
    _h "• $a (uid $uid) — $prof$ttl$([[ "$frozen" == true ]] && echo '  ❄️FROZEN')  · $(_agent_sessions "$a")"
  done
  _h "→ /agent <name> for detail"
}

bot_cmd_agent() {
  local a="${1:-}"; [[ -n "$a" ]] || { _h "usage: /agent <name>"; return; }
  id -u "$a" >/dev/null 2>&1 || { _h "no such agent: $a"; return; }
  local st; st="$(sudo -n "$L2" status "$a" --json 2>/dev/null || echo '{}')"
  local prof base frozen rem ttl
  prof="$(jq -r '.current_profile // "?"' <<<"$st")"
  base="$(jq -r '.base_profile // "?"' <<<"$st")"
  frozen="$(jq -r '.frozen // false' <<<"$st")"
  rem="$(jq -r '.remaining_s // 0' <<<"$st")"
  ttl="never"; [[ "$rem" =~ ^[0-9]+$ && "$rem" -gt 0 ]] && ttl="$(_fmt_dur "$rem") left"
  _h "🔎 $a"
  _h "user:     $a (uid $(id -u "$a" 2>/dev/null))"
  _h "profile:  $prof (base $base)   ttl: $ttl$([[ "$frozen" == true ]] && echo '   ❄️FROZEN')"
  local who_lines; who_lines="$(who 2>/dev/null | awk -v u="$a" '$1==u {h=$NF; gsub(/[()]/,"",h); printf "  %s  %s  %s %s\n", $2, h, $3, $4}')"
  [[ -n "$who_lines" ]] && { _h "sessions:"; _h "$who_lines"; } || _h "sessions: none"
  local rec; rec="$(sudo -n "$L2" log "$a" --since 6h 2>/dev/null | tail -n 5 || true)"
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

# ---- hardware stats (all unprivileged; no sudo needed) ---------------------
bot_cmd_disk() {
  _h "💾 disk:"
  df -h -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk 'NR>1{
    u=$5; gsub(/%/,"",u); w=(u+0>=85)?" ⚠️":"";
    printf "• %s : %s/%s (%s)%s\n", $6, $3, $2, $5, w
  }'
}

bot_cmd_mem() {
  _h "🧠 memory:"
  free -h 2>/dev/null | awk '/^Mem:/{printf "• RAM: %s used / %s total (free %s)\n",$3,$2,$4} /^Swap:/ && $2!="0B"{printf "• swap: %s / %s\n",$3,$2}'
  _h "top by mem:"
  ps -eo comm,%mem,%cpu --sort=-%mem 2>/dev/null | awk 'NR>1 && NR<=6{printf "  %-16s %5s%%m %5s%%c\n",$1,$2,$3}'
}

bot_cmd_cpu() {
  local load nc
  load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
  nc="$(nproc 2>/dev/null || echo '?')"
  _h "⚙️ cpu: load ${load:-?}  ($nc cores)"
  _h "top by cpu:"
  ps -eo comm,%cpu,%mem --sort=-%cpu 2>/dev/null | awk 'NR>1 && NR<=6{printf "  %-16s %5s%%c %5s%%m\n",$1,$2,$3}'
}

bot_cmd_temp() {
  have_cmd sensors || { _h "🌡 sensors not available — install lm-sensors (llm2ssh tools install), then: sudo sensors-detect"; return; }
  local out; out="$(sensors -A 2>/dev/null | grep -iE '°c|rpm' | sed 's/  */ /g')"
  [[ -n "$out" ]] && { _h "🌡 sensors:"; _h "$out"; } || _h "🌡 no temperature sensors detected (try: sudo sensors-detect)"
}

bot_cmd_top() {
  _h "📊 top processes:"
  ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | awk 'NR>1 && NR<=9{printf "  %6s %-16s %5s%%c %5s%%m\n",$1,$2,$3,$4}'
}

bot_cmd_hw() {
  local model cores ram
  model="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  [[ -n "$model" ]] || model="$(awk -F: '/model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  cores="$(nproc 2>/dev/null || echo '?')"
  ram="$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
  _h "🖥 $(hostname)"
  _h "cpu: ${model:-?} ($cores cores)"
  _h "ram: ${ram:-?}"
  local disks; disks="$(lsblk -d -n -o NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3=="disk"{m=""; for(k=4;k<=NF;k++) m=m" "$k; printf "  %s  %s%s\n",$1,$2,m}')"
  [[ -n "$disks" ]] && { _h "disks:"; _h "$disks"; }
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
