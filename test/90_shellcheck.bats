#!/usr/bin/env bats
# Static analysis gate: every shell script must pass shellcheck -S warning.

@test "shellcheck is clean across all scripts" {
  if ! command -v shellcheck >/dev/null 2>&1; then skip "shellcheck not installed"; fi
  run bash "$BATS_TEST_DIRNAME/shellcheck.sh"
  echo "$output"
  [ "$status" -eq 0 ]
}
