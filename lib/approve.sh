# shellcheck shell=bash
# lib/approve.sh — approval broker SERVER side. Provides the local TTY approver
# (`llm2ssh approve --watch`) and scriptable decisions, plus helpers the Telegram
# bot reuses. The CLIENT is wrappers/llm2ssh-approve. See docs/CONTRACTS.md.

[[ -n "${_LLM2SSH_APPROVE_SOURCED:-}" ]] && return 0
_LLM2SSH_APPROVE_SOURCED=1

APPROVAL_REQ="$LLM2SSH_RUN/approvals/req"
APPROVAL_RES="$LLM2SSH_RUN/approvals/res"
APPROVAL_HB="$LLM2SSH_RUN/approvald.alive"

approval_touch_hb() { : >"$APPROVAL_HB" 2>/dev/null || true; }

# Background heartbeat toucher; prints its PID. Caller must kill it on exit.
# The subshell's fds MUST be redirected away from any command-substitution pipe,
# otherwise `pid=$(approval_hb_daemon_start)` hangs waiting on the child.
approval_hb_daemon_start() {
  ( while true; do : >"$APPROVAL_HB" 2>/dev/null || true; sleep 5; done ) >/dev/null 2>&1 &
  printf '%s' "$!"
}

approval_ensure_spool() {
  ensure_dir "$APPROVAL_REQ" 3770 "root:$LLM2SSH_GROUP"
  ensure_dir "$APPROVAL_RES" 2750 "$LLM2SSH_BOT_USER:$LLM2SSH_GROUP" 2>/dev/null || ensure_dir "$APPROVAL_RES" 2750 "root:$LLM2SSH_GROUP"
}

# approval_pending — req ids, oldest first.
approval_pending() {
  local f
  for f in $(ls -1tr "$APPROVAL_REQ"/*.json 2>/dev/null || true); do
    basename "$f" .json
  done
}

approval_req_field() {
  local id="$1" field="$2"
  jq -r --arg f "$field" '.[$f] // ""' "$APPROVAL_REQ/$id.json" 2>/dev/null || true
}

# approval_is_frozen USER -> 0 if that agent is frozen.
approval_is_frozen() { [[ -f "$LLM2SSH_RUN/agents/$1.frozen" ]]; }

# approval_write_decision ID DECISION DECIDED_BY [REASON]
approval_write_decision() {
  local id="$1" decision="$2" by="$3" reason="${4:-}"
  local res="$APPROVAL_RES/$id.json" tmp
  tmp="$APPROVAL_RES/.$id.tmp.$$"
  approval_ensure_spool
  jq -n --arg id "$id" --arg d "$decision" --arg by "$by" --arg r "$reason" \
        --argjson at "$(now_epoch)" \
        '{id:$id, decision:$d, decided_by:$by, reason:$r, decided_at:$at}' \
    >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  chmod 0640 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$res"
}

_approval_print_request() {
  local id="$1"
  printf '\n--- approval request %s ---\n' "$id" >&2
  printf '  user:    %s\n' "$(approval_req_field "$id" user)" >&2
  printf '  source:  %s\n' "$(approval_req_field "$id" source)" >&2
  printf '  command: %s\n' "$(approval_req_field "$id" command)" >&2
  printf '  cwd:     %s\n' "$(approval_req_field "$id" cwd)" >&2
}

cmd_approve() {
  have_cmd jq || die "jq required for approvals"
  case "${1:-}" in
    --watch)  shift; _approve_watch "$@" ;;
    --list)   _approve_list ;;
    "" )      die_usage "usage: llm2ssh approve --watch [--auto allow|deny] | --list | <id> allow|deny [--reason R]" ;;
    -*)       die_usage "unknown flag: $1" ;;
    *)        _approve_decide "$@" ;;
  esac
}

_approve_list() {
  approval_ensure_spool
  local id any=0
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    any=1
    printf '%s  %s  %s\n' "$id" "$(approval_req_field "$id" user)" "$(approval_req_field "$id" command)"
  done < <(approval_pending)
  [[ "$any" -eq 0 ]] && log "no pending approval requests"
}

# _approve_decide ID allow|deny [--reason R]
_approve_decide() {
  local id="$1" decision="${2:-}" reason=""
  shift 2 || true
  while [[ $# -gt 0 ]]; do case "$1" in --reason) reason="${2:-}"; shift 2 ;; *) shift ;; esac; done
  case "$decision" in allow|deny) ;; *) die_usage "decision must be allow|deny" ;; esac
  [[ -f "$APPROVAL_REQ/$id.json" ]] || warn "no pending request '$id' (writing decision anyway)"
  approval_write_decision "$id" "$decision" "tty:$(id -un)" "$reason" \
    && log "recorded: $id -> $decision"
}

_approve_watch() {
  local auto=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto) auto="${2:-}"; shift 2 ;;
      *) die_usage "unknown flag for --watch: $1" ;;
    esac
  done
  [[ -z "$auto" || "$auto" == "allow" || "$auto" == "deny" ]] || die_usage "--auto must be allow|deny"
  approval_ensure_spool
  approval_touch_hb
  local hbpid; hbpid="$(approval_hb_daemon_start)"
  # shellcheck disable=SC2064
  trap "kill $hbpid 2>/dev/null || true" EXIT INT TERM

  if [[ -n "$auto" ]]; then
    warn "AUTO-$auto mode: every request will be auto-${auto}d (audited). Ctrl-C to stop."
  else
    log "approver watching for requests (Ctrl-C to stop)…"
  fi

  declare -A seen=()
  while true; do
    local id user cmd decision by reason
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      [[ -n "${seen[$id]:-}" ]] && continue
      user="$(approval_req_field "$id" user)"
      cmd="$(approval_req_field "$id" command)"
      reason=""
      if approval_is_frozen "$user"; then
        decision="deny"; by="freeze"; reason="agent frozen"
      elif [[ -n "$auto" ]]; then
        decision="$auto"; by="tty-auto:$(id -un)"
      else
        _approval_print_request "$id"
        local ans=""
        read -r -p "Allow this command? [y/N] " ans || ans=""
        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then decision="allow"; else decision="deny"; fi
        by="tty:$(id -un)"
      fi
      approval_write_decision "$id" "$decision" "$by" "$reason"
      seen[$id]=1
      declare -F event_log >/dev/null 2>&1 && event_log "approval $id ($cmd) -> $decision by $by" || true
    done < <(approval_pending)
    sleep 0.5
  done
}
