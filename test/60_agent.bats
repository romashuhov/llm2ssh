#!/usr/bin/env bats
# M3: profile→policy compilation, managed-settings, and the approval broker
# (client + local approver + PreToolUse hook). Root; run via test/run.sh.

TESTKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYplaceholder0000000000000000000000 a@ci"
HOOK=/usr/local/lib/llm2ssh/hooks/pretooluse-gate
APPROVE=/usr/local/bin/llm2ssh-approve

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
  L=/usr/local/bin/llm2ssh
  "$L" create a1 --key "$TESTKEY" >/dev/null 2>&1 || true
}

# Belt-and-suspenders: never let an approver leak into the next test / hang bats.
teardown() { pkill -KILL -f 'approve --watch' 2>/dev/null || true; }

# Start the approver in its OWN process group (setsid) so we can reliably kill
# it AND its background heartbeat child on teardown.
_start_approver() {
  setsid "$L" approve --watch --auto "$1" >/dev/null 2>&1 &
  local pid=$!
  echo "$pid"
  sleep 1
}
_stop_approver() {
  local pid="$1"
  kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  pkill -KILL -f 'approve --watch' 2>/dev/null || true
  sleep 0.5
}

@test "grant compiles a valid gate-policy for the profile" {
  "$L" grant a1 docker-ro
  jq -e . /etc/llm2ssh/gate-policy/a1.json >/dev/null
  [ "$(jq -r .profile /etc/llm2ssh/gate-policy/a1.json)" = "docker-ro" ]
  "$L" revoke a1
}

@test "managed-settings.json is valid and wires the enforced hook" {
  "$L" grant a1 docker-ro
  f=/etc/claude-code/managed-settings.json
  jq -e . "$f" >/dev/null
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$f")" = "$HOOK" ]
  [ "$(jq -r '.allowManagedHooksOnly' "$f")" = "true" ]
  [ "$(jq -r '.permissions.disableBypassPermissionsMode' "$f")" = "disable" ]
  "$L" revoke a1
}

@test "workspace advisory settings mirror the profile's sudo allow list" {
  # workspace exists after agent install; simulate it here
  install -d -o a1 -g a1 -m 0750 /home/a1/workspace
  "$L" grant a1 docker-ro
  f=/home/a1/workspace/.claude/settings.json
  jq -e . "$f" >/dev/null
  jq -e '.permissions.allow[] | select(test("sudo docker ps"))' "$f" >/dev/null
  "$L" revoke a1
}

@test "custom ask pattern is compiled into the gate-policy" {
  cat >/etc/llm2ssh/profiles.d/asktest.profile <<EOF
name asktest
description observer + owner approval for docker rm
include observer
ask sudo docker rm *
EOF
  "$L" grant a1 asktest
  jq -e '.ask | index("sudo docker rm *")' /etc/llm2ssh/gate-policy/a1.json >/dev/null
  "$L" revoke a1
  rm -f /etc/llm2ssh/profiles.d/asktest.profile
}

@test "approval client: auto-allow approver grants (exit 0)" {
  apv="$(_start_approver allow)"
  run bash -c "printf '{\"source\":\"cli\",\"user\":\"a1\",\"command\":\"x\"}' | runuser -u a1 -- $APPROVE request --timeout 8"
  _stop_approver "$apv"
  [ "$status" -eq 0 ]
}

@test "approval client: auto-deny approver denies (exit 1)" {
  apv="$(_start_approver deny)"
  run bash -c "printf '{\"source\":\"cli\",\"user\":\"a1\",\"command\":\"x\"}' | runuser -u a1 -- $APPROVE request --timeout 8"
  _stop_approver "$apv"
  [ "$status" -eq 1 ]
}

@test "approval client fails closed when no broker is running (exit 3)" {
  pkill -f 'approve --watch' 2>/dev/null || true; sleep 1
  rm -f /run/llm2ssh/approvald.alive
  run bash -c "printf '{\"source\":\"cli\",\"user\":\"a1\",\"command\":\"x\"}' | runuser -u a1 -- $APPROVE request --timeout 5"
  [ "$status" -eq 3 ]
}

@test "PreToolUse hook allows a gated command when the owner approves" {
  cat >/etc/llm2ssh/profiles.d/asktest.profile <<EOF
name asktest
description observer + approval for docker rm
include observer
ask sudo docker rm *
EOF
  "$L" grant a1 asktest
  apv="$(_start_approver allow)"
  run bash -c "printf '{\"tool_input\":{\"command\":\"sudo docker rm web\"}}' | runuser -u a1 -- $HOOK"
  _stop_approver "$apv"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision"'* ]]
  [[ "$output" == *'"allow"'* ]]
  "$L" revoke a1; rm -f /etc/llm2ssh/profiles.d/asktest.profile
}

@test "PreToolUse hook denies everything while the agent is frozen" {
  "$L" grant a1 docker-ro
  "$L" freeze a1
  run bash -c "printf '{\"tool_input\":{\"command\":\"ls\"}}' | runuser -u a1 -- $HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
  [[ "$output" == *"FROZEN"* ]]
  "$L" unfreeze a1
}

@test "PreToolUse hook defers a non-gated command (exit 0, no decision)" {
  "$L" grant a1 docker-ro     # no ask patterns, default allow
  run bash -c "printf '{\"tool_input\":{\"command\":\"ls -la\"}}' | runuser -u a1 -- $HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  "$L" revoke a1
}

@test "svc approval cannot be bypassed via a crafted cwd (JSON injection)" {
  # Regression for the confirmed high finding: a cwd containing a double-quote
  # must NOT make the request unparseable and fail OPEN. With a live auto-DENY
  # broker, the restart must be DENIED, never executed.
  "$L" grant a1 services --services nginx
  mkdir -p '/tmp/x"y'; chmod 777 '/tmp/x"y'
  apv="$(_start_approver deny)"
  run runuser -u a1 -- bash -c 'cd "/tmp/x\"y"; sudo -n /usr/local/lib/llm2ssh/bin/llm2ssh-svc restart nginx'
  _stop_approver "$apv"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DENIED"* ]]
  "$L" revoke a1
}
