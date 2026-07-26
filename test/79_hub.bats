#!/usr/bin/env bats
# Multi-server hub: hwstat, the server registry, key/authorize, and a REAL SSH
# loopback proving `llm2ssh-hub <node> <verb>` fans a command out over ssh to a
# node's restricted llm2ssh-hub user. Root; run via test/run.sh.

setup_file() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  if [ "$(id -u)" -ne 0 ]; then return 0; fi
  [ -x /usr/local/bin/llm2ssh ] || bash "$REPO/install.sh" --no-tools >/dev/null 2>&1
}

setup() {
  if [ "$(id -u)" -ne 0 ]; then skip "needs root (run via test/run.sh)"; fi
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  L=/usr/local/bin/llm2ssh
  HUB=/usr/local/lib/llm2ssh/bin/llm2ssh-hub
}

@test "hwstat produces output" {
  run "$L" hwstat disk; [ "$status" -eq 0 ]; [[ "$output" == *disk* ]]
  run "$L" hwstat cpu;  [[ "$output" == *load* ]]
}

@test "servers add / list / remove" {
  "$L" servers add nodeA llm2ssh-hub@198.51.100.7 >/dev/null
  "$L" servers list | grep -q 'nodeA  llm2ssh-hub@198.51.100.7'
  "$L" servers remove nodeA >/dev/null
  run bash -c "$L servers list | grep -q nodeA"; [ "$status" -ne 0 ]
}

@test "hub keygen + hub-authorize create the restricted node user (no full/delete)" {
  "$L" hub keygen >/dev/null
  [ -f /etc/llm2ssh/hub/id_ed25519 ]
  pub="$(cat /etc/llm2ssh/hub/id_ed25519.pub)"
  [[ "$pub" == ssh-ed25519* ]]
  "$L" hub-authorize "$pub" >/dev/null
  getent passwd llm2ssh-hub
  visudo -cf /etc/sudoers.d/llm2ssh-hub
  grep -q 'llm2ssh-bot-admin' /etc/sudoers.d/llm2ssh-hub          # admin only via the safe wrapper
  ! grep -qE 'NOPASSWD:.*/llm2ssh grant' /etc/sudoers.d/llm2ssh-hub  # never raw grant/full
  # key stored ROOT-owned (agent/hub user cannot self-persist)
  [ "$(stat -c '%U' /etc/llm2ssh/keys/llm2ssh-hub)" = root ]
}

@test "llm2ssh-hub fans a command out over REAL ssh (loopback node)" {
  command -v sshd >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null 2>&1 || skip "no sshd"
  ssh-keygen -A >/dev/null 2>&1 || true
  bash "$REPO/install.sh" --no-tools >/dev/null 2>&1     # ensure the sshd Match drop-in is active
  mkdir -p /run/sshd
  pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd -o LogLevel=ERROR 2>/dev/null || service ssh start 2>/dev/null || true
  sleep 1
  pgrep -x sshd >/dev/null 2>&1 || skip "sshd would not start in this container"

  "$L" hub keygen >/dev/null
  "$L" hub-authorize "$(cat /etc/llm2ssh/hub/id_ed25519.pub)" >/dev/null
  "$L" servers add self llm2ssh-hub@127.0.0.1 >/dev/null
  "$L" create hubtest --key "ssh-ed25519 AAAAtest a@ci" >/dev/null 2>&1 || true

  run "$HUB" self status --json
  echo "STATUS=$status OUT=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *hubtest* ]]                         # got the remote node's agent list over ssh

  # hardware over the hub too
  run "$HUB" self hwstat cpu
  [[ "$output" == *load* ]]

  "$L" servers remove self >/dev/null; "$L" delete hubtest --yes >/dev/null 2>&1 || true
}

@test "the /server picker keyboard lists registered servers" {
  "$L" servers add nodeB llm2ssh-hub@203.0.113.9 >/dev/null
  run bash -c '
    export LLM2SSH_LIB=/usr/local/lib/llm2ssh
    . /usr/local/lib/llm2ssh/lib/common.sh
    . /usr/local/lib/llm2ssh/bot/handlers.sh
    . /usr/local/lib/llm2ssh/bot/menus.sh
    _kb_servers | jq -e ".[][]|select(.callback_data==\"sv:nodeB\")" >/dev/null || exit 1
    _kb_servers | jq -e ".[][]|select(.callback_data==\"sv:local\")" >/dev/null || exit 2
    echo OK'
  [ "$status" -eq 0 ]; [[ "$output" == *OK* ]]
  "$L" servers remove nodeB >/dev/null
}
