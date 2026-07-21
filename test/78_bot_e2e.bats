#!/usr/bin/env bats
# End-to-end: one-command pairing setup + the REAL daemon pairing and replying,
# driven against a mock Telegram API. This is the test that catches "bot doesn't
# reply" / "setup never completes" bugs that pure-unit tests miss.

setup_file() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  if [ "$(id -u)" -ne 0 ]; then return 0; fi
  [ -x /usr/local/bin/llm2ssh ] || bash "$REPO/install.sh" --no-tools >/dev/null 2>&1
}

setup() {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root (run via test/run.sh)"; fi
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  L=/usr/local/bin/llm2ssh
}

teardown() {
  pkill -f 'mock_tg.py' 2>/dev/null || true
  pkill -9 -u llm2ssh-bot 2>/dev/null || true
}

@test "bot setup is one non-blocking command (pairing mode, no owner yet)" {
  python3 "$REPO/test/mock_tg.py" & sleep 1
  rm -f /etc/llm2ssh/bot.env /var/lib/llm2ssh-bot/owner
  run timeout 20 env TG_API_BASE=http://127.0.0.1:8081 "$L" bot setup --token "111:FAKE" --user "@tester" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"is running"* ]]              # returned immediately, no handshake wait
  [ -f /etc/llm2ssh/bot.env ]
  grep -q '^PAIR_USER=tester' /etc/llm2ssh/bot.env
  [ ! -f /var/lib/llm2ssh-bot/owner ]            # not bound until the first message
}

@test "the daemon PAIRS on the first message, then answers with a menu" {
  rm -f /var/lib/llm2ssh-bot/owner /tmp/mock_sends.log
  python3 "$REPO/test/mock_tg.py" & sleep 1
  # pairing config: empty owner, PAIR_USER=tester (matches the mock's sender)
  "$L" bot setup --token "111:FAKE" --user "@tester" </dev/null >/dev/null 2>&1 || true
  rm -f /var/lib/llm2ssh-bot/owner
  runuser -u llm2ssh-bot -- env TG_API_BASE=http://127.0.0.1:8081 LLM2SSH_LIB=/usr/local/lib/llm2ssh \
    /usr/local/lib/llm2ssh/bot/llm2ssh-botd >/tmp/botd.log 2>&1 &
  sleep 6
  [ -f /var/lib/llm2ssh-bot/owner ]                       # paired
  grep -q '^OWNER_CHAT_ID=42' /var/lib/llm2ssh-bot/owner
  grep -q 'reply_markup' /tmp/mock_sends.log             # sent the inline menu
  ! grep -q 'Permission denied' /tmp/botd.log
}

@test "menu keyboards are well-formed inline_keyboard JSON" {
  run bash -c '
    export LLM2SSH_LIB=/usr/local/lib/llm2ssh
    . /usr/local/lib/llm2ssh/lib/common.sh
    . /usr/local/lib/llm2ssh/bot/handlers.sh
    . /usr/local/lib/llm2ssh/bot/menus.sh
    _kb_main | jq -e "type==\"array\" and (.[0][0].callback_data==\"m:agents\")" >/dev/null || exit 1
    _kb_hw   | jq -e ".[0][0].callback_data==\"hw:disk\"" >/dev/null || exit 2
    _kb_duration a1 docker-ro | jq -e ".[0][0].callback_data==\"agt:a1:docker-ro:1h\"" >/dev/null || exit 3
    echo OK'
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}
