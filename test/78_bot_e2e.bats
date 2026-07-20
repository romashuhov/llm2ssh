#!/usr/bin/env bats
# End-to-end: the REAL `bot setup` handshake AND the REAL daemon, driven against a
# mock Telegram API. This is the test that catches "bot doesn't reply" / "setup
# never completes" bugs that pure-unit tests miss. Root; run via test/run.sh.

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

@test "bot setup completes the /start handshake and writes bot.env" {
  python3 "$REPO/test/mock_tg.py" & sleep 1
  rm -f /etc/llm2ssh/bot.env
  run timeout 30 env TG_API_BASE=http://127.0.0.1:8081 "$L" bot setup --token "111:FAKE" --user "@tester" </dev/null
  [[ "$output" == *"received"* ]]           # saw the incoming message
  [[ "$output" == *"bound to chat 42"* ]]   # completed
  [ -f /etc/llm2ssh/bot.env ]
  grep -q '^OWNER_CHAT_ID=42' /etc/llm2ssh/bot.env
  grep -q '^OWNER_USER_ID=42' /etc/llm2ssh/bot.env
}

@test "the running daemon replies to /start (and persists offset cleanly)" {
  # bot.env exists from the previous test; if run alone, write one.
  [ -f /etc/llm2ssh/bot.env ] || "$L" bot setup --unattended --token "111:FAKE" --chat-id 42 >/dev/null 2>&1
  rm -f /tmp/mock_sends.log
  python3 "$REPO/test/mock_tg.py" & sleep 1
  runuser -u llm2ssh-bot -- env TG_API_BASE=http://127.0.0.1:8081 LLM2SSH_LIB=/usr/local/lib/llm2ssh \
    /usr/local/lib/llm2ssh/bot/llm2ssh-botd >/tmp/botd.log 2>&1 &
  sleep 6
  grep -q 'text=llm2ssh' /tmp/mock_sends.log        # the "bot ready" reply reached Telegram
  ! grep -q 'Permission denied' /tmp/botd.log       # offset (and everything) writes cleanly
}
