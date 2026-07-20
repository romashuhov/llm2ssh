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

@test "interactive 'bot setup' loads the Telegram API layer (regression for tg_call not found)" {
  # The CLI must source bot/tg-api.sh so `bot setup` doesn't die with
  # 'tg_call: command not found'. Point the API at a dead port to fail fast.
  run bash -c "printf 'faketoken\n' | TG_API_BASE=http://127.0.0.1:9 /usr/local/bin/llm2ssh bot setup"
  [ "$status" -ne 0 ]
  [[ "$output" != *"tg_call"* ]]      # the function WAS defined (no 'command not found')
  [[ "$output" == *"rejected"* ]]     # reached the getMe token check
}

@test "_bot_gen_code returns an 8-char code under set -euo pipefail (SIGPIPE regression)" {
  # With a valid token, setup reached this code-gen; the old `urandom | head`
  # SIGPIPE'd and aborted setup silently. Verify it survives strict mode.
  run bash -c "set -euo pipefail; export LLM2SSH_LIB=/usr/local/lib/llm2ssh; . \$LLM2SSH_LIB/lib/common.sh; . \$LLM2SSH_LIB/lib/bot.sh; c=\$(_bot_gen_code); echo len=\${#c}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"len=8"* ]]
}

@test "bot setup --token skips the terminal prompt (works with no stdin)" {
  # Regression: passing --token must bypass the interactive read entirely, so it
  # works where stdin/tty is unavailable (e.g. sudo on a NAS). Dead API + no stdin.
  run bash -c "TG_API_BASE=http://127.0.0.1:9 /usr/local/bin/llm2ssh bot setup --token '111:FAKE' </dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected"* ]]     # reached getMe (did NOT block on read)
  [[ "$output" != *"no token"* ]]     # did NOT fall into the empty-token path
}

@test "bot setup accepts --user and still validates the token first" {
  run bash -c "TG_API_BASE=http://127.0.0.1:9 /usr/local/bin/llm2ssh bot setup --token '111:FAKE' --user '@someone' </dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected"* ]]     # parsed --user, reached getMe (didn't choke on the flag)
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

@test "hardware handlers (/disk /mem /cpu /hw) produce output" {
  run bash -c '
    export LLM2SSH_LIB=/usr/local/lib/llm2ssh
    . /usr/local/lib/llm2ssh/lib/common.sh
    . /usr/local/lib/llm2ssh/bot/handlers.sh
    case "$(bot_cmd_disk)" in *disk*) ;; *) echo "disk FAIL"; exit 1;; esac
    case "$(bot_cmd_mem)"  in *memory*) ;; *) echo "mem FAIL";  exit 2;; esac
    case "$(bot_cmd_cpu)"  in *load*) ;; *) echo "cpu FAIL";  exit 3;; esac
    case "$(bot_cmd_hw)"   in *cpu:*) ;; *) echo "hw FAIL";   exit 4;; esac
    echo OK'
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "/agents panel shows agent uid, profile and session state" {
  "$L" create panelagent --key "ssh-ed25519 AAAAtest a@ci" >/dev/null 2>&1 || true
  "$L" grant panelagent docker-ro >/dev/null 2>&1 || true
  run bash -c '
    export LLM2SSH_LIB=/usr/local/lib/llm2ssh
    . /usr/local/lib/llm2ssh/lib/common.sh
    . /usr/local/lib/llm2ssh/bot/handlers.sh
    bot_cmd_agents'
  [ "$status" -eq 0 ]
  [[ "$output" == *"panelagent"* ]]
  [[ "$output" == *"docker-ro"* ]]
  [[ "$output" == *"uid"* ]]
  [[ "$output" == *"idle"* || "$output" == *"session"* ]]
  "$L" delete panelagent --yes >/dev/null 2>&1 || true
}

@test "bot service unit is installed and marks NoNewPrivileges=no" {
  [ -f /etc/systemd/system/llm2ssh-bot.service ]
  grep -q 'NoNewPrivileges=no' /etc/systemd/system/llm2ssh-bot.service
  grep -q 'User=llm2ssh-bot' /etc/systemd/system/llm2ssh-bot.service
}
