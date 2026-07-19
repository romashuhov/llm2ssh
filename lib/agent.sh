# shellcheck shell=bash
# lib/agent.sh — Mode B: run an agent CLI ON the server, in a tmux session the
# owner can attach to (or drive via the Telegram bot). Provider-agnostic: the
# CLI-specific bits (install, auth, launch command) come from the active provider
# in lib/agents/<provider>.sh via these functions:
#   agent_install AGENT           — install the agent CLI
#   agent_auth AGENT ARGS...      — configure credentials
#   agent_exec_line AGENT         — echo the shell command tmux should run
#   agent_status_line AGENT       — echo a one-line provider status (optional)

[[ -n "${_LLM2SSH_AGENT_SOURCED:-}" ]] && return 0
_LLM2SSH_AGENT_SOURCED=1

LLM2SSH_TMUX_SOCK="llm2ssh"
agent_tmux_session() { printf 'agent-%s' "$1"; }
agent_ttylog() { printf '%s/.llm2ssh/tty.log' "$(agent_home "$1")"; }

# _as_agent AGENT CMD...  — run CMD as the agent user.
_as_agent() { local a="$1"; shift; runuser -u "$a" -- "$@"; }

_agent_tmux() { local a="$1"; shift; _as_agent "$a" tmux -L "$LLM2SSH_TMUX_SOCK" "$@"; }

_agent_provider() {
  # Only claude for v1; abstraction is in place for more.
  printf '%s' "${LLM2SSH_AGENT_PROVIDER:-claude}"
}

cmd_agent() {
  local action="${1:-}"; shift || true
  case "$action" in
    install) _agent_install "$@" ;;
    auth)    _agent_auth "$@" ;;
    start)   _agent_start "$@" ;;
    attach)  _agent_attach "$@" ;;
    say)     _agent_say "$@" ;;
    tail)    _agent_tail "$@" ;;
    status)  _agent_status "$@" ;;
    stop)    _agent_stop "$@" ;;
    *) die_usage "usage: llm2ssh agent install|auth|start|attach|say|tail|status|stop <agent>" ;;
  esac
}

_agent_install() {
  local agent="${1:-}"; [[ -n "$agent" ]] || die_usage "usage: llm2ssh agent install <agent>"
  require_agent_exists "$agent"
  declare -F agent_install >/dev/null 2>&1 || die "no agent provider available"
  agent_install "$agent"
  # Ensure workspace + compiled policy/settings exist.
  local home; home="$(agent_home "$agent")"
  [[ -n "$home" ]] && install -d -o "$agent" -g "$agent" -m 0750 "$home/workspace" "$home/.llm2ssh" 2>/dev/null || true
  declare -F context_render >/dev/null 2>&1 && context_render "$agent" || true
  log "agent CLI installed for '$agent' — set credentials: llm2ssh agent auth $agent"
}

_agent_auth() {
  local agent="${1:-}"; shift || true
  [[ -n "$agent" ]] || die_usage "usage: llm2ssh agent auth <agent> [--api-key|--oauth-token|--login]"
  require_agent_exists "$agent"
  declare -F agent_auth >/dev/null 2>&1 || die "no agent provider available"
  agent_auth "$agent" "$@"
}

_agent_start() {
  local agent="" resume=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --resume) resume=1; shift ;;
      *) agent="$1"; shift ;;
    esac
  done
  [[ -n "$agent" ]] || die_usage "usage: llm2ssh agent start <agent> [--resume]"
  require_agent_exists "$agent"
  [[ "$(state_get "$agent" frozen 0)" == "1" ]] && die "agent '$agent' is frozen"
  have_cmd tmux || die "tmux not installed"
  declare -F agent_exec_line >/dev/null 2>&1 || die "no agent provider available"

  local sess home ws exec_line
  sess="$(agent_tmux_session "$agent")"
  home="$(agent_home "$agent")"
  ws="$home/workspace"
  install -d -o "$agent" -g "$agent" -m 0750 "$ws" "$home/.llm2ssh" 2>/dev/null || true

  if _agent_tmux "$agent" has-session -t "$sess" 2>/dev/null; then
    log "agent '$agent' already running (attach: llm2ssh agent attach $agent)"
    return 0
  fi
  exec_line="$(LLM2SSH_RESUME="$resume" agent_exec_line "$agent")"
  _agent_tmux "$agent" new-session -d -s "$sess" -c "$ws" "$exec_line"
  # Mirror pane output for audit + TG relay.
  _as_agent "$agent" mkdir -p "$home/.llm2ssh" 2>/dev/null || true
  _agent_tmux "$agent" pipe-pane -o -t "$sess" "cat >> $(agent_ttylog "$agent")" 2>/dev/null || true
  declare -F event_log >/dev/null 2>&1 && event_log "agent '$agent' session started" || true
  log "started agent '$agent' (attach: llm2ssh agent attach $agent)"
}

_agent_attach() {
  local agent="" ro=0
  while [[ $# -gt 0 ]]; do case "$1" in --read-only) ro=1; shift ;; *) agent="$1"; shift ;; esac; done
  [[ -n "$agent" ]] || die_usage "usage: llm2ssh agent attach <agent> [--read-only]"
  require_agent_exists "$agent"
  local sess; sess="$(agent_tmux_session "$agent")"
  _agent_tmux "$agent" has-session -t "$sess" 2>/dev/null || die "agent '$agent' is not running (start it: llm2ssh agent start $agent)"
  if [[ "$ro" -eq 1 ]]; then
    exec runuser -u "$agent" -- tmux -L "$LLM2SSH_TMUX_SOCK" attach -r -t "$sess"
  else
    exec runuser -u "$agent" -- tmux -L "$LLM2SSH_TMUX_SOCK" attach -t "$sess"
  fi
}

_agent_say() {
  local agent="${1:-}" text="${2:-}"
  [[ -n "$agent" && -n "$text" ]] || die_usage "usage: llm2ssh agent say <agent> \"text\""
  require_agent_exists "$agent"
  local sess; sess="$(agent_tmux_session "$agent")"
  _agent_tmux "$agent" has-session -t "$sess" 2>/dev/null || die "agent '$agent' is not running"
  _agent_tmux "$agent" send-keys -t "$sess" -l "$text"
  _agent_tmux "$agent" send-keys -t "$sess" Enter
  log "sent to '$agent'"
}

_agent_tail() {
  local agent="" n=200
  while [[ $# -gt 0 ]]; do case "$1" in -n) n="${2:-200}"; shift 2 ;; *) agent="$1"; shift ;; esac; done
  [[ -n "$agent" ]] || die_usage "usage: llm2ssh agent tail <agent> [-n N]"
  require_agent_exists "$agent"
  local ttylog; ttylog="$(agent_ttylog "$agent")"
  if [[ -r "$ttylog" ]]; then
    tail -n "$n" "$ttylog"
  else
    local sess; sess="$(agent_tmux_session "$agent")"
    _agent_tmux "$agent" capture-pane -p -t "$sess" 2>/dev/null | tail -n "$n" || log "no output yet for '$agent'"
  fi
}

_agent_status() {
  local agent="${1:-}"; [[ -n "$agent" ]] || die_usage "usage: llm2ssh agent status <agent>"
  require_agent_exists "$agent"
  local sess running="no" frozen
  sess="$(agent_tmux_session "$agent")"
  _agent_tmux "$agent" has-session -t "$sess" 2>/dev/null && running="yes"
  frozen="$(state_get "$agent" frozen 0)"
  printf 'agent      %s\n' "$agent"
  printf 'session    %s\n' "$running"
  printf 'profile    %s%s\n' "$(state_get "$agent" current_profile observer)" \
         "$([[ "$frozen" == 1 ]] && echo '   [FROZEN]')"
  declare -F agent_status_line >/dev/null 2>&1 && agent_status_line "$agent" || true
}

_agent_stop() {
  local agent="" force=0
  while [[ $# -gt 0 ]]; do case "$1" in --force) force=1; shift ;; *) agent="$1"; shift ;; esac; done
  [[ -n "$agent" ]] || die_usage "usage: llm2ssh agent stop <agent> [--force]"
  require_agent_exists "$agent"
  local sess; sess="$(agent_tmux_session "$agent")"
  if ! _agent_tmux "$agent" has-session -t "$sess" 2>/dev/null; then log "agent '$agent' is not running"; return 0; fi
  if [[ "$force" -eq 0 ]]; then
    _agent_tmux "$agent" send-keys -t "$sess" C-c 2>/dev/null || true
    _agent_tmux "$agent" send-keys -t "$sess" C-c 2>/dev/null || true
  fi
  _agent_tmux "$agent" kill-session -t "$sess" 2>/dev/null || true
  declare -F event_log >/dev/null 2>&1 && event_log "agent '$agent' session stopped" || true
  log "stopped agent '$agent'"
}
