#!/usr/bin/env bats
# Access-request flow: requestable profiles, the agent client (bot/no-bot paths),
# and the bot-side decision (authoritative agent = req file owner; grant via the
# admin wrapper which refuses root).

TESTKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYplaceholder0000000000000000000000 a@ci"
REQ=/run/llm2ssh/requests/req
RES=/run/llm2ssh/requests/res
HB=/run/llm2ssh/botd.alive

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
  export LLM2SSH_LIB=/usr/local/lib/llm2ssh
  "$L" create rq --key "$TESTKEY" >/dev/null 2>&1 || true
  rm -f "$HB" "$REQ"/*.json "$RES"/*.json 2>/dev/null || true
}

@test "requestable profiles are marked; full is NOT requestable" {
  run "$L" profile show disk-audit
  [[ "$output" == *"requestable: yes"* ]]
  run "$L" profile show full
  [[ "$output" != *"requestable: yes"* ]]
}

@test "disk-audit grants du ONLY via the safe wrapper, not raw du" {
  "$L" grant rq disk-audit
  visudo -cf /etc/sudoers.d/llm2ssh-rq
  # du is available only through the root-owned wrapper (blocks --files0-from)
  runuser -u rq -- sudo -n -l /usr/local/lib/llm2ssh/bin/llm2ssh-du /var
  runuser -u rq -- sudo -n -l /usr/bin/docker system df -v
  # raw `sudo du` (the arbitrary-file-read primitive) is NOT granted
  run runuser -u rq -- sudo -n -l /usr/bin/du --files0-from=/etc/shadow
  [ "$status" -ne 0 ]
  run runuser -u rq -- sudo -n -l /usr/bin/docker run alpine
  [ "$status" -ne 0 ]
  "$L" revoke rq
}

@test "raw 'sudo du *' is rejected by the profile validator (denylist)" {
  cat >/etc/llm2ssh/profiles.d/rawdu.profile <<EOF
name rawdu
include observer
sudo /usr/bin/du *
EOF
  run "$L" profile show rawdu
  [ "$status" -eq 3 ]
  [[ "$output" == *"denylist"* ]]
  rm -f /etc/llm2ssh/profiles.d/rawdu.profile
}

@test "the du wrapper refuses option injection and only reports dir sizes" {
  # --files0-from must NOT reach du: the wrapper requires an absolute path.
  run /usr/local/lib/llm2ssh/bin/llm2ssh-du --files0-from=/etc/shadow
  [ "$status" -ne 0 ]
  run /usr/local/lib/llm2ssh/bin/llm2ssh-du /etc
  [ "$status" -eq 0 ]
  [[ "$output" != *"root:"* ]]   # it printed sizes, not /etc/shadow contents
}

@test "request client: no bot connected -> prints the manual command" {
  rm -f "$HB"
  run runuser -u rq -- /usr/local/bin/llm2ssh-request disk-audit --reason "disk full"
  [ "$status" -eq 3 ]
  [[ "$output" == *"llm2ssh grant rq disk-audit"* ]]
}

@test "request client: a non-requestable profile is refused" {
  run runuser -u rq -- /usr/local/bin/llm2ssh-request full
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot be requested"* ]]
}

_load_bot() {
  # shellcheck disable=SC1091
  . "$LLM2SSH_LIB/lib/common.sh"; . "$LLM2SSH_LIB/lib/state.sh"
  . "$LLM2SSH_LIB/lib/profile.sh"; . "$LLM2SSH_LIB/bot/tg-api.sh"; . "$LLM2SSH_LIB/lib/bot.sh"
}

@test "bot_request_decide grants to the FILE OWNER, ignoring a spoofed user field" {
  _load_bot
  export OWNER_USER_ID=42 OWNER_CHAT_ID=42
  id=aabb1122
  printf '{"id":"%s","profile":"disk-audit","user":"root"}' "$id" >"$REQ/$id.json"
  chown rq "$REQ/$id.json"; chmod 0640 "$REQ/$id.json"
  run bot_request_decide 42 42 "g:$id:1h:disk-audit"
  [ "$status" -eq 0 ]
  [[ "$output" == "granted" ]]
  [ -f /etc/sudoers.d/llm2ssh-rq ]          # granted to rq (file owner)
  [ ! -f /etc/sudoers.d/llm2ssh-root ]      # NOT root
  [ "$(jq -r .decision "$RES/$id.json")" = "granted" ]
  "$L" revoke rq
}

@test "bot_request_decide uses the CALLBACK profile, not the (rewritten) file" {
  _load_bot
  export OWNER_USER_ID=42 OWNER_CHAT_ID=42
  id=bbcc2233
  # file was rewritten to docker-admin AFTER the card (with disk-audit) was sent
  printf '{"id":"%s","profile":"docker-admin","user":"rq"}' "$id" >"$REQ/$id.json"
  chown rq "$REQ/$id.json"; chmod 0640 "$REQ/$id.json"
  run bot_request_decide 42 42 "g:$id:1h:disk-audit"   # owner tapped the disk-audit card
  [ "$status" -eq 0 ]
  # granted disk-audit (from callback) -> its du wrapper is whitelisted, NOT docker-admin's start
  grep -q 'llm2ssh-du' /etc/sudoers.d/llm2ssh-rq
  ! grep -q 'docker start' /etc/sudoers.d/llm2ssh-rq
  "$L" revoke rq
}

@test "bot_request_decide refuses a non-requestable profile in the callback" {
  _load_bot
  export OWNER_USER_ID=42 OWNER_CHAT_ID=42
  id=ddee4455
  printf '{"id":"%s","profile":"disk-audit","user":"rq"}' "$id" >"$REQ/$id.json"
  chown rq "$REQ/$id.json"; chmod 0640 "$REQ/$id.json"
  run bot_request_decide 42 42 "g:$id:0:full"          # try to grant root
  [ "$status" -eq 0 ]
  [[ "$output" == "error" ]]
  [ ! -f /etc/sudoers.d/llm2ssh-rq ] || ! grep -q 'ALL=(ALL:ALL)' /etc/sudoers.d/llm2ssh-rq
}

@test "bot_request_decide rejects a non-owner and honours deny" {
  _load_bot
  export OWNER_USER_ID=42 OWNER_CHAT_ID=42
  id=ccdd3344
  printf '{"id":"%s","profile":"docker-ro","user":"rq"}' "$id" >"$REQ/$id.json"
  chown rq "$REQ/$id.json"; chmod 0640 "$REQ/$id.json"
  run bot_request_decide 999 42 "g:$id:1h:docker-ro"   # not the owner
  [ "$status" -ne 0 ]
  [ ! -f "$RES/$id.json" ]
  run bot_request_decide 42 42 "g:$id:x:docker-ro"     # owner denies
  [ "$status" -eq 0 ]
  [[ "$output" == "denied" ]]
  [ "$(jq -r .decision "$RES/$id.json")" = "denied" ]
}

@test "request client end-to-end: background granter -> client exits 0" {
  : >"$HB"    # pretend the bot is live
  # background 'granter' mimicking the bot: watch req, write granted res
  ( for _ in $(seq 1 20); do
      f="$(ls -1 "$REQ"/*.json 2>/dev/null | head -1)"
      if [ -n "$f" ]; then
        rid="$(basename "$f" .json)"
        printf '{"id":"%s","decision":"granted","note":"1h"}' "$rid" >"$RES/$rid.json"
        chmod 0640 "$RES/$rid.json"; break
      fi
      sleep 0.5
    done ) &
  gp=$!
  run runuser -u rq -- /usr/local/bin/llm2ssh-request docker-ro --reason "need docker"
  kill "$gp" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"granted"* ]]
}
