#!/usr/bin/env bats
# Function-level unit tests for lib/common.sh and lib/state.sh.

load helpers

setup() { setup_common; load_lib; }

@test "valid_agent_name accepts good names" {
  valid_agent_name "llmagent"
  valid_agent_name "agent_1"
  valid_agent_name "a-b-c"
  valid_agent_name "_svc"
}

@test "valid_agent_name rejects bad names" {
  ! valid_agent_name "1agent"        # starts with digit
  ! valid_agent_name "Agent"         # uppercase
  ! valid_agent_name "a b"           # space
  ! valid_agent_name "a;b"           # metacharacter
  ! valid_agent_name ""              # empty
  ! valid_agent_name "$(printf 'a%.0s' {1..40})"  # too long
}

@test "os_check passes for ubuntu, fails for arch" {
  os_check
  printf 'ID=arch\n' >"$LLM2SSH_ROOT/etc/os-release"
  run os_check
  [ "$status" -ne 0 ]
}

@test "state set/get/del roundtrip" {
  state_init myagent
  state_set myagent current_profile docker-ro
  [ "$(state_get myagent current_profile)" = "docker-ro" ]
  state_set myagent current_profile full
  [ "$(state_get myagent current_profile)" = "full" ]
  [ "$(state_get myagent missing_key fallback)" = "fallback" ]
  state_del myagent current_profile
  [ "$(state_get myagent current_profile default)" = "default" ]
}

@test "state file is 0600" {
  state_init a2
  state_set a2 k v
  mode="$(stat -c '%a' "$(agent_state_file a2)")"
  [ "$mode" = "600" ]
}

@test "list_agents enumerates created agents" {
  state_init alpha
  state_init beta
  run list_agents
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
}

@test "atomic_write installs with mode" {
  dest="$BATS_TEST_TMPDIR/f"
  printf 'hello\n' | atomic_write "$dest" 0640
  [ "$(cat "$dest")" = "hello" ]
  [ "$(stat -c '%a' "$dest")" = "640" ]
}
