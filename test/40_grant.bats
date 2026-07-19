#!/usr/bin/env bats
# End-to-end permission enforcement (root; run inside a container via run.sh).
# Installs llm2ssh, fakes a root-owned docker binary, then asserts that the
# generated sudoers actually allow/deny the right commands.

setup_file() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  if [ "$(id -u)" -ne 0 ]; then return 0; fi
  bash "$REPO/install.sh" --no-tools >/dev/null 2>&1
  # Fake, root-owned docker so %DOCKER% resolves and passes the security check.
  cat >/usr/bin/docker <<'EOF'
#!/bin/sh
echo "fake docker $*"
EOF
  chmod 0755 /usr/bin/docker; chown root:root /usr/bin/docker
  # A disposable agent with a literal test key.
  /usr/local/bin/llm2ssh create tester \
    --key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYplaceholder0000000000000000000000 test@ci" \
    >/dev/null 2>&1
}

setup() {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root (run via test/run.sh)"; fi
  L=/usr/local/bin/llm2ssh
}

# allowed AGENT CMD... -> succeeds if the agent may sudo CMD (NOPASSWD).
_allowed() { runuser -u "$1" -- sudo -n -l "${@:2}" >/dev/null 2>&1; }

@test "create placed a root-owned keys file" {
  [ -f /etc/llm2ssh/keys/tester ]
  [ "$(stat -c '%U' /etc/llm2ssh/keys/tester)" = "root" ]
  grep -q "restrict,pty ssh-ed25519" /etc/llm2ssh/keys/tester
}

@test "observer grants zero sudo" {
  "$L" grant tester observer
  [ ! -f /etc/sudoers.d/llm2ssh-tester ]
  run _allowed tester /usr/bin/docker ps
  [ "$status" -ne 0 ]
}

@test "docker-ro allows docker ps but not docker run" {
  "$L" grant tester docker-ro
  [ -f /etc/sudoers.d/llm2ssh-tester ]
  visudo -cf /etc/sudoers.d/llm2ssh-tester
  _allowed tester /usr/bin/docker ps
  run _allowed tester /usr/bin/docker run alpine
  [ "$status" -ne 0 ]
}

@test "docker-admin allows restart but still NOT docker run/exec" {
  "$L" grant tester docker-admin
  _allowed tester /usr/bin/docker restart web
  run _allowed tester /usr/bin/docker run alpine
  [ "$status" -ne 0 ]
  run _allowed tester /usr/bin/docker exec web sh
  [ "$status" -ne 0 ]
}

@test "generated sudoers file has no dot and mode 0440" {
  "$L" grant tester docker-ro
  [ "$(stat -c '%a' /etc/sudoers.d/llm2ssh-tester)" = "440" ]
}

@test "services grant requires --services and writes an allowlist" {
  run "$L" grant tester services
  [ "$status" -ne 0 ]                     # missing --services
  "$L" grant tester services --services nginx,redis
  grep -qx nginx /var/lib/llm2ssh/agents/tester/services.allow
  grep -qx redis /var/lib/llm2ssh/agents/tester/services.allow
  _allowed tester /usr/local/lib/llm2ssh/bin/llm2ssh-svc restart nginx
}

@test "llm2ssh-svc denies units outside the allowlist" {
  "$L" grant tester services --services nginx
  # The wrapper itself refuses (allowlist enforcement), exit 4.
  run runuser -u tester -- sudo -n /usr/local/lib/llm2ssh/bin/llm2ssh-svc restart sshd
  [ "$status" -eq 4 ]
}

@test "full grant with --yes gives sudo ALL" {
  "$L" grant tester full --yes
  grep -q "ALL=(ALL:ALL) NOPASSWD: ALL" /etc/sudoers.d/llm2ssh-tester
  _allowed tester /bin/cat /etc/shadow
}

@test "ttl grant records an expiry; revoke clears it" {
  "$L" grant tester docker-ro --ttl 1h
  run "$L" status tester --json
  [[ "$output" == *'"remaining_s":'* ]]
  [ "$(sed -n 's/.*expires_at=//p' /var/lib/llm2ssh/agents/tester/state)" -gt 0 ]
  "$L" revoke tester
  [ "$(sed -n 's/.*expires_at=//p' /var/lib/llm2ssh/agents/tester/state)" -eq 0 ]
  # revoke returns to base profile (observer) -> no sudoers file
  [ ! -f /etc/sudoers.d/llm2ssh-tester ]
}

@test "delete removes user, keys, and sudoers" {
  "$L" create scratch --key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYplaceholder0000000000000000000000 s@ci" >/dev/null
  "$L" grant scratch docker-ro >/dev/null
  "$L" delete scratch --yes
  ! getent passwd scratch
  [ ! -f /etc/sudoers.d/llm2ssh-scratch ]
  [ ! -f /etc/llm2ssh/keys/scratch ]
  [ ! -d /var/lib/llm2ssh/agents/scratch ]
}
