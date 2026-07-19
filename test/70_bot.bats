#!/usr/bin/env bats
# M4: Telegram bot — pure helpers, config/sudoers generation, notifications,
# and the owner-gated callback decision. No network (Telegram is not reachable
# in CI); the daemon loop itself is reviewed, not run here.

setup_file() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  if [ "$(id -u)" -ne 0 ]; then return 0; fi
  bash "$REPO/install.sh" --no-tools >/dev/null 2>&1
  if [ ! -x /usr/bin/docker ]; then
    printf '#!/bin/sh\necho "fake docker $*"\n' >/usr/bin/docker
    chmod 0755 /usr/bin/docker; chown root:root /usr/bin/docker
  fi
}

setup() {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root (run via test/run.sh)"; fi
  L=/usr/local/bin/llm2ssh
  export LLM2SSH_LIB=/usr/local/lib/llm2ssh
  # shellcheck disable=SC1090
  . "$LLM2SSH_LIB/lib/common.sh"
  . "$LLM2SSH_LIB/lib/state.sh"
  . "$LLM2SSH_LIB/lib/notify.sh"
  . "$LLM2SSH_LIB/lib/approve.sh"
  . "$LLM2SSH_LIB/bot/tg-api.sh"
  . "$LLM2SSH_LIB/lib/profile.sh"
  . "$LLM2SSH_LIB/lib/sudoers.sh"
  . "$LLM2SSH_LIB/lib/bot.sh"
}

@test "tg_scrub redacts the bot token" {
  TG_TOKEN="12345:SECRETPART"
  run tg_scrub "GET https://api/bot12345:SECRETPART/getMe failed"
  [[ "$output" == *"<token>"* ]]
  [[ "$output" != *"SECRETPART"* ]]
}

@test "tg_valid_callback accepts good, rejects bad" {
  tg_valid_callback "a:0011ffaa:1"
  tg_valid_callback "a:0011ffaa:0"
  ! tg_valid_callback "a:0011ffaa:2"
  ! tg_valid_callback "a:NOTHEX00:1"
  ! tg_valid_callback "b:0011ffaa:1"
}

@test "split_message breaks long text into bounded chunks" {
  long="$(head -c 9000 /dev/zero | tr '\0' a)"
  out="$(printf '%s' "$long" | split_message)"
  ff="$(printf '%s' "$out" | tr -cd '\f' | wc -c)"
  [ "$ff" -ge 2 ]     # 9000 / 3900 => 3 chunks => 2 separators
}

@test "notify_emit writes a valid JSON notification" {
  rm -f /run/llm2ssh/notify/*.json 2>/dev/null || true
  notify_emit alert "disk almost full"
  f="$(ls -1 /run/llm2ssh/notify/*.json | head -1)"
  [ -n "$f" ]
  [ "$(jq -r .text "$f")" = "disk almost full" ]
  [ "$(jq -r .severity "$f")" = "alert" ]
  rm -f "$f"
}

@test "notify spool is NOT writable by an agent (anti-phishing)" {
  "$L" create nb1 --key "ssh-ed25519 AAAAtest a@ci" >/dev/null 2>&1 || true
  run runuser -u nb1 -- bash -c 'echo x > /run/llm2ssh/notify/evil.json'
  [ "$status" -ne 0 ]
  [ ! -f /run/llm2ssh/notify/evil.json ]
}

@test "bot setup --unattended writes a tight config and valid sudoers" {
  "$L" bot setup --unattended --token "111:AAA" --chat-id 4242 >/dev/null 2>&1
  [ -f /etc/llm2ssh/bot.env ]
  [ "$(stat -c '%a %U:%G' /etc/llm2ssh/bot.env)" = "640 root:llm2ssh-bot" ]
  visudo -cf /etc/sudoers.d/llm2ssh-bot
  grep -q 'freeze \*' /etc/sudoers.d/llm2ssh-bot
  grep -q 'unfreeze \*' /etc/sudoers.d/llm2ssh-bot
  grep -q 'status \*' /etc/sudoers.d/llm2ssh-bot
}

@test "bot sudoers with a relay agent still validates" {
  "$L" create relayer --key "ssh-ed25519 AAAAtest a@ci" >/dev/null 2>&1 || true
  "$L" bot setup --unattended --token "111:AAA" --chat-id 4242 --agent relayer >/dev/null 2>&1
  visudo -cf /etc/sudoers.d/llm2ssh-bot
  grep -q '(relayer) NOPASSWD.*relay-exec' /etc/sudoers.d/llm2ssh-bot
}

@test "bot_decide records an owner decision and rejects non-owner" {
  export OWNER_USER_ID=4242 OWNER_CHAT_ID=4242
  rm -f /run/llm2ssh/approvals/res/*.json 2>/dev/null || true
  bot_decide 4242 4242 "a:aabbccdd:1"
  [ -f /run/llm2ssh/approvals/res/aabbccdd.json ]
  [ "$(jq -r .decision /run/llm2ssh/approvals/res/aabbccdd.json)" = "allow" ]
  [ "$(jq -r .decided_by /run/llm2ssh/approvals/res/aabbccdd.json)" = "tg:4242" ]
  run bot_decide 9999 4242 "a:11223344:1"
  [ "$status" -ne 0 ]
  [ ! -f /run/llm2ssh/approvals/res/11223344.json ]
}

@test "bot_msg_authorized requires BOTH owner user id and chat id" {
  export OWNER_USER_ID=4242 OWNER_CHAT_ID=4242
  bot_msg_authorized 4242 4242            # owner in bound chat -> ok
  ! bot_msg_authorized 9999 4242          # other user in the (group) chat -> denied
  ! bot_msg_authorized 4242 9999          # owner in another chat -> denied
  unset OWNER_USER_ID
  ! bot_msg_authorized 4242 4242          # no bound owner -> denied
}

@test "bot service unit is installed and marks NoNewPrivileges=no" {
  [ -f /etc/systemd/system/llm2ssh-bot.service ]
  grep -q 'NoNewPrivileges=no' /etc/systemd/system/llm2ssh-bot.service
  grep -q 'User=llm2ssh-bot' /etc/systemd/system/llm2ssh-bot.service
}
