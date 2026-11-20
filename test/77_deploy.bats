#!/usr/bin/env bats
# `deploy` profile: the root-owned llm2ssh-deploy wrapper runs ONLY owner-listed
# actions, as the project owner, with no shell; .env is shown masked and every
# edit needs a fresh owner Allow (fail-closed) with a backup taken first.

TESTKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYplaceholder0000000000000000000000 d@ci"
W=/usr/local/lib/llm2ssh/bin/llm2ssh-deploy
PROJ=/home/owner1/proj
CONF=/etc/llm2ssh/deploy.d/proj.conf
AREQ=/run/llm2ssh/approvals/req
ARES=/run/llm2ssh/approvals/res
AHB=/run/llm2ssh/approvald.alive

setup_file() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  if [ "$(id -u)" -ne 0 ]; then return 0; fi
  bash "$REPO/install.sh" --no-tools >/dev/null 2>&1
  # Fake docker: shows who ran it and with which env/args.
  cat >/usr/bin/docker <<'EOF'
#!/bin/sh
echo "fake docker uid=$(id -un) pwd=$PWD agent_uid=${PRATIMO_AGENT_UID:-} docker_gid=${PRATIMO_DOCKER_GID:-} args: $*"
[ "$1" = exec ] && cat
exit 0
EOF
  chmod 0755 /usr/bin/docker; chown root:root /usr/bin/docker
  id owner1 >/dev/null 2>&1 || useradd -m -s /bin/bash owner1
  chmod 0700 /home/owner1
  /usr/local/bin/llm2ssh create dp --key "$TESTKEY" >/dev/null 2>&1 || true
}

setup() {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root (run via test/run.sh)"; fi
  L=/usr/local/bin/llm2ssh
  rm -rf "$PROJ"; install -d -o owner1 -g owner1 -m 0755 "$PROJ" "$PROJ/docker" "$PROJ/.git"
  cat >"$PROJ/update.sh" <<'EOF'
#!/usr/bin/env bash
echo "update as $(id -un) in $PWD"
if IFS= read -r -t 1 line; then echo "stdin:$line"; else echo "stdin-empty"; fi
EOF
  printf 'services: {}\n' >"$PROJ/docker/compose.deploy-agent.yml"
  cat >"$PROJ/.env" <<'EOF'
# comment
LOG_LEVEL=info
AUTH_SECRET=0123456789abcdefWXYZ
DATABASE_URL=postgres://pratimo:hunter2pass@localhost:5432/pratimo
BRAND_CHANNEL_NAME="Pratimo | News"
TELEGRAM_BOT_TOKEN=short
EOF
  chown owner1:owner1 "$PROJ"/update.sh "$PROJ"/.env "$PROJ"/docker/*; chmod 0600 "$PROJ/.env"
  cat >"$CONF" <<EOF
run-as        owner1
dir           $PROJ
env-file      .env
timeout       60
compose       deploy-agent docker/compose.deploy-agent.yml
compose-env   PRATIMO_AGENT_UID %DIR_UID%
compose-env   PRATIMO_DOCKER_GID %DOCKER_GID%
query         state pg pratimo pratimo SELECT 1
container     web-1 api-1
env-edit      *
EOF
  chmod 0644 "$CONF"; chown root:root "$CONF"
  rm -f "$AHB" "$AREQ"/*.json "$ARES"/*.json 2>/dev/null || true
  rm -rf /var/lib/llm2ssh/deploy/proj
  "$L" grant dp deploy --ttl 1h >/dev/null 2>&1
}

# as the agent, through sudo — exactly what the agent can do over SSH.
_dp() { runuser -u dp -- sudo -n "$W" "$@"; }

# _responder DECISION — fake broker: fresh heartbeat + answer the next request.
_responder() {
  : >"$AHB"
  ( for _ in $(seq 1 40); do
      : >"$AHB"
      f="$(ls -1 "$AREQ"/*.json 2>/dev/null | head -1)"
      if [ -n "$f" ]; then
        rid="$(basename "$f" .json)"
        cp "$f" "$BATS_TEST_TMPDIR/last-req.json"
        printf '{"id":"%s","decision":"%s"}' "$rid" "$1" >"$ARES/$rid.json"
        break
      fi
      sleep 0.25
    done ) &
  RESP_PID=$!
}

@test "deploy is requestable, time-limited, and only grants the wrapper" {
  run "$L" profile show deploy
  [[ "$output" == *"requestable: yes"* ]]
  [[ "$output" == *"ttl-required: yes"* ]]
  run "$L" grant dp deploy                  # no --ttl -> refused
  [ "$status" -eq 2 ]
  visudo -cf /etc/sudoers.d/llm2ssh-dp
  grep -q 'llm2ssh-deploy' /etc/sudoers.d/llm2ssh-dp
  # no way to become the owner directly, and no raw shell
  run runuser -u dp -- sudo -n -u owner1 true
  [ "$status" -ne 0 ]
  run runuser -u dp -- sudo -n -l /bin/bash
  [ "$status" -ne 0 ]
  run runuser -u dp -- ls "$PROJ"
  [ "$status" -ne 0 ]
}

@test "update runs update.sh as the owner, in the project dir, stdin </dev/null" {
  run _dp update proj
  [ "$status" -eq 0 ]
  [[ "$output" == *"update as owner1 in $PROJ"* ]]
  [[ "$output" == *"stdin-empty"* ]]
}

@test "compose recreates with fixed flags and the configured env" {
  run _dp compose proj deploy-agent
  [ "$status" -eq 0 ]
  [[ "$output" == *"uid=owner1"* ]]
  [[ "$output" == *"agent_uid=$(id -u owner1)"* ]]
  [[ "$output" == *"--env-file .env -f docker/compose.deploy-agent.yml up -d --build --force-recreate"* ]]
  run _dp compose proj other
  [ "$status" -eq 4 ]
}

@test "query runs the configured SQL read-only; restart-policy only for listed containers" {
  run _dp query proj state
  [ "$status" -eq 0 ]
  [[ "$output" == *"default_transaction_read_only=on"* ]]
  [[ "$output" == *"SELECT 1"* ]]
  run _dp restart-policy proj web-1 unless-stopped
  [ "$status" -eq 0 ]
  [[ "$output" == *"update --restart unless-stopped web-1"* ]]
  run _dp restart-policy proj evil unless-stopped
  [ "$status" -eq 3 ]
  run _dp restart-policy proj web-1 'always --privileged'
  [ "$status" -eq 2 ]
}

@test "bad targets, traversal and unknown verbs are refused" {
  run _dp update ../etc/passwd
  [ "$status" -eq 2 ]
  run _dp update nosuch
  [ "$status" -eq 4 ]
  run _dp shell proj
  [ "$status" -eq 2 ]
}

@test "refuses when the config is not root-owned or the tree is agent-writable" {
  chown dp "$CONF"
  run _dp update proj
  [ "$status" -eq 3 ]
  chown root "$CONF"
  # home closed (0700): the agent can't even reach the file -> still fine
  chmod o+w "$PROJ/update.sh"
  run _dp update proj
  [ "$status" -eq 0 ]
  # home traversable + update.sh world-writable -> the agent could plant code: refuse
  chmod 0711 /home/owner1
  run _dp update proj
  chmod 0700 /home/owner1
  [ "$status" -eq 3 ]
  [[ "$output" == *"agent can write"* ]]
}

@test "env-show masks secrets (last 4 chars at most) and URL passwords" {
  run _dp env-show proj
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOG_LEVEL=info"* ]]
  [[ "$output" == *"AUTH_SECRET=****WXYZ"* ]]
  [[ "$output" != *"0123456789abcdef"* ]]
  [[ "$output" != *"hunter2pass"* ]]
  [[ "$output" == *"postgres://pratimo:****"* ]]
  [[ "$output" == *"TELEGRAM_BOT_TOKEN=****(5 chars)"* ]]
  [[ "$output" == *"BRAND_CHANNEL_NAME=Pratimo | News"* ]]
}

@test "env-set without a running broker is DENIED and the file is untouched" {
  before="$(sha256sum "$PROJ/.env")"
  run _dp env-set proj LOG_LEVEL debug
  [ "$status" -eq 3 ]
  [ "$(sha256sum "$PROJ/.env")" = "$before" ]
}

@test "env-set: owner sees the exact masked diff; Allow applies it with a backup" {
  _responder allow
  run _dp env-set proj LOG_LEVEL debug --line 2
  kill "$RESP_PID" 2>/dev/null || true
  [ "$status" -eq 0 ]
  jq -r .command "$BATS_TEST_TMPDIR/last-req.json" | grep -F 'line 2: LOG_LEVEL: info → debug'
  grep -qx 'LOG_LEVEL=debug' "$PROJ/.env"
  [ "$(stat -c '%U %a' "$PROJ/.env")" = "owner1 600" ]
  b="$(ls -1 /var/lib/llm2ssh/deploy/proj/env-backups/)"
  grep -qx 'LOG_LEVEL=info' "/var/lib/llm2ssh/deploy/proj/env-backups/$b"
}

@test "env-set of a secret never shows the value; quoting style is kept" {
  _responder allow
  run _dp env-set proj AUTH_SECRET newsecretvalue9999
  kill "$RESP_PID" 2>/dev/null || true
  [ "$status" -eq 0 ]
  cmd="$(jq -r .command "$BATS_TEST_TMPDIR/last-req.json")"
  [[ "$cmd" == *"****WXYZ"*"****9999"* ]]
  [[ "$cmd" != *"newsecretvalue"* ]]
  [[ "$output" != *"newsecretvalue"* ]]
  _responder allow
  run _dp env-set proj BRAND_CHANNEL_NAME "Pratimo Daily"
  kill "$RESP_PID" 2>/dev/null || true
  grep -qx 'BRAND_CHANNEL_NAME="Pratimo Daily"' "$PROJ/.env"
}

@test "env-set: Deny leaves the file; dangerous names and values are refused" {
  before="$(sha256sum "$PROJ/.env")"
  _responder deny
  run _dp env-set proj LOG_LEVEL debug
  kill "$RESP_PID" 2>/dev/null || true
  [ "$status" -eq 3 ]
  [ "$(sha256sum "$PROJ/.env")" = "$before" ]
  run _dp env-set proj DOCKER_HOST tcp://evil:2375
  [ "$status" -eq 3 ]
  run _dp env-set proj LOG_LEVEL '$(id)'
  [ "$status" -eq 2 ]
  run _dp env-set proj LOG_LEVEL "$(printf 'a\nPATH=/tmp')"
  [ "$status" -eq 2 ]
  run _dp env-set proj LOG_LEVEL debug --line 5
  [ "$status" -eq 3 ]
  [ "$(sha256sum "$PROJ/.env")" = "$before" ]
}

@test "after revoke the agent can no longer run the wrapper" {
  "$L" revoke dp
  run _dp list
  [ "$status" -ne 0 ]
}
