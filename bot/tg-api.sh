# shellcheck shell=bash
# TG_MSG_MAX and other module constants are consumed by llm2ssh-botd.
# shellcheck disable=SC2034
# bot/tg-api.sh — all Telegram Bot API access, plus pure helpers (message
# splitting, token scrubbing, callback validation). Sourced by llm2ssh-botd and
# by tests. Network functions need $TG_TOKEN in the environment (from bot.env).
#
# Non-negotiable coding rules (what makes bash safe here):
#   * every JSON value is built with jq --arg / parsed with jq -r (no interpolation)
#   * the token is NEVER echoed into logs (tg_scrub redacts it)
#   * outbound sends are serialized + rate-limited (Telegram per-chat guidance)

[[ -n "${_LLM2SSH_TGAPI_SOURCED:-}" ]] && return 0
_LLM2SSH_TGAPI_SOURCED=1

: "${TG_API_BASE:=https://api.telegram.org}"   # overridable for tests
TG_MSG_MAX=4096
TG_SPLIT_AT=3900
TG_MIN_INTERVAL=1                              # seconds between sends per chat
_TG_LAST_SEND=0

# ---- Pure helpers (unit-tested; no network) --------------------------------

# tg_scrub STRING — redact the bot token from arbitrary text before logging.
tg_scrub() {
  local s="$*"
  [[ -n "${TG_TOKEN:-}" ]] && s="${s//$TG_TOKEN/<token>}"
  printf '%s' "$s"
}

# tg_valid_callback DATA — 0 if DATA matches the strict callback format a:<8hex>:<0|1>.
tg_valid_callback() { [[ "$1" =~ ^a:[0-9a-f]{8}:[01]$ ]]; }

# split_message  (text on stdin) — emit chunks <= TG_SPLIT_AT, preferring to
# break on the last newline within the window. Prints a NUL-free stream where
# each chunk is separated by a form-feed (\f) so callers can iterate safely.
split_message() {
  local text; text="$(cat)"
  while [[ -n "$text" ]]; do
    if [[ "${#text}" -le "$TG_SPLIT_AT" ]]; then
      printf '%s' "$text"; break
    fi
    local window="${text:0:$TG_SPLIT_AT}" cut
    # prefer last newline in the window; else hard cut
    if [[ "$window" == *$'\n'* ]]; then
      cut="${window%$'\n'*}"
    else
      cut="$window"
    fi
    printf '%s\f' "$cut"
    text="${text:${#cut}}"
    # drop a single leading newline left by the split
    [[ "$text" == $'\n'* ]] && text="${text:1}"
  done
}

# ---- Network functions (need $TG_TOKEN) ------------------------------------

# _tg_curl METHOD [curl args...] — the token-bearing URL is written to a curl
# config file with the printf BUILTIN (no separate process), so the token never
# appears in any process's /proc/<pid>/cmdline. curl's argv holds only `-K <file>`.
# The config file is mode 0600 and, under the systemd unit's PrivateTmp, isolated
# from the agent entirely.
_tg_curl() {
  local method="$1"; shift
  local cfg; cfg="$(mktemp "${TMPDIR:-/tmp}/l2tg.XXXXXX")" || return 1
  chmod 600 "$cfg" 2>/dev/null || true
  printf 'url = "%s/bot%s/%s"\n' "$TG_API_BASE" "$TG_TOKEN" "$method" >"$cfg"
  local rc=0
  curl -sS --fail-with-body --max-time 70 -K "$cfg" "$@" 2>/dev/null || rc=$?
  rm -f "$cfg"
  return "$rc"
}

# tg_call METHOD [curl --data-urlencode k=v ...] — returns response body on stdout.
tg_call() { _tg_curl "$@"; }

_tg_rate_limit() {
  local now; now="$(date +%s)"
  local wait=$(( TG_MIN_INTERVAL - (now - _TG_LAST_SEND) ))
  [[ "$wait" -gt 0 ]] && sleep "$wait"
  _TG_LAST_SEND="$(date +%s)"
}

# tg_send_message CHAT_ID TEXT [PARSE_MODE] — splits long text, honors rate limit
# and 429 retry_after. PARSE_MODE default: none (plain text never 400s).
tg_send_message() {
  local chat="$1" text="$2" parse="${3:-}"
  local chunk
  while IFS= read -r -d $'\f' chunk || [[ -n "$chunk" ]]; do
    [[ -z "$chunk" ]] && continue
    _tg_send_one "$chat" "$chunk" "$parse"
  done < <(printf '%s' "$text" | split_message)
}

_tg_send_one() {
  local chat="$1" text="$2" parse="${3:-}" resp retry
  local args=(--data-urlencode "chat_id=$chat" --data-urlencode "text=$text")
  [[ -n "$parse" ]] && args+=(--data-urlencode "parse_mode=$parse")
  _tg_rate_limit
  resp="$(tg_call sendMessage "${args[@]}")"
  # 429? honor retry_after and retry once.
  if [[ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    retry="$(jq -r '.parameters.retry_after // empty' <<<"$resp" 2>/dev/null)"
    if [[ -n "$retry" ]]; then sleep "$retry"; tg_call sendMessage "${args[@]}" >/dev/null; fi
  fi
}

# tg_send_keyboard CHAT_ID TEXT KEYBOARD_JSON — inline keyboard (approvals).
tg_send_keyboard() {
  local chat="$1" text="$2" kb="$3"
  _tg_rate_limit
  tg_call sendMessage \
    --data-urlencode "chat_id=$chat" \
    --data-urlencode "text=$text" \
    --data-urlencode "reply_markup=$(jq -nc --argjson k "$kb" '{inline_keyboard:$k}')" \
    >/dev/null
}

tg_edit_message() {
  local chat="$1" msgid="$2" text="$3"
  tg_call editMessageText \
    --data-urlencode "chat_id=$chat" --data-urlencode "message_id=$msgid" \
    --data-urlencode "text=$text" >/dev/null
}

tg_answer_callback() {
  local cbid="$1" text="${2:-}"
  tg_call answerCallbackQuery --data-urlencode "callback_query_id=$cbid" \
    --data-urlencode "text=$text" >/dev/null
}

# tg_send_document CHAT_ID FILE CAPTION — multipart upload for long output.
tg_send_document() {
  local chat="$1" file="$2" caption="${3:-}"
  _tg_rate_limit
  _tg_curl sendDocument --max-time 120 \
    -F "chat_id=$chat" -F "document=@$file" -F "caption=$caption" >/dev/null 2>&1
}
