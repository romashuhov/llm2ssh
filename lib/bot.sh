# shellcheck shell=bash
# lib/bot.sh — Telegram bot setup and the security-critical bits: least-privilege
# sudoers, config file with tight perms, the owner-gated callback decision, and
# the systemd unit. The daemon itself lives in bot/llm2ssh-botd.

[[ -n "${_LLM2SSH_BOT_SOURCED:-}" ]] && return 0
_LLM2SSH_BOT_SOURCED=1

# Interactive `bot setup` and the request-decision helpers use the Telegram API
# wrappers (tg_call, tg_send_message, …). The CLI dispatcher sources lib/* but
# not bot/*, so pull tg-api.sh in here (it guards against double-sourcing).
# shellcheck source=/dev/null
[[ -r "$LLM2SSH_LIB/bot/tg-api.sh" ]] && . "$LLM2SSH_LIB/bot/tg-api.sh"

BOT_CONFIG="$LLM2SSH_ETC/bot.env"
BOT_SUDOERS="$LLM2SSH_SUDOERSD/llm2ssh-bot"
BOT_UNIT="/etc/systemd/system/llm2ssh-bot.service"
BOT_RELAY_BIN="/usr/local/lib/llm2ssh/bin/relay-exec"
BOT_ADMIN_BIN="/usr/local/lib/llm2ssh/bin/llm2ssh-bot-admin"
# Access-request spool + the bot's own heartbeat (the request client checks this
# specifically, so a running local TTY approver isn't mistaken for the bot).
REQUEST_REQ="$LLM2SSH_RUN/requests/req"
REQUEST_RES="$LLM2SSH_RUN/requests/res"
# shellcheck disable=SC2034  # BOTD_HB is consumed by llm2ssh-botd
BOTD_HB="$LLM2SSH_RUN/botd.alive"

# ---- sudoers (the bot's ENTIRE privilege surface) --------------------------
# Correct argument forms (M6): freeze/unfreeze/status/log/list all take args.
# With admin=1, the bot may ALSO run the admin wrapper, which itself hard-refuses
# `full`/delete — so even the admin bot cannot grant root or destroy an agent.
bot_render_sudoers() {
  local agent="${1:-}" admin="${2:-0}" dbin
  dbin="$(resolve_docker_bin 2>/dev/null || echo /usr/bin/docker)"
  cat <<EOF
# Managed by llm2ssh — the Telegram bot's entire privilege surface. DO NOT EDIT.
Cmnd_Alias LLM2SSH_BOT_RO = /usr/local/bin/llm2ssh status, /usr/local/bin/llm2ssh status *, \\
    /usr/local/bin/llm2ssh list, /usr/local/bin/llm2ssh list *, \\
    /usr/local/bin/llm2ssh log *
Cmnd_Alias LLM2SSH_BOT_CTL = /usr/local/bin/llm2ssh freeze *, /usr/local/bin/llm2ssh unfreeze *
Cmnd_Alias LLM2SSH_BOT_DOCKER = $dbin ps --format json, $dbin ps -a --format json, \\
    $dbin ps --format json --no-trunc
$LLM2SSH_BOT_USER ALL=(root) NOPASSWD: LLM2SSH_BOT_RO, LLM2SSH_BOT_CTL, LLM2SSH_BOT_DOCKER
EOF
  if [[ "$admin" == "1" ]]; then
    # The admin wrapper is the boundary; the wildcard is safe because the wrapper
    # validates every verb/arg and refuses full/delete.
    printf '%s ALL=(root) NOPASSWD: %s *\n' "$LLM2SSH_BOT_USER" "$BOT_ADMIN_BIN"
  fi
  if [[ -n "$agent" ]]; then
    printf '%s ALL=(%s) NOPASSWD: %s *\n' "$LLM2SSH_BOT_USER" "$agent" "$BOT_RELAY_BIN"
  fi
}

bot_install_sudoers() {
  local agent="${1:-}" admin="${2:-0}" tmp
  ensure_dir "$LLM2SSH_SUDOERSD" 0755 "root:root"
  tmp="$LLM2SSH_SUDOERSD/.llm2ssh-bot.tmp.$$"
  bot_render_sudoers "$agent" "$admin" >"$tmp"
  chmod 0440 "$tmp"; chown root:root "$tmp" 2>/dev/null || true
  if ! sudoers_validate "$tmp"; then
    rm -f "$tmp"; die_validation "generated bot sudoers failed visudo -cf"
  fi
  mv -f "$tmp" "$BOT_SUDOERS"
}

# ---- config ----------------------------------------------------------------
# bot_write_config TOKEN CHAT_ID USER_ID [RELAY_AGENT] [ADMIN]
bot_write_config() {
  local token="$1" chat="$2" user="$3" agent="${4:-}" admin="${5:-true}"
  ensure_dir "$LLM2SSH_ETC" 0755 "root:root"
  {
    printf '# llm2ssh bot config — the token is a credential. Keep 0640 root:%s.\n' "$LLM2SSH_BOT_USER"
    printf 'TG_TOKEN=%q\n' "$token"
    printf 'OWNER_CHAT_ID=%q\n' "$chat"
    printf 'OWNER_USER_ID=%q\n' "$user"
    printf 'RELAY_AGENT=%q\n' "$agent"
    printf 'APPROVAL_TIMEOUT_S=%q\n' "60"
    printf 'RELAY_TIMEOUT_S=%q\n' "600"
    printf 'ALLOW_UNFREEZE=%q\n' "true"
    # Admin commands (onboard/grant/revoke/tools). The bot can NEVER grant full
    # or delete regardless — the admin wrapper hard-refuses those.
    printf 'BOT_ADMIN=%q\n' "$admin"
  } | atomic_write "$BOT_CONFIG" 0640 "root:$LLM2SSH_BOT_USER"
}

# ---- systemd unit ----------------------------------------------------------
bot_install_service() {
  local src="$LLM2SSH_LIB/systemd/llm2ssh-bot.service"
  [[ -f "$src" ]] || src="/usr/local/lib/llm2ssh/systemd/llm2ssh-bot.service"
  [[ -f "$src" ]] || { warn "bot service unit not found; skipping"; return 0; }
  install -m 0644 "$src" "$BOT_UNIT"
  # Only touch systemd when it's actually the init system (skips containers).
  if have_cmd systemctl && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload || true
    systemctl enable --now llm2ssh-bot.service 2>/dev/null || warn "could not start llm2ssh-bot (check: journalctl -u llm2ssh-bot)"
  else
    warn "systemd not running; unit installed but not started (start it where systemd is available)"
  fi
}

# ---- owner-gated callback decision (reused by the daemon) ------------------
# bot_msg_authorized FROM_ID CHAT_ID -> 0 iff the sender is the bound owner in the
# bound chat. Used by the daemon's message path (mirrors the callback gate). This
# is what makes a stray group binding harmless: commands from anyone but the owner
# are ignored, not just commands from other chats.
bot_msg_authorized() {
  [[ -n "${OWNER_USER_ID:-}" && "$1" == "$OWNER_USER_ID" && "$2" == "$OWNER_CHAT_ID" ]]
}

# bot_request_write_res ID DECISION [NOTE] — mint an access-request decision.
bot_request_write_res() {
  local id="$1" decision="$2" note="${3:-}" res tmp
  res="$REQUEST_RES/$id.json"; tmp="$REQUEST_RES/.$id.tmp.$$"
  jq -n --arg id "$id" --arg d "$decision" --arg n "$note" --argjson at "$(now_epoch)" \
     '{id:$id, decision:$d, note:$n, decided_at:$at}' >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  chmod 0640 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$res"
}

# bot_request_decide FROM_ID CHAT_ID CALLBACK_DATA -> handle an access-request
# button. Owner-gated. The requesting agent is taken from the req FILE OWNER
# (authoritative — an agent cannot request access for another user). The grant
# goes through the admin wrapper, which still refuses full/root-equivalent.
# Echoes the outcome word for the daemon to show; returns non-zero if the presser
# isn't the owner or the callback is malformed.
bot_request_decide() {
  local from="$1" chat="$2" data="$3"
  [[ "$from" == "${OWNER_USER_ID:-}" && "$chat" == "${OWNER_CHAT_ID:-}" ]] || return 1
  # The PROFILE comes from the callback (== what the owner saw on the card), NOT
  # re-read from the agent-owned file — otherwise the agent could bait-and-switch
  # to a more privileged profile after the card was sent.
  [[ "$data" =~ ^g:([0-9a-f]{8}):(1h|4h|1d|0|x):([a-z][a-z0-9-]{0,31})$ ]] || return 1
  local id="${BASH_REMATCH[1]}" ttl="${BASH_REMATCH[2]}" profile="${BASH_REMATCH[3]}"
  local reqf="$REQUEST_REQ/$id.json"
  [[ -f "$reqf" ]] || { printf 'expired'; return 0; }
  # The requesting AGENT is the file owner (authoritative — not spoofable).
  local agent
  agent="$(stat -c %U "$reqf" 2>/dev/null || echo '')"
  if [[ ! "$agent" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    bot_request_write_res "$id" error "malformed request"; rm -f "$reqf"; printf 'error'; return 0
  fi
  if [[ "$ttl" == "x" ]]; then
    bot_request_write_res "$id" denied ""; rm -f "$reqf"; printf 'denied'; return 0
  fi
  # Defense in depth: only requestable profiles, and never root-equivalent (the
  # admin wrapper also refuses these).
  if ! profile_is_requestable "$profile"; then
    bot_request_write_res "$id" error "'$profile' is not requestable"; rm -f "$reqf"; printf 'error'; return 0
  fi
  local args=(grant "$agent" "$profile")
  [[ "$ttl" != "0" ]] && args+=(--ttl "$ttl")
  if sudo -n "$BOT_ADMIN_BIN" "${args[@]}" >/dev/null 2>&1; then
    bot_request_write_res "$id" granted "$([[ "$ttl" == "0" ]] && echo permanent || echo "$ttl")"
    rm -f "$reqf"; printf 'granted'; return 0
  fi
  bot_request_write_res "$id" error "could not grant (needs the terminal?)"; rm -f "$reqf"; printf 'error'; return 0
}

# bot_decide FROM_ID CHAT_ID CALLBACK_DATA -> writes the approval res if and only
# if the presser is the bound owner. Returns non-zero (no decision) otherwise.
bot_decide() {
  local from_id="$1" chat_id="$2" data="$3"
  [[ "$from_id" == "${OWNER_USER_ID:-}" && "$chat_id" == "${OWNER_CHAT_ID:-}" ]] || return 1
  tg_valid_callback "$data" || return 1
  local rest="${data#a:}" id bit decision
  id="${rest%:*}"; bit="${rest##*:}"
  [[ "$bit" == "1" ]] && decision="allow" || decision="deny"
  approval_write_decision "$id" "$decision" "tg:$from_id" ""
}

# ---- CLI -------------------------------------------------------------------
cmd_bot() {
  local action="${1:-}"; shift || true
  case "$action" in
    setup)  _bot_setup "$@" ;;
    rotate) _bot_rotate "$@" ;;
    rebind) _bot_rebind "$@" ;;
    status) _bot_status ;;
    *) die_usage "usage: llm2ssh bot setup|rotate|rebind|status" ;;
  esac
}

_bot_status() {
  if [[ -f "$BOT_CONFIG" ]]; then
    log "bot configured (config: $BOT_CONFIG, perms $(stat -c '%a %U:%G' "$BOT_CONFIG" 2>/dev/null))"
    have_cmd systemctl && systemctl is-active llm2ssh-bot >/dev/null 2>&1 && log "service: active" || log "service: not active"
  else
    log "bot not configured (run: llm2ssh bot setup)"
  fi
}

_bot_setup() {
  local unattended=0 token="" chat="" user="" agent="" admin="true"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --unattended) unattended=1; shift ;;
      --token) token="${2:?}"; shift 2 ;;
      --chat-id) chat="${2:?}"; shift 2 ;;
      --user-id) user="${2:?}"; shift 2 ;;
      --agent) agent="${2:?}"; shift 2 ;;
      --no-admin) admin="false"; shift ;;
      *) die_usage "unknown flag for bot setup: $1" ;;
    esac
  done
  local admin_flag=0; [[ "$admin" == "true" ]] && admin_flag=1
  if [[ "$unattended" -eq 1 ]]; then
    [[ -n "$token" && -n "$chat" ]] || die_usage "unattended setup needs --token and --chat-id"
    [[ -n "$user" ]] || user="$chat"
    bot_write_config "$token" "$chat" "$user" "$agent" "$admin"
    bot_install_sudoers "$agent" "$admin_flag"
    bot_install_service
    log "bot configured (unattended, admin=$admin)"
    return 0
  fi

  # Interactive setup (needs network for the Telegram API).
  have_cmd jq || die "jq required"
  have_cmd curl || die "curl required for interactive setup"
  local tok
  read -r -s -p "Bot token from @BotFather: " tok; echo >&2
  [[ -n "$tok" ]] || die "no token entered"
  # `|| true`: curl returns non-zero on a bad token / network error, which under
  # `set -e` would abort silently. We want to inspect the body and report clearly.
  local me; me="$(TG_TOKEN="$tok" tg_call getMe || true)"
  [[ "$(jq -r '.ok // false' <<<"$me" 2>/dev/null)" == "true" ]] || die "token rejected by Telegram getMe (check the token / network)"
  local botname; botname="$(jq -r '.result.username' <<<"$me")"
  TG_TOKEN="$tok" tg_call deleteWebhook --data-urlencode 'drop_pending_updates=true' >/dev/null || true

  local code; code="$(tr -dc 'A-Z0-9' </dev/urandom | head -c 8)"
  log "Open this within 5 minutes to bind the bot to YOUR chat:"
  log "    https://t.me/${botname}?start=${code}"
  log "waiting for the /start handshake…"

  local deadline=$(( $(date +%s) + 300 )) offset=0 upd chat_id user_id="" payload
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    upd="$(TG_TOKEN="$tok" tg_call getUpdates --data-urlencode "timeout=20" --data-urlencode "offset=$offset" --data-urlencode 'allowed_updates=["message"]' || true)"
    [[ "$(jq -r '.ok // false' <<<"$upd" 2>/dev/null)" == "true" ]] || { sleep 2; continue; }
    local n; n="$(jq '.result | length' <<<"$upd")"
    local i
    for ((i=0; i<n; i++)); do
      offset="$(( $(jq -r ".result[$i].update_id" <<<"$upd") + 1 ))"
      payload="$(jq -r ".result[$i].message.text // empty" <<<"$upd")"
      if [[ "$payload" == "/start $code" ]]; then
        # Refuse to bind to a group/channel: there, other members could command
        # the bot. Require a 1:1 private chat.
        local ctype; ctype="$(jq -r ".result[$i].message.chat.type" <<<"$upd")"
        [[ "$ctype" == "private" ]] || die "the bot must be bound in a PRIVATE 1:1 chat, not a '$ctype'. Message the bot directly (not in a group) and re-run setup."
        chat_id="$(jq -r ".result[$i].message.chat.id" <<<"$upd")"
        user_id="$(jq -r ".result[$i].message.from.id" <<<"$upd")"
        break 2
      fi
    done
  done
  [[ -n "$user_id" ]] || die "handshake timed out; re-run 'llm2ssh bot setup'"

  read -r -p "Relay chat to which on-server agent (blank to disable relay): " agent
  bot_write_config "$tok" "$chat_id" "$user_id" "$agent" "$admin"
  bot_install_sudoers "$agent" "$admin_flag"
  bot_install_service
  TG_TOKEN="$tok" tg_call sendMessage --data-urlencode "chat_id=$chat_id" \
    --data-urlencode "text=✓ Bound. This bot now answers only you." >/dev/null || true
  log "bot bound to chat $chat_id and started"
}

_bot_rotate() {
  [[ -f "$BOT_CONFIG" ]] || die "bot not configured"
  # shellcheck disable=SC1090
  . "$BOT_CONFIG"
  local tok; read -r -s -p "New bot token: " tok; echo >&2
  [[ -n "$tok" ]] || die "no token entered"
  bot_write_config "$tok" "$OWNER_CHAT_ID" "$OWNER_USER_ID" "${RELAY_AGENT:-}"
  have_cmd systemctl && systemctl restart llm2ssh-bot 2>/dev/null || true
  log "token rotated (revoke the old one in @BotFather)"
}

_bot_rebind() {
  [[ -f "$BOT_CONFIG" ]] || die "bot not configured"
  # Re-run the interactive setup (re-enter token + redo the /start handshake).
  _bot_setup "$@"
}
