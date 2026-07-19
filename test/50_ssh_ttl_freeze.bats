#!/usr/bin/env bats
# M2: connect-info, live context, TTL expiry, freeze/unfreeze, audit log.
# Root; run inside a container via test/run.sh.

TESTKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYplaceholder0000000000000000000000 a@ci"

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
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  L=/usr/local/bin/llm2ssh
  "$L" create a1 --key "$TESTKEY" >/dev/null 2>&1 || true
}

@test "create generates a live context readable via llm2ssh-ctx as the agent" {
  run runuser -u a1 -- /usr/local/bin/llm2ssh-ctx
  [ "$status" -eq 0 ]
  [[ "$output" == *"Current profile"* ]]
  [[ "$output" == *"observer"* ]]
}

@test "context updates when the profile changes" {
  "$L" grant a1 docker-ro
  run runuser -u a1 -- /usr/local/bin/llm2ssh-ctx
  [[ "$output" == *"docker-ro"* ]]
  [[ "$output" == *"sudo"* ]]
  "$L" revoke a1
}

@test "connect-info prints an ssh config block" {
  run "$L" connect-info a1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Host llm-a1"* ]]
  [[ "$output" == *"User a1"* ]]
  [[ "$output" == *"llm2ssh-ctx"* ]]
}

@test "sudo activity shows up in llm2ssh log" {
  "$L" grant a1 docker-ro
  runuser -u a1 -- sudo -n /usr/bin/docker ps >/dev/null 2>&1 || true
  run "$L" log a1 --sudo-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker"* ]]
  "$L" revoke a1
}

@test "TTL expiry falls back to base profile on _gc" {
  "$L" grant a1 docker-ro --ttl 1s
  [ -f /etc/sudoers.d/llm2ssh-a1 ]
  sleep 2
  "$L" _gc
  [ ! -f /etc/sudoers.d/llm2ssh-a1 ]
  [ "$(sed -n 's/.*current_profile=//p' /var/lib/llm2ssh/agents/a1/state)" = "observer" ]
}

@test "freeze revokes sudo, disables the account, and sets the flag" {
  "$L" grant a1 docker-ro
  "$L" freeze a1 --reason "test"
  [ ! -f /etc/sudoers.d/llm2ssh-a1 ]
  [ -f /etc/llm2ssh/keys/a1.frozen ]
  [ ! -f /etc/llm2ssh/keys/a1 ]
  [ -f /run/llm2ssh/agents/a1.frozen ]
  [ "$(sed -n 's/.*frozen=//p' /var/lib/llm2ssh/agents/a1/state | head -1)" = "1" ]
  # account expiry blocks all auth (the correct lock, unlike usermod -L)
  chage -l a1 | grep -qi 'Account expires'
  "$L" unfreeze a1
}

@test "freeze kills a running process owned by the agent" {
  setsid runuser -u a1 -- sleep 300 >/dev/null 2>&1 &
  sleep 1
  pid="$(pgrep -u a1 -f 'sleep 300' | head -1)"
  [ -n "$pid" ]
  "$L" freeze a1
  sleep 1
  run kill -0 "$pid"
  [ "$status" -ne 0 ]              # process is gone
  "$L" unfreeze a1
}

@test "grant/revoke are refused while frozen" {
  "$L" freeze a1
  run "$L" grant a1 docker-ro
  [ "$status" -ne 0 ]
  [[ "$output" == *"frozen"* ]]
  "$L" unfreeze a1
}

@test "unfreeze never resurrects a grant that expired while frozen" {
  "$L" grant a1 docker-ro --ttl 1s
  "$L" freeze a1
  sleep 2
  "$L" unfreeze a1
  # expired while frozen -> back to base, no sudoers
  [ ! -f /etc/sudoers.d/llm2ssh-a1 ]
  [ "$(sed -n 's/.*current_profile=//p' /var/lib/llm2ssh/agents/a1/state)" = "observer" ]
}

@test "unfreeze restores an active grant" {
  "$L" grant a1 docker-ro
  "$L" freeze a1
  "$L" unfreeze a1
  [ -f /etc/sudoers.d/llm2ssh-a1 ]
  [ -f /etc/llm2ssh/keys/a1 ]
  [ ! -f /etc/llm2ssh/keys/a1.frozen ]
}

@test "sshd drop-in is effective for the agent (M7 check)" {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null 2>&1 || skip "cannot install openssh-server"
  ssh-keygen -A >/dev/null 2>&1 || true
  bash "$REPO/install.sh" --no-tools >/dev/null 2>&1   # now that sshd exists, installs the drop-in
  [ -f /etc/ssh/sshd_config.d/60-llm2ssh.conf ]
  sshd -t
  out="$(sshd -T -C user=a1,host=x.invalid,addr=203.0.113.1 2>/dev/null)"
  echo "$out" | grep -qi 'authorizedkeysfile .*etc/llm2ssh/keys'
  echo "$out" | grep -qi 'passwordauthentication no'
  # and doctor should now confirm it
  run "$L" doctor
  [[ "$output" == *"sshd effective for a1"* ]]
}
