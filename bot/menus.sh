# shellcheck shell=bash
# bot/menus.sh — inline-keyboard navigation for the Telegram bot. Callback data
# is namespaced (m:/hw:/ag:/af:/au:/av:/ag2:/agp:/agt:) and EVERY callback is
# owner-gated by the daemon (dispatch_callback) before it reaches here. Sourced
# by llm2ssh-botd after handlers.sh (uses bot_cmd_* and $L2 from there).

[[ -n "${_LLM2SSH_MENUS_SOURCED:-}" ]] && return 0
_LLM2SSH_MENUS_SOURCED=1

_menu_title() { printf '🤖 llm2ssh — %s' "$(hostname)"; }

# ---- keyboard builders (inline_keyboard JSON arrays) -----------------------
_kb_main() {
  jq -nc '[
    [{text:"👥 Agents",callback_data:"m:agents"},{text:"🖥 Hardware",callback_data:"m:hw"}],
    [{text:"🐳 Docker",callback_data:"m:docker"},{text:"📊 Status",callback_data:"m:status"}],
    [{text:"📋 Agent instructions",callback_data:"m:instr"},{text:"❓ Help",callback_data:"m:help"}]
  ]'
}
_kb_hw() {
  jq -nc '[
    [{text:"💾 Disk",callback_data:"hw:disk"},{text:"🧠 Memory",callback_data:"hw:mem"}],
    [{text:"⚙️ CPU",callback_data:"hw:cpu"},{text:"🌡 Temp",callback_data:"hw:temp"}],
    [{text:"📊 Top",callback_data:"hw:top"},{text:"🖥 Overview",callback_data:"hw:hwo"}],
    [{text:"« Menu",callback_data:"m:home"}]
  ]'
}
# single "back" row
_kb_back() { jq -nc --arg cd "$1" --arg t "${2:-« Back}" '[[{text:$t,callback_data:$cd}]]'; }

# agents list -> one button per agent + back
_kb_agents() {
  local arr n i a prof frozen label buttons='[]'
  arr="$(sudo -n "$L2" status --json 2>/dev/null || echo '[]')"
  n="$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)"
  for ((i=0; i<n; i++)); do
    a="$(jq -r ".[$i].agent" <<<"$arr")"
    prof="$(jq -r ".[$i].current_profile // \"?\"" <<<"$arr")"
    frozen="$(jq -r ".[$i].frozen // false" <<<"$arr")"
    label="$a · $prof"; [[ "$frozen" == true ]] && label="$a ❄️ $prof"
    buttons="$(jq -c --arg t "$label" --arg cd "ag:$a" '. + [[{text:$t,callback_data:$cd}]]' <<<"$buttons")"
  done
  jq -c '. + [[{text:"« Menu",callback_data:"m:home"}]]' <<<"$buttons"
}

# per-agent actions. Grant/Revoke only in admin mode; freeze/unfreeze always.
_kb_agent_actions() {
  local a="$1" frozen="$2" rows='[]' frbtn
  if [[ "$BOT_ADMIN" == "true" ]]; then
    rows="$(jq -c --arg g "ag2:$a" --arg v "av:$a" \
      '. + [[{text:"🔧 Grant…",callback_data:$g},{text:"↩ Revoke",callback_data:$v}]]' <<<"$rows")"
  fi
  if [[ "$frozen" == "true" ]]; then frbtn="$(jq -nc --arg cd "au:$a" '{text:"♻️ Unfreeze",callback_data:$cd}')"
  else frbtn="$(jq -nc --arg cd "af:$a" '{text:"❄️ Freeze",callback_data:$cd}')"; fi
  jq -c --argjson fr "$frbtn" '. + [[$fr,{text:"« Agents",callback_data:"m:agents"}]]' <<<"$rows"
}

# grant step 1: profile picker (excludes full / any sudo-all profile)
_kb_profiles() {
  local a="$1" f name seen=" " buttons='[]'
  for f in /etc/llm2ssh/profiles.d/*.profile /usr/local/lib/llm2ssh/profiles/*.profile; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f" .profile)"
    [[ "$seen" == *" $name "* ]] && continue
    seen+="$name "
    [[ "$name" == "full" ]] && continue
    grep -qE '^[[:space:]]*sudo-all[[:space:]]+yes' "$f" && continue
    # keep callback_data within Telegram's 64-byte limit
    [[ "${#a}" -gt 20 || "${#name}" -gt 24 ]] && continue
    buttons="$(jq -c --arg t "$name" --arg cd "agp:$a:$name" '. + [[{text:$t,callback_data:$cd}]]' <<<"$buttons")"
  done
  jq -c --arg cd "ag:$a" '. + [[{text:"« Cancel",callback_data:$cd}]]' <<<"$buttons"
}

# grant step 2: duration picker
_kb_duration() {
  local a="$1" p="$2"
  jq -nc --arg h1 "agt:$a:$p:1h" --arg h4 "agt:$a:$p:4h" --arg d1 "agt:$a:$p:1d" \
         --arg pm "agt:$a:$p:perm" --arg back "ag:$a" '[
    [{text:"⏱ 1h",callback_data:$h1},{text:"⏱ 4h",callback_data:$h4}],
    [{text:"⏱ 1d",callback_data:$d1},{text:"♾ Forever",callback_data:$pm}],
    [{text:"« Cancel",callback_data:$back}]
  ]'
}

# ---- sending / editing ------------------------------------------------------
# bot_send_menu CHAT [banner] — send a fresh main menu.
bot_send_menu() {
  local chat="$1" banner="${2:-}" text
  text="$(_menu_title)"$'\n'"Tap to navigate:"
  [[ -n "$banner" ]] && text="$banner"$'\n\n'"$text"
  tg_send_keyboard "$chat" "$text" "$(_kb_main)"
}

_menu_agent() {
  local chat="$1" msgid="$2" a="$3"
  if ! id -u "$a" >/dev/null 2>&1; then
    tg_edit_keyboard "$chat" "$msgid" "no such agent: $a" "$(_kb_back m:agents '« Agents')"; return
  fi
  local frozen; frozen="$(sudo -n "$L2" status "$a" --json 2>/dev/null | jq -r '.frozen // false')"
  tg_edit_keyboard "$chat" "$msgid" "$(bot_cmd_agent "$a")" "$(_kb_agent_actions "$a" "$frozen")"
}

_menu_do_grant() {
  local chat="$1" msgid="$2" data="$3" rest a p code args out
  rest="${data#agt:}"; a="${rest%%:*}"; rest="${rest#*:}"; p="${rest%%:*}"; code="${rest##*:}"
  args=(grant "$a" "$p")
  case "$code" in 1h) args+=(--ttl 1h);; 4h) args+=(--ttl 4h);; 1d) args+=(--ttl 1d);; esac
  out="$(_admin "${args[@]}" 2>&1)"
  tg_edit_keyboard "$chat" "$msgid" "🔧 $a → $p"$'\n'"$out" "$(_kb_back "ag:$a" '« Agent')"
}

# bot_menu_callback DATA CHAT MSGID — route an (already owner-verified) callback.
bot_menu_callback() {
  local data="$1" chat="$2" msgid="$3" a rest p
  case "$data" in
    m:home)   tg_edit_keyboard "$chat" "$msgid" "$(_menu_title)"$'\n'"Tap to navigate:" "$(_kb_main)" ;;
    m:hw)     tg_edit_keyboard "$chat" "$msgid" "🖥 Hardware — pick a readout:" "$(_kb_hw)" ;;
    m:agents) tg_edit_keyboard "$chat" "$msgid" "👥 Agents — tap one:" "$(_kb_agents)" ;;
    m:docker) tg_edit_keyboard "$chat" "$msgid" "$(bot_cmd_docker)" "$(_kb_back m:home '« Menu')" ;;
    m:status) tg_edit_keyboard "$chat" "$msgid" "$(bot_cmd_status)" "$(_kb_back m:home '« Menu')" ;;
    m:instr)  tg_edit_keyboard "$chat" "$msgid" "$("$L2" instructions 2>/dev/null | head -c 3500)" "$(_kb_back m:home '« Menu')" ;;
    m:help)   tg_edit_keyboard "$chat" "$msgid" "$(bot_cmd_help "$BOT_ADMIN")" "$(_kb_back m:home '« Menu')" ;;
    hw:disk)  tg_edit_keyboard "$chat" "$msgid" "$(bot_cmd_disk)" "$(_kb_back m:hw '« Hardware')" ;;
    hw:mem)   tg_edit_keyboard "$chat" "$msgid" "$(bot_cmd_mem)"  "$(_kb_back m:hw '« Hardware')" ;;
    hw:cpu)   tg_edit_keyboard "$chat" "$msgid" "$(bot_cmd_cpu)"  "$(_kb_back m:hw '« Hardware')" ;;
    hw:temp)  tg_edit_keyboard "$chat" "$msgid" "$(bot_cmd_temp)" "$(_kb_back m:hw '« Hardware')" ;;
    hw:top)   tg_edit_keyboard "$chat" "$msgid" "$(bot_cmd_top)"  "$(_kb_back m:hw '« Hardware')" ;;
    hw:hwo)   tg_edit_keyboard "$chat" "$msgid" "$(bot_cmd_hw)"   "$(_kb_back m:hw '« Hardware')" ;;
    ag:*)  _menu_agent "$chat" "$msgid" "${data#ag:}" ;;
    af:*)  a="${data#af:}"; sudo -n "$L2" freeze "$a"   >/dev/null 2>&1; _menu_agent "$chat" "$msgid" "$a" ;;
    au:*)  a="${data#au:}"; sudo -n "$L2" unfreeze "$a" >/dev/null 2>&1; _menu_agent "$chat" "$msgid" "$a" ;;
    av:*)  a="${data#av:}"; _admin revoke "$a" >/dev/null 2>&1; _menu_agent "$chat" "$msgid" "$a" ;;
    ag2:*) a="${data#ag2:}"; tg_edit_keyboard "$chat" "$msgid" "🔧 Grant to $a — pick a profile:" "$(_kb_profiles "$a")" ;;
    agp:*) rest="${data#agp:}"; a="${rest%%:*}"; p="${rest#*:}"
           tg_edit_keyboard "$chat" "$msgid" "🔧 $a → $p — for how long?" "$(_kb_duration "$a" "$p")" ;;
    agt:*) _menu_do_grant "$chat" "$msgid" "$data" ;;
    *) : ;;
  esac
}
