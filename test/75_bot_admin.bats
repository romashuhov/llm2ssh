#!/usr/bin/env bats
# The bot admin boundary: llm2ssh-bot-admin exposes a safe subset and HARD
# refuses full/delete/injection. This is what lets the bot manage everything
# EXCEPT root/destroy. Root; run via test/run.sh.

TESTKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYplaceholder0000000000000000000000 a@ci"
BA=/usr/local/lib/llm2ssh/bin/llm2ssh-bot-admin

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
  "$L" create radmin --key "$TESTKEY" >/dev/null 2>&1 || true
}

@test "admin wrapper grants a safe profile" {
  run "$BA" grant radmin docker-ro
  [ "$status" -eq 0 ]
  [ -f /etc/sudoers.d/llm2ssh-radmin ]
}

@test "admin wrapper REFUSES granting full (no root via the bot)" {
  "$BA" grant radmin docker-ro >/dev/null 2>&1
  run "$BA" grant radmin full
  [ "$status" -ne 0 ]
  [[ "$output" == *"not allowed"* ]]
  ! grep -q 'ALL=(ALL:ALL)' /etc/sudoers.d/llm2ssh-radmin    # full was NOT granted
}

@test "admin wrapper REFUSES a custom sudo-all (root-equivalent) profile" {
  cat >/etc/llm2ssh/profiles.d/rooty.profile <<EOF
name rooty
description sneaky root
sudo-all yes
EOF
  run "$BA" grant radmin rooty
  [ "$status" -ne 0 ]
  [[ "$output" == *"root-equivalent"* ]]
  rm -f /etc/llm2ssh/profiles.d/rooty.profile
}

@test "admin wrapper REFUSES delete/create/uninstall and unknown verbs" {
  run "$BA" delete radmin;  [ "$status" -ne 0 ]
  run "$BA" uninstall;      [ "$status" -ne 0 ]
  run "$BA" create x;       [ "$status" -ne 0 ]
  run "$BA" evilverb;       [ "$status" -ne 0 ]
}

@test "admin wrapper validates agent/profile names (no injection)" {
  run "$BA" grant 'a;b' docker-ro; [ "$status" -ne 0 ]
  run "$BA" grant radmin 'x y';    [ "$status" -ne 0 ]
  run "$BA" onboard 'bad name';    [ "$status" -ne 0 ]
  run "$BA" grant radmin docker-ro --evil; [ "$status" -ne 0 ]
}

@test "admin wrapper onboard + revoke work" {
  run "$BA" onboard obot observer
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEGIN OPENSSH PRIVATE KEY"* ]]
  getent passwd obot
  run "$BA" revoke obot
  [ "$status" -eq 0 ]
  "$L" delete obot --yes
}

@test "bot sudoers includes the admin wrapper (and --no-admin drops it)" {
  "$L" bot setup --unattended --token "1:AAA" --chat-id 7 >/dev/null 2>&1
  visudo -cf /etc/sudoers.d/llm2ssh-bot
  grep -q 'llm2ssh-bot-admin' /etc/sudoers.d/llm2ssh-bot
  grep -q '^BOT_ADMIN=' /etc/llm2ssh/bot.env
  "$L" bot setup --unattended --token "1:AAA" --chat-id 7 --no-admin >/dev/null 2>&1
  visudo -cf /etc/sudoers.d/llm2ssh-bot
  ! grep -q 'llm2ssh-bot-admin' /etc/sudoers.d/llm2ssh-bot
}
