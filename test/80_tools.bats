#!/usr/bin/env bats
# M-tools: monitoring/utility installation, config overrides (which also proves
# /etc/llm2ssh/config is now sourced), and the observer-hw profile.

setup_file() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  if [ "$(id -u)" -ne 0 ]; then return 0; fi
  [ -x /usr/local/bin/llm2ssh ] || bash "$REPO/install.sh" --no-tools >/dev/null 2>&1
  # Fake, root-owned hardware tools so observer-hw validates without apt.
  for b in /usr/sbin/dmidecode /usr/sbin/smartctl; do
    [ -x "$b" ] || { printf '#!/bin/sh\necho fake\n' >"$b"; chmod 0755 "$b"; chown root:root "$b"; }
  done
}

setup() {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root (run via test/run.sh)"; fi
  L=/usr/local/bin/llm2ssh
  CFG=/etc/llm2ssh/config
}

teardown() {
  # Strip any test overrides we appended to the config.
  [ -f "$CFG" ] && sed -i '/^LLM2SSH_TOOLS=/d;/^LLM2SSH_EXTRA_DENYLIST="echo"/d' "$CFG" 2>/dev/null || true
}

@test "tools list shows the curated default packages" {
  run "$L" tools list
  [ "$status" -eq 0 ]
  [[ "$output" == *"htop"* ]]
  [[ "$output" == *"sysstat"* ]]
  [[ "$output" == *"lsof"* ]]
}

@test "tools install actually installs a package (idempotent)" {
  "$L" tools install tree >/dev/null 2>&1
  dpkg -s tree >/dev/null 2>&1
  run "$L" tools list
  [[ "$output" == *"tree"* ]]
}

@test "LLM2SSH_TOOLS in config overrides the default list (proves config is sourced)" {
  printf 'LLM2SSH_TOOLS="tree lsof"\n' >>"$CFG"
  run "$L" tools list
  [[ "$output" == *"tree"* ]]
  [[ "$output" == *"lsof"* ]]
  [[ "$output" != *"htop"* ]]
}

@test "LLM2SSH_EXTRA_DENYLIST from config is enforced (proves config is sourced)" {
  printf 'LLM2SSH_EXTRA_DENYLIST="echo"\n' >>"$CFG"
  cat >/etc/llm2ssh/profiles.d/echotest.profile <<EOF
name echotest
include observer
sudo /bin/echo x
EOF
  run "$L" profile show echotest
  [ "$status" -eq 3 ]
  [[ "$output" == *"denylist"* ]]
  rm -f /etc/llm2ssh/profiles.d/echotest.profile
}

@test "observer-hw allows dmidecode with NO args but denies --dump-bin (file write)" {
  "$L" create hw1 --key "ssh-ed25519 AAAAtest a@ci" >/dev/null 2>&1 || true
  "$L" grant hw1 observer-hw
  visudo -cf /etc/sudoers.d/llm2ssh-hw1
  # no-args full dump is allowed
  runuser -u hw1 -- sudo -n -l /usr/sbin/dmidecode
  # arg forms (which could write a file as root) are NOT allowed
  run runuser -u hw1 -- sudo -n -l /usr/sbin/dmidecode --dump-bin /tmp/x
  [ "$status" -ne 0 ]
  # smartctl --scan allowed, arbitrary smartctl args not
  runuser -u hw1 -- sudo -n -l /usr/sbin/smartctl --scan
  run runuser -u hw1 -- sudo -n -l /usr/sbin/smartctl -a -s off /dev/sda
  [ "$status" -ne 0 ]
  "$L" delete hw1 --yes
}
