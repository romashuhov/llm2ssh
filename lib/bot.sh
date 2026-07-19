# shellcheck shell=bash
# lib/bot.sh — Telegram bot setup and the security-critical bits: least-privilege
# sudoers, config file with tight perms, the owner-gated callback decision, and
# the systemd unit. The daemon itself lives in bot/llm2ssh-botd.

[[ -n "${_LLM2SSH_BOT_SOURCED:-}" ]] && return 0
_LLM2SSH_BOT_SOURCED=1

BOT_CONFIG="$LLM2SSH_ETC/bot.env"
BOT_SUDOERS="$LLM2SSH_SUDOERSD/llm2ssh-bot"
BOT_UNIT="/etc/systemd/system/llm2ssh-bot.service"
BOT_RELAY_BIN="/usr/local/lib/llm2ssh/bin/relay-exec"
BOT_ADMIN_BIN="/usr/local/lib/llm2ssh/bin/llm2ssh-bot-admin"

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
  local me; me="$(TG_TOKEN="$tok" tg_call getMe)"
  [[ "$(jq -r '.ok // false' <<<"$me")" == "true" ]] || die "token rejected by Telegram getMe"
  local botname; botname="$(jq -r '.result.username' <<<"$me")"
  TG_TOKEN="$tok" tg_call deleteWebhook --data-urlencode 'drop_pending_updates=true' >/dev/null || true

  local code; code="$(tr -dc 'A-Z0-9' </dev/urandom | head -c 8)"
  log "Open this within 5 minutes to bind the bot to YOUR chat:"
  log "    https://t.me/${botname}?start=${code}"
  log "waiting for the /start handshake…"

  local deadline=$(( $(date +%s) + 300 )) offset=0 upd chat_id user_id="" payload
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    upd="$(TG_TOKEN="$tok" tg_call getUpdates --data-urlencode "timeout=20" --data-urlencode "offset=$offset" --data-urlencode 'allowed_updates=["message"]')"
    [[ "$(jq -r '.ok // false' <<<"$upd")" == "true" ]] || { sleep 2; continue; }
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
