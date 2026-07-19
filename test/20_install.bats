#!/usr/bin/env bats
# Installation integration test. Requires root; run inside a throwaway
# container (test/run.sh). Installs to the real prefixes and checks doctor.

load helpers

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "install.sh runs and places the CLI" {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root (run via test/run.sh)"; fi
  run bash "$REPO/install.sh" --no-tools
  [ "$status" -eq 0 ]
  [ -x /usr/local/bin/llm2ssh ]
  [ -f /usr/local/lib/llm2ssh/VERSION ]
}

@test "group and bot user exist after install" {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root"; fi
  getent group llm2ssh
  getent passwd llm2ssh-bot
}

@test "doctor passes on a fresh install" {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root"; fi
  run /usr/local/bin/llm2ssh doctor
  [ "$status" -eq 0 ]
}

@test "installed CLI resolves its own lib dir" {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root"; fi
  run env -u LLM2SSH_LIB /usr/local/bin/llm2ssh version
  [ "$status" -eq 0 ]
}
