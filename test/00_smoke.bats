#!/usr/bin/env bats
# Smoke tests for the CLI dispatcher (no root required).

load helpers

setup() { setup_common; }

@test "version prints a version string" {
  run "$LLM2SSH" version
  [ "$status" -eq 0 ]
  [[ "$output" == llm2ssh\ * ]]
}

@test "help lists core commands" {
  run "$LLM2SSH" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"grant <agent>"* ]]
  [[ "$output" == *"freeze"* ]]
}

@test "unknown command exits 2 (usage)" {
  run "$LLM2SSH" frobnicate
  [ "$status" -eq 2 ]
}

@test "list on an empty install succeeds" {
  run "$LLM2SSH" list
  [ "$status" -eq 0 ]
}

@test "list --json emits a JSON array" {
  run "$LLM2SSH" list --json
  [ "$status" -eq 0 ]
  [[ "$output" == "["*"]" ]]
}

@test "mutating command as non-root is refused" {
  if [ "$(id -u)" -eq 0 ]; then skip "running as root"; fi
  run "$LLM2SSH" create testagent
  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
}
