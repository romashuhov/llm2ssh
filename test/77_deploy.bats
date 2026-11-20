#!/usr/bin/env bats
# `deploy` profile: the root-owned llm2ssh-deploy wrapper runs ONLY owner-listed
# actions, as the project owner, with no shell. update/compose need the owner's
# Allow with the commit range shown; .env is masked (except env-public) and every
# edit needs a fresh Allow (fail-closed) with a backup taken first.

TESTKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYplaceholder0000000000000000000000 d@ci"
W=/usr/local/lib/llm2ssh/bin/llm2ssh-deploy
PROJ=/home/owner1/proj
ORIGIN=/srv/deploy-origin.git
CONF=/etc/llm2ssh/deploy.d/proj.conf
AREQ=/run/llm2ssh/approvals/req
ARES=/run/llm2ssh/approvals/res
AHB=/run/llm2ssh/approvald.alive
STATE=/var/lib/llm2ssh/agents/dp/state

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
  /usr/local/bin/llm2ssh create dp --key "$TESTKEY" >/dev/null 2>&1 || true
}

_o() { runuser -u owner1 -- env HOME=/home/owner1 git -c user.name=o -c user.email=o@x "$@"; }

setup() {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root (run via test/run.sh)"; fi
  L=/usr/local/bin/llm2ssh
  chmod 0700 /home/owner1
  rm -rf "$PROJ" "$ORIGIN" /tmp/seed /home/owner1/.gitconfig
  install -d -o owner1 -g owner1 /srv
  runuser -u owner1 -- git init -q --bare -b main "$ORIGIN"
  install -d -o owner1 -g owner1 -m 0755 "$PROJ"
  _o init -q -b main "$PROJ"
  install -d -o owner1 -g owner1 -m 0755 "$PROJ/docker"
  cat >"$PROJ/update.sh" <<'EOF'
#!/usr/bin/env bash
echo "update as $(id -un) in $PWD"
if IFS= read -r -t 1 line; then echo "stdin:$line"; else echo "stdin-empty"; fi
if [ -e /proc/$$/fd/9 ]; then echo "fd9-leaked"; else echo "fd9-closed"; fi
echo "path=$PATH"
EOF
  printf 'services: {}\n' >"$PROJ/docker/compose.deploy-agent.yml"
  chown -R owner1:owner1 "$PROJ"
  _o -C "$PROJ" add update.sh docker
  _o -C "$PROJ" commit -qm "initial"
  _o -C "$PROJ" remote add origin "$ORIGIN"
  _o -C "$PROJ" push -q -u origin main
  # one commit on origin that the server does not have yet
  _o clone -q "$ORIGIN" /tmp/seed
  _o -C /tmp/seed commit -q --allow-empty -m "new feature"
  _o -C /tmp/seed push -q origin main
  cat >"$PROJ/.env" <<'EOF'
# comment
LOG_LEVEL=info
AUTH_SECRET=0123456789abcdefWXYZ
DATABASE_URL=postgres://pratimo:hunter2pass@localhost:5432/pratimo
BRAND_CHANNEL_NAME="Pratimo"
TELEGRAM_BOT_TOKEN=short
PLAIN_SETTING=visible-only-if-public
EOF
  chown owner1:owner1 "$PROJ/.env"; chmod 0600 "$PROJ/.env"
  install -d -o owner1 -g owner1 /home/owner1/.bun /home/owner1/.bun/bin
  cat >"$CONF" <<EOF
run-as        owner1
dir           $PROJ
env-file      .env
timeout       60
path-prepend  /home/owner1/.bun/bin
compose       deploy-agent docker/compose.deploy-agent.yml
compose-env   PRATIMO_AGENT_UID %DIR_UID%
compose-env   PRATIMO_DOCKER_GID %DOCKER_GID%
query         state pg pratimo pratimo SELECT 1
container     web-1 api-1
env-public    LOG_LEVEL DATABASE_URL BRAND_CHANNEL_NAME
env-edit      LOG_LEVEL AUTH_SECRET BRAND_CHANNEL_NAME NEW_VAR HTTP_PROXY
EOF
  chmod 0644 "$CONF"; chown root:root "$CONF"
  rm -f "$AHB" "$AREQ"/*.json "$ARES"/*.json 2>/dev/null || true
  rm -rf /var/lib/llm2ssh/deploy/proj /var/log/llm2ssh/deploy/proj
  "$L" grant dp deploy --ttl 1h >/dev/null 2>&1
}

# as the agent, through sudo — exactly what the agent can do over SSH.
_dp() { runuser -u dp -- sudo -n "$W" "$@"; }
_allowed() { runuser -u "$1" -- sudo -n -l "${@:2}" >/dev/null 2>&1; }

# _responder DECISION — fake broker: fresh heartbeat + answer the next request.
_responder() {
  : >"$AHB"
  ( for _ in $(seq 1 80); do
      : >"$AHB"
      f="$(ls -1 "$AREQ"/*.json 2>/dev/null | head -1)"
      if [ -n "$f" ]; then
        rid="$(basename "$f" .json)"
        cp "$f" "$BATS_TEST_TMPDIR/last-req.json"
        stat -c %U "$f" >"$BATS_TEST_TMPDIR/last-req.owner"
        printf '{"id":"%s","decision":"%s"}' "$rid" "$1" >"$ARES/$rid.json"
        break
      fi
      sleep 0.25
    done ) &
  RESP_PID=$!
}
_card() { jq -r .command "$BATS_TEST_TMPDIR/last-req.json"; }

# ---- profile -----------------------------------------------------------------

@test "deploy: requestable, ttl-required, ttl-max 4h; wrapper + docker ps only (no inspect/logs)" {
  run "$L" profile show deploy
  [[ "$output" == *"requestable: yes"* ]]
  [[ "$output" == *"ttl-required: yes"* ]]
  [[ "$output" == *"ttl-max: 14400s"* ]]
  run "$L" grant dp deploy                  # no --ttl
  [ "$status" -eq 2 ]
  run "$L" grant dp deploy --ttl 1d         # over ttl-max
  [ "$status" -eq 2 ]
  visudo -cf /etc/sudoers.d/llm2ssh-dp
  _allowed dp "$W" list
  _allowed dp /usr/bin/docker ps
  run _allowed dp /usr/bin/docker inspect web-1
  [ "$status" -ne 0 ]
  run _allowed dp /usr/bin/docker logs web-1
  [ "$status" -ne 0 ]
  run _allowed dp /usr/bin/docker start -a web-1
  [ "$status" -ne 0 ]
  run runuser -u dp -- sudo -n -u owner1 true
  [ "$status" -ne 0 ]
  run runuser -u dp -- ls "$PROJ"
  [ "$status" -ne 0 ]
}

@test "the wrapper itself refuses an expired or open-ended grant" {
  sed -i "s/^expires_at=.*/expires_at=$(( $(date +%s) - 5 ))/" "$STATE"
  run _dp list
  [ "$status" -eq 3 ]
  [[ "$output" == *"expired"* ]]
  sed -i "s/^expires_at=.*/expires_at=0/" "$STATE"
  run _dp list
  [ "$status" -eq 3 ]
  [[ "$output" == *"without an expiry"* ]]
}

# ---- update / compose ----------------------------------------------------------

@test "update without a broker is denied (confirm update is the default)" {
  run _dp update proj
  [ "$status" -eq 3 ]
  [[ "$output" != *"update as owner1"* ]]
}

@test "update: owner sees the commit range; runs detached as owner, stdin </dev/null, no lock fd, bun PATH" {
  _responder allow
  run _dp update proj
  kill "$RESP_PID" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/last-req.owner")" = root ]
  [ "$(jq -r .source "$BATS_TEST_TMPDIR/last-req.json")" = llm2ssh-deploy ]
  _card | grep -F 'origin/main'
  _card | grep -F '1 new commit(s)'
  _card | grep -F 'new feature'
  [[ "$output" == *"update as owner1 in $PROJ"* ]]
  [[ "$output" == *"stdin-empty"* ]]
  [[ "$output" == *"fd9-closed"* ]]
  [[ "$output" == *"path=/home/owner1/.bun/bin:"* ]]
  run _dp status proj
  [ "$status" -eq 0 ]
  [[ "$output" == *"finished, exit 0"* ]]
  [[ "$output" == *"update as owner1"* ]]
}

@test "update keeps running when the caller goes away (own session + log)" {
  cat >"$PROJ/update.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2; echo "survived"
EOF
  chown owner1 "$PROJ/update.sh"
  printf 'confirm none\n' >>"$CONF"
  runuser -u dp -- sudo -n "$W" update proj >/dev/null 2>&1 &
  caller=$!
  sleep 0.7
  pkill -KILL -f "tail -n \+1 -f --pid" || true
  kill -KILL "$caller" 2>/dev/null || true
  for _ in $(seq 1 30); do
    run _dp status proj
    [[ "$output" == *"finished"* ]] && break
    sleep 0.3
  done
  [[ "$output" == *"finished, exit 0"* ]]
  [[ "$output" == *"survived"* ]]
}

@test "compose: approved with the HEAD being built, fixed flags and configured env" {
  _responder allow
  run _dp compose proj deploy-agent
  kill "$RESP_PID" 2>/dev/null || true
  [ "$status" -eq 0 ]
  _card | grep -F 'HEAD'
  _card | grep -F 'initial'
  [[ "$output" == *"uid=owner1"* ]]
  [[ "$output" == *"agent_uid=$(id -u owner1)"* ]]
  [[ "$output" == *"--env-file .env -f docker/compose.deploy-agent.yml up -d --build --force-recreate"* ]]
  run _dp compose proj other
  [ "$status" -eq 4 ]
}

# ---- read-only verbs -------------------------------------------------------------

@test "query is read-only; restart-policy only for listed containers; git-log works" {
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
  run _dp git-log proj
  [ "$status" -eq 0 ]
  [[ "$output" == *"initial"* ]]
}

@test "bad targets, traversal and unknown verbs are refused (full path in help)" {
  run _dp update ../etc/passwd
  [ "$status" -eq 2 ]
  run _dp update nosuch
  [ "$status" -eq 4 ]
  [[ "$output" == *"$W list"* ]]
  run _dp shell proj
  [ "$status" -eq 2 ]
}

# ---- closed tree ---------------------------------------------------------------

@test "refuses when the config is not root-owned" {
  chown dp "$CONF"
  run _dp git-log proj
  [ "$status" -eq 3 ]
}

@test "closed-tree check: hooks, ~/.gitconfig, PATH dirs writable by the agent -> refused (git-log too)" {
  chmod 0711 /home/owner1                 # agent may traverse (not list) the home
  run _dp git-log proj
  [ "$status" -eq 0 ]
  chmod o+w "$PROJ/.git/hooks"            # found by the recursive scan of the project
  run _dp git-log proj
  [ "$status" -eq 3 ]
  [[ "$output" == *"agent can write $PROJ/.git/hooks"* ]]
  chmod o-w "$PROJ/.git/hooks"
  install -o owner1 -m 0666 /dev/null /home/owner1/.gitconfig   # hidden in an unlistable home
  run _dp git-log proj
  [ "$status" -eq 3 ]
  [[ "$output" == *".gitconfig"* ]]
  rm -f /home/owner1/.gitconfig
  chmod o+w /home/owner1/.bun/bin
  run _dp env-show proj
  chmod o-w /home/owner1/.bun/bin
  chmod 0700 /home/owner1
  [ "$status" -eq 3 ]
}

# ---- .env ----------------------------------------------------------------------

@test "env-show masks everything except env-public (URL passwords masked even then)" {
  run _dp env-show proj
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOG_LEVEL=info"* ]]
  [[ "$output" == *"BRAND_CHANNEL_NAME=Pratimo"* ]]
  [[ "$output" == *"AUTH_SECRET=****WXYZ"* ]]
  [[ "$output" == *"TELEGRAM_BOT_TOKEN=****(5 chars)"* ]]
  [[ "$output" == *"PLAIN_SETTING=****"* ]]
  [[ "$output" != *"visible-only-if-public"* ]]
  [[ "$output" != *"0123456789abcdef"* ]]
  [[ "$output" != *"hunter2pass"* ]]
  [[ "$output" == *"postgres://pratimo:****"* ]]
}

@test "env-set without a running broker is DENIED and the file is untouched" {
  before="$(sha256sum "$PROJ/.env")"
  run _dp env-set proj LOG_LEVEL debug
  [ "$status" -eq 3 ]
  [ "$(sha256sum "$PROJ/.env")" = "$before" ]
}

@test "env-set: owner sees line, old and FULL new value; Allow applies it with a backup" {
  _responder allow
  run _dp env-set proj LOG_LEVEL debug --line 2
  kill "$RESP_PID" 2>/dev/null || true
  [ "$status" -eq 0 ]
  _card | grep -F 'line 2: LOG_LEVEL: info → debug'
  grep -qx 'LOG_LEVEL=debug' "$PROJ/.env"
  [ "$(stat -c '%U %a' "$PROJ/.env")" = "owner1 600" ]
  b="$(ls -1 /var/lib/llm2ssh/deploy/proj/env-backups/)"
  grep -qx 'LOG_LEVEL=info' "/var/lib/llm2ssh/deploy/proj/env-backups/$b"
}

@test "env-set of a secret: old value masked, new value shown in full; quoting kept; no value oracle" {
  _responder allow
  run _dp env-set proj AUTH_SECRET newsecretvalue9999
  kill "$RESP_PID" 2>/dev/null || true
  [ "$status" -eq 0 ]
  _card | grep -F 'AUTH_SECRET: ****WXYZ(20 chars) → newsecretvalue9999'
  [[ "$(_card)" != *"0123456789abcdef"* ]]
  _responder allow
  run _dp env-set proj BRAND_CHANNEL_NAME Daily
  kill "$RESP_PID" 2>/dev/null || true
  grep -qx 'BRAND_CHANNEL_NAME="Daily"' "$PROJ/.env"
  # setting the CURRENT value is not short-circuited (would confirm a guess)
  rm -f "$AHB"
  run _dp env-set proj AUTH_SECRET newsecretvalue9999
  [ "$status" -eq 3 ]
  [[ "$output" != *"already"* ]]
}

@test "env-set: a new variable needs --add" {
  run _dp env-set proj NEW_VAR 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"--add"* ]]
  _responder allow
  run _dp env-set proj NEW_VAR 1 --add
  kill "$RESP_PID" 2>/dev/null || true
  [ "$status" -eq 0 ]
  _card | grep -F 'NEW_VAR: (absent — new line) → 1'
  grep -qx 'NEW_VAR=1' "$PROJ/.env"
  run _dp env-set proj LOG_LEVEL x --add
  [ "$status" -eq 3 ]
}

@test "env-set: Deny leaves the file; denylisted names and unsafe values are refused" {
  before="$(sha256sum "$PROJ/.env")"
  _responder deny
  run _dp env-set proj LOG_LEVEL debug
  kill "$RESP_PID" 2>/dev/null || true
  [ "$status" -eq 3 ]
  for n in HTTP_PROXY https_proxy XDG_CONFIG_HOME GCONV_PATH npm_config_prefix JAVA_TOOL_OPTIONS \
           DOCKER_HOST COMPOSE_FILE LD_PRELOAD NODE_OPTIONS BUN_INSTALL GIT_SSH_COMMAND; do
    run _dp env-set proj "$n" x
    [ "$status" -eq 3 ]
    [[ "$output" == *"may never be changed"* ]]
  done
  run _dp env-set proj PLAIN_SETTING x          # not in env-edit
  [ "$status" -eq 3 ]
  for v in 'a b' '$(id)' '"q"' "a'b" 'a#b' 'a\b' "$(printf 'a\nPATH=/tmp')" 'a;b' 'a|b'; do
    run _dp env-set proj LOG_LEVEL "$v"
    [ "$status" -eq 2 ]
  done
  run _dp env-set proj LOG_LEVEL debug --line 5
  [ "$status" -eq 3 ]
  [ "$(sha256sum "$PROJ/.env")" = "$before" ]
}

# ---- bot side --------------------------------------------------------------------

_load_bot() {
  export LLM2SSH_LIB=/usr/local/lib/llm2ssh
  # shellcheck disable=SC1091
  . "$LLM2SSH_LIB/lib/common.sh"; . "$LLM2SSH_LIB/lib/state.sh"
  . "$LLM2SSH_LIB/lib/profile.sh"; . "$LLM2SSH_LIB/lib/approve.sh"
  . "$LLM2SSH_LIB/bot/tg-api.sh"; . "$LLM2SSH_LIB/lib/bot.sh"
}

@test "approval card: requester = file owner; only root-written requests get the 🔒 label; newlines stripped" {
  _load_bot
  printf '{"source":"llm2ssh-deploy","user":"dp","command":"env-set x\\n✅ fake line","timeout_s":180}' >"$AREQ/a1b2c3d4.json"
  bot_approval_card a1b2c3d4
  [[ "$CARD_TEXT" == "🔒 llm2ssh-deploy (agent dp): env-set x ✅ fake line (auto-deny in 180s)" ]]
  # an agent-written request pretending to be the wrapper, for another user
  printf '{"source":"llm2ssh-deploy","user":"root","command":"update"}' >"$AREQ/b1b2c3d4.json"
  chown dp "$AREQ/b1b2c3d4.json"
  bot_approval_card b1b2c3d4
  [ "$CARD_USER" = dp ]
  [[ "$CARD_TEXT" == "🛑 Approval needed (agent dp): update"* ]]
  rm -f "$AREQ"/a1b2c3d4.json "$AREQ"/b1b2c3d4.json
}

@test "duration keyboards: deploy has no Forever and nothing over 4h; docker-ro unchanged" {
  _load_bot
  kb='[[{"text":"⏱ 1h"},{"text":"⏱ 4h"},{"text":"⏱ 1d"}],[{"text":"♾ Forever"},{"text":"❌ Deny"}]]'
  out="$(bot_kb_limit deploy <<<"$kb")"
  [[ "$out" == *"1h"* && "$out" == *"4h"* && "$out" == *"Deny"* ]]
  [[ "$out" != *"1d"* && "$out" != *"Forever"* ]]
  out="$(bot_kb_limit docker-ro <<<"$kb")"
  [[ "$out" == *"1d"* && "$out" == *"Forever"* ]]
}

@test "after revoke the agent can no longer run the wrapper" {
  "$L" revoke dp
  run _dp list
  [ "$status" -ne 0 ]
}
