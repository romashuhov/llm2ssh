#!/usr/bin/env bats
# Self-update: `llm2ssh update` records/uses the git checkout it was installed from.

setup_file() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  if [ "$(id -u)" -ne 0 ]; then return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  command -v git >/dev/null 2>&1 || apt-get install -y -qq git >/dev/null 2>&1 || true
}

setup() {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root (run via test/run.sh)"; fi
  L=/usr/local/bin/llm2ssh
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "update without a recorded git source errors with clear guidance" {
  [ -x "$L" ] || bash "$REPO/install.sh" --no-tools >/dev/null 2>&1
  rm -f /usr/local/lib/llm2ssh/.source
  run "$L" update
  [ "$status" -ne 0 ]
  [[ "$output" == *"install"* ]]
}

@test "install records the git checkout for self-update" {
  if ! command -v git >/dev/null 2>&1; then skip "git not available"; fi
  if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then skip "test tree is not a git checkout"; fi
  bash "$REPO/install.sh" --no-tools >/dev/null 2>&1
  [ -f /usr/local/lib/llm2ssh/.source ]
  [ "$(cat /usr/local/lib/llm2ssh/.source)" = "$REPO" ]
}
