#!/usr/bin/env bats
# onboard: one-shot create + server-side keygen + paste-into-chat bootstrap.

setup_file() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  if [ "$(id -u)" -ne 0 ]; then return 0; fi
  [ -x /usr/local/bin/llm2ssh ] || bash "$REPO/install.sh" --no-tools >/dev/null 2>&1
  if [ ! -x /usr/bin/docker ]; then
    printf '#!/bin/sh\necho "fake docker $*"\n' >/usr/bin/docker
    chmod 0755 /usr/bin/docker; chown root:root /usr/bin/docker
  fi
}

setup() {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root (run via test/run.sh)"; fi
  L=/usr/local/bin/llm2ssh
}

@test "onboard creates the agent, installs a key, and prints a paste blob" {
  run "$L" onboard ob1
  [ "$status" -eq 0 ]
  getent passwd ob1
  [ -s /etc/llm2ssh/keys/ob1 ]
  grep -q 'ssh-ed25519' /etc/llm2ssh/keys/ob1
  [ "$(stat -c '%U' /etc/llm2ssh/keys/ob1)" = "root" ]
  # the blob carries a usable private key + ready ssh config + usage
  [[ "$output" == *"BEGIN OPENSSH PRIVATE KEY"* ]]
  [[ "$output" == *"Host llm-ob1"* ]]
  [[ "$output" == *"User ob1"* ]]
  [[ "$output" == *"ssh llm-ob1 llm2ssh-ctx"* ]]
  # default profile is observer -> no sudo granted
  [ ! -f /etc/sudoers.d/llm2ssh-ob1 ]
  "$L" delete ob1 --yes
}

@test "onboard --profile starts with more access; --replace rotates the key" {
  "$L" onboard ob2 --profile docker-ro >/dev/null
  [ -f /etc/sudoers.d/llm2ssh-ob2 ]                 # docker-ro granted at onboarding
  before="$(md5sum /etc/llm2ssh/keys/ob2 | awk '{print $1}')"
  "$L" onboard ob2 --replace >/dev/null
  after="$(md5sum /etc/llm2ssh/keys/ob2 | awk '{print $1}')"
  [ "$before" != "$after" ]                          # key file changed
  [ "$(grep -c 'ssh-ed25519' /etc/llm2ssh/keys/ob2)" -eq 1 ]   # old key dropped
  "$L" delete ob2 --yes
}
