#!/usr/bin/env bats
# Profile parser + validator unit tests (sandbox; no root, no docker).

load helpers

setup() {
  setup_common
  # shellcheck disable=SC1090
  . "$LLM2SSH_LIB/lib/common.sh"
  . "$LLM2SSH_LIB/lib/state.sh"
  . "$LLM2SSH_LIB/lib/profile.sh"
  . "$LLM2SSH_LIB/lib/sudoers.sh"
}

@test "observer loads with no sudo and no groups" {
  profile_load observer
  [ "${#P_SUDO[@]}" -eq 0 ]
  [ "${#P_GROUPS[@]}" -eq 0 ]
  [ "$P_SUDO_ALL" -eq 0 ]
}

@test "observer-logs inherits observer and adds log groups" {
  profile_load observer-logs
  [[ " ${P_GROUPS[*]} " == *" adm "* ]]
  [[ " ${P_GROUPS[*]} " == *" systemd-journal "* ]]
}

@test "full sets sudo-all" {
  profile_load full
  [ "$P_SUDO_ALL" -eq 1 ]
}

@test "full renders sudo ALL and validates" {
  profile_load full
  run sudoers_render fullagent full never
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL=(ALL:ALL) NOPASSWD: ALL"* ]]
}

@test "denylisted binary in a custom profile is rejected" {
  mkdir -p "$LLM2SSH_PROFILES_ETC"
  cat >"$LLM2SSH_PROFILES_ETC/evil.profile" <<EOF
name evil
description tries to grant a root shell
sudo /bin/bash
EOF
  run profile_load evil
  [ "$status" -eq 3 ]   # EX_VALIDATION
  [[ "$output" == *"denylist"* ]]
}

@test "sudoers metacharacter in a custom profile is rejected" {
  mkdir -p "$LLM2SSH_PROFILES_ETC"
  cat >"$LLM2SSH_PROFILES_ETC/meta.profile" <<EOF
name meta
description sneaks an = into the spec
sudo /bin/echo a=b
EOF
  run profile_load meta
  [ "$status" -eq 3 ]
  [[ "$output" == *"metacharacter"* ]]
}

@test "unknown directive is rejected" {
  mkdir -p "$LLM2SSH_PROFILES_ETC"
  cat >"$LLM2SSH_PROFILES_ETC/typo.profile" <<EOF
name typo
sudoo /bin/ls
EOF
  run profile_load typo
  [ "$status" -eq 3 ]
  [[ "$output" == *"unknown profile directive"* ]]
}

@test "alias name is a valid sudoers identifier" {
  run sudoers_alias_name my-agent_1
  [ "$output" = "LLM2SSH_MY_AGENT_1" ]
}
