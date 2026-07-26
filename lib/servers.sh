# shellcheck shell=bash
# lib/servers.sh — multi-server registry + fan-out. One "hub" host runs the bot
# and reaches other boxes over SSH (as the restricted llm2ssh-hub user). The hub
# talks to nodes through the root-owned wrapper wrappers/llm2ssh-hub; this file
# holds the registry and the `servers` CLI.

[[ -n "${_LLM2SSH_SERVERS_SOURCED:-}" ]] && return 0
_LLM2SSH_SERVERS_SOURCED=1

LLM2SSH_SERVERS="$LLM2SSH_ETC/servers"
LLM2SSH_HUB_DIR="$LLM2SSH_ETC/hub"
LLM2SSH_HUB_KEY="$LLM2SSH_HUB_DIR/id_ed25519"
LLM2SSH_HUB_KNOWN="$LLM2SSH_HUB_DIR/known_hosts"
: "${LLM2SSH_BIN:=/usr/local/bin/llm2ssh}"

_valid_server_name() { [[ "${1:-}" =~ ^[a-zA-Z0-9._-]{1,32}$ ]]; }

# servers_target NAME -> ssh target (or "local"); exit 1 if unknown.
servers_target() {
  local name="${1:-local}"
  [[ "$name" == "local" ]] && { printf 'local'; return 0; }
  [[ -r "$LLM2SSH_SERVERS" ]] || return 1
  awk -v n="$name" '$1==n {print $2; f=1} END{exit !f}' "$LLM2SSH_SERVERS"
}

# servers_names -> every name, local first.
servers_names() {
  printf 'local\n'
  [[ -r "$LLM2SSH_SERVERS" ]] && awk 'NF && $1!~/^#/ {print $1}' "$LLM2SSH_SERVERS"
}

servers_add() {
  require_root
  local name="${1:-}" target="${2:-}"
  _valid_server_name "$name" || die_usage "usage: llm2ssh servers add <name> <ssh-target>   (name chars: a-zA-Z0-9._-)"
  [[ "$name" == "local" ]] && die "'local' is reserved (it is this host)"
  [[ -n "$target" ]] || die_usage "missing ssh target, e.g. llm2ssh-hub@203.0.113.5 or an ssh alias"
  [[ "$target" =~ [[:space:]] ]] && die "ssh target must be a single token"
  ensure_dir "$LLM2SSH_ETC" 0755 "root:root"
  local tmp; tmp="$(mktemp)"
  [[ -r "$LLM2SSH_SERVERS" ]] && awk -v n="$name" '$1!=n' "$LLM2SSH_SERVERS" >"$tmp"
  printf '%s %s\n' "$name" "$target" >>"$tmp"
  atomic_write "$LLM2SSH_SERVERS" 0644 "root:root" <"$tmp"; rm -f "$tmp"
  log "registered '$name' -> $target   (test: llm2ssh servers test $name)"
}

servers_remove() {
  require_root
  local name="${1:?usage: llm2ssh servers remove <name>}"
  [[ -r "$LLM2SSH_SERVERS" ]] || die "no servers registered"
  local tmp; tmp="$(mktemp)"; awk -v n="$name" '$1!=n' "$LLM2SSH_SERVERS" >"$tmp"
  atomic_write "$LLM2SSH_SERVERS" 0644 "root:root" <"$tmp"; rm -f "$tmp"
  log "removed '$name'"
}

servers_list() {
  printf 'local  (this host)\n'
  [[ -r "$LLM2SSH_SERVERS" ]] && awk 'NF && $1!~/^#/ {printf "%s  %s\n",$1,$2}' "$LLM2SSH_SERVERS"
}

# l2_on SERVER ARGS... — run `llm2ssh ARGS` on SERVER (local, or over ssh as root
# via the hub key). Used by the CLI; the bot goes through the llm2ssh-hub wrapper.
l2_on() {
  local server="${1:-local}"; shift || true
  local target; target="$(servers_target "$server")" || die "unknown server: $server (see: llm2ssh servers list)"
  if [[ "$target" == "local" ]]; then
    "$LLM2SSH_BIN" "$@"
  else
    have_cmd ssh || die "ssh not found (needed to reach remote servers)"
    ssh -i "$LLM2SSH_HUB_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
        -o UserKnownHostsFile="$LLM2SSH_HUB_KNOWN" -o StrictHostKeyChecking=accept-new \
        -- "$target" sudo -n llm2ssh "$@"
  fi
}

servers_test() {
  local name="${1:?usage: llm2ssh servers test <name>}"
  log "testing '$name'…"
  if l2_on "$name" version >/dev/null 2>&1; then log "  ✓ reachable"
  else die "  ✗ unreachable — check: ssh target, hub key authorized on the node (llm2ssh hub-authorize), sudoers"; fi
}

cmd_servers() {
  local action="${1:-list}"; shift || true
  case "$action" in
    add)       servers_add "$@" ;;
    remove|rm) servers_remove "$@" ;;
    list)      servers_list ;;
    test)      servers_test "$@" ;;
    *) die_usage "usage: llm2ssh servers add <name> <ssh-target> | list | remove <name> | test <name>" ;;
  esac
}
