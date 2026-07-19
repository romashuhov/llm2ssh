# shellcheck shell=bash
# lib/state.sh — per-agent state store. Flat key=value files under
# /var/lib/llm2ssh/agents/<agent>/state (root 0600). Values are single-line,
# no shell evaluation: we parse with a read loop, never `source`.

[[ -n "${_LLM2SSH_STATE_SOURCED:-}" ]] && return 0
_LLM2SSH_STATE_SOURCED=1

# agent_dir AGENT -> path to the agent's state directory
agent_dir() { printf '%s/%s' "$LLM2SSH_AGENTS" "$1"; }

agent_state_file() { printf '%s/%s/state' "$LLM2SSH_AGENTS" "$1"; }

agent_exists() { [[ -d "$(agent_dir "$1")" ]]; }

require_agent_exists() {
  agent_exists "$1" || die_notfound "no such agent: '$1' (create it with: llm2ssh create $1)"
}

# state_init AGENT — create the agent state dir skeleton (idempotent).
state_init() {
  local a="$1" d
  d="$(agent_dir "$a")"
  ensure_dir "$d" 0700 "root:root"
}

# state_get AGENT KEY [DEFAULT] — echo the value or DEFAULT if unset.
state_get() {
  local a="$1" key="$2" def="${3:-}" file k v
  file="$(agent_state_file "$a")"
  [[ -r "$file" ]] || { printf '%s' "$def"; return 0; }
  while IFS='=' read -r k v; do
    if [[ "$k" == "$key" ]]; then printf '%s' "$v"; return 0; fi
  done <"$file"
  printf '%s' "$def"
}

# state_set AGENT KEY VALUE — set/replace a key atomically.
# Values must be single-line and contain no '=' in the key; value is stored raw.
state_set() {
  local a="$1" key="$2" val="$3" file tmp found=0
  file="$(agent_state_file "$a")"
  ensure_dir "$(dirname "$file")" 0700 "root:root"
  [[ -f "$file" ]] || { : >"$file"; chmod 0600 "$file"; }
  tmp="$(dirname "$file")/.state.tmp.$$"
  : >"$tmp"
  while IFS='=' read -r k v; do
    if [[ "$k" == "$key" ]]; then
      printf '%s=%s\n' "$key" "$val" >>"$tmp"; found=1
    else
      printf '%s=%s\n' "$k" "$v" >>"$tmp"
    fi
  done <"$file"
  [[ "$found" -eq 0 ]] && printf '%s=%s\n' "$key" "$val" >>"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

# state_del AGENT KEY — remove a key.
state_del() {
  local a="$1" key="$2" file tmp
  file="$(agent_state_file "$a")"
  [[ -f "$file" ]] || return 0
  tmp="$(dirname "$file")/.state.tmp.$$"
  : >"$tmp"
  while IFS='=' read -r k v; do
    [[ "$k" == "$key" ]] && continue
    printf '%s=%s\n' "$k" "$v" >>"$tmp"
  done <"$file"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

# list_agents — print all agent names, one per line.
list_agents() {
  [[ -d "$LLM2SSH_AGENTS" ]] || return 0
  local d
  for d in "$LLM2SSH_AGENTS"/*/; do
    [[ -d "$d" ]] || continue
    basename "$d"
  done
}
