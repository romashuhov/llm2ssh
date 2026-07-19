# shellcheck shell=bash
# lib/agents/claude.sh — Claude Code provider for Mode B.
# Implements the provider interface used by lib/agent.sh and profile-compile.sh:
#   agent_install, agent_auth, agent_exec_line, agent_status_line,
#   agent_compile_settings.
#
# Enforcement note: managed-settings.json (root-owned, /etc/claude-code) is the
# hard policy Claude Code cannot override. The workspace settings.json is
# advisory (agent-writable dir) — it only makes a well-behaved agent efficient.

[[ -n "${_LLM2SSH_AGENT_CLAUDE_SOURCED:-}" ]] && return 0
_LLM2SSH_AGENT_CLAUDE_SOURCED=1

CLAUDE_MANAGED_DIR="${LLM2SSH_ROOT}/etc/claude-code"
CLAUDE_MANAGED_SETTINGS="$CLAUDE_MANAGED_DIR/managed-settings.json"
CLAUDE_HOOK="/usr/local/lib/llm2ssh/hooks/pretooluse-gate"

# ---- Install ---------------------------------------------------------------
# APT repository (preferred): the binary lands in /usr/bin/claude ROOT-OWNED, so
# the agent cannot replace the very binary that enforces managed-settings/hooks.
# Falls back to the native installer only if explicitly requested (agent-writable
# ~/.local binary — weaker for the enforced-hook story; see docs/SECURITY.md).
CLAUDE_APT_KEY_URL="https://downloads.claude.ai/keys/claude-code.asc"
CLAUDE_APT_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
CLAUDE_APT_LINE="deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main"

agent_install() {
  local agent="$1" mode="${2:-}" home
  home="$(agent_home "$agent")"
  install -d -o "$agent" -g "$agent" -m 0750 "$home/.llm2ssh" 2>/dev/null || true

  if have_cmd claude && [[ "$mode" != "--native" ]]; then
    log "Claude Code already installed ($(command -v claude))"
    return 0
  fi

  if [[ "$mode" == "--native" ]]; then
    have_cmd curl || die "curl required"
    log "installing Claude Code for '$agent' (native installer, agent-writable)…"
    _as_agent "$agent" bash -lc 'curl -fsSL https://claude.ai/install.sh | bash' \
      || die "native Claude Code install failed"
    warn "native install places the binary in the agent's home (agent-writable). Prefer the apt method for enforcement."
    return 0
  fi

  # APT method (root-owned binary).
  have_cmd curl || die "curl required"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "$CLAUDE_APT_KEY_URL" -o /etc/apt/keyrings/claude-code.asc || die "could not fetch Claude Code signing key"
  # Verify the pinned fingerprint before trusting the repo.
  local got
  got="$(gpg --show-keys --with-colons --with-fingerprint /etc/apt/keyrings/claude-code.asc 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
  if [[ "$got" != "$CLAUDE_APT_FPR" ]]; then
    rm -f /etc/apt/keyrings/claude-code.asc
    die "Claude Code signing-key fingerprint mismatch (got '$got', want '$CLAUDE_APT_FPR') — refusing to install"
  fi
  printf '%s\n' "$CLAUDE_APT_LINE" >/etc/apt/sources.list.d/claude-code.list
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || die "apt-get update failed"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq claude-code || die "apt-get install claude-code failed"
  log "installed Claude Code (root-owned: $(command -v claude 2>/dev/null || echo /usr/bin/claude))"
}

# ---- Auth ------------------------------------------------------------------
# Credentials live in ~/.llm2ssh/agent.env (0600, agent-owned). Never in
# managed-settings (world-readable). Prompted with no echo.
agent_auth() {
  local agent="$1"; shift || true
  local mode="${1:-}"
  local home envf
  home="$(agent_home "$agent")"
  envf="$home/.llm2ssh/agent.env"
  install -d -o "$agent" -g "$agent" -m 0750 "$home/.llm2ssh" 2>/dev/null || true
  case "$mode" in
    --api-key)
      local key; read -r -s -p "Anthropic API key (input hidden): " key; echo >&2
      [[ -n "$key" ]] || die "no key entered"
      printf 'export ANTHROPIC_API_KEY=%q\n' "$key" | install -o "$agent" -g "$agent" -m 0600 /dev/stdin "$envf"
      log "stored API key for '$agent'"
      ;;
    --oauth-token)
      local tok; read -r -s -p "Claude Code OAuth token (from 'claude setup-token' on your machine): " tok; echo >&2
      [[ -n "$tok" ]] || die "no token entered"
      printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$tok" | install -o "$agent" -g "$agent" -m 0600 /dev/stdin "$envf"
      log "stored OAuth token for '$agent'"
      ;;
    --login|"")
      log "starting interactive login in the agent tmux session…"
      log "run: llm2ssh agent start $agent  then  llm2ssh agent attach $agent  and complete /login"
      ;;
    *) die_usage "usage: llm2ssh agent auth <agent> [--api-key|--oauth-token|--login]" ;;
  esac
}

# ---- Launch ----------------------------------------------------------------
# Shell command tmux runs as the agent. Sources agent.env, cds to workspace,
# execs claude (resuming the latest conversation when LLM2SSH_RESUME=1).
agent_exec_line() {
  local resume="${LLM2SSH_RESUME:-0}" flag=""
  [[ "$resume" == "1" ]] && flag=" --continue"
  printf 'bash -lc %q' "cd ~/workspace; [ -f ~/.llm2ssh/agent.env ] && . ~/.llm2ssh/agent.env; exec claude${flag}"
}

agent_status_line() {
  local agent="$1" home envf
  home="$(agent_home "$agent")"
  envf="$home/.llm2ssh/agent.env"
  if [[ -f "$envf" ]]; then printf 'auth       configured (%s)\n' "$(sed -n 's/^export \([A-Z_]*\)=.*/\1/p' "$envf" | head -1)"
  else printf 'auth       NOT configured (llm2ssh agent auth %s)\n' "$agent"; fi
  if _as_agent "$agent" bash -lc 'command -v claude >/dev/null 2>&1'; then printf 'cli        installed\n'
  else printf 'cli        NOT installed (llm2ssh agent install %s)\n' "$agent"; fi
}

# ---- Compile Claude-layer settings from the active profile -----------------
# Called by policy_compile with P_* already loaded for the current profile.
agent_compile_settings() {
  local agent="$1"
  have_cmd jq || return 0

  # (a) managed-settings.json — root-owned, enforced, host-global.
  ensure_dir "$CLAUDE_MANAGED_DIR" 0755 "root:root"
  jq -n --arg hook "$CLAUDE_HOOK" '{
    permissions: {
      deny: [
        "Bash(sudo -i)", "Bash(sudo -s)", "Bash(sudo su*)", "Bash(sudo bash*)",
        "Bash(sudo sh*)", "Bash(pkexec:*)", "Bash(su -*)", "Bash(su root*)",
        "Read(/etc/llm2ssh/**)", "Read(/home/*/.llm2ssh/**)",
        "Read(/home/*/.claude/.credentials.json)"
      ],
      disableBypassPermissionsMode: "disable"
    },
    allowManagedHooksOnly: true,
    env: { DISABLE_AUTOUPDATER: "1" },
    hooks: {
      PreToolUse: [ { matcher: "Bash", hooks: [ { type: "command", command: $hook, timeout: 200 } ] } ]
    }
  }' | atomic_write "$CLAUDE_MANAGED_SETTINGS" 0644 "root:root"

  # (b) workspace settings.json — advisory allow list derived from the profile.
  local home ws cdir
  home="$(agent_home "$agent")"
  [[ -n "$home" ]] || return 0
  ws="$home/workspace"; cdir="$ws/.claude"
  [[ -d "$ws" ]] || return 0
  install -d -o "$agent" -g "$agent" -m 0755 "$cdir" 2>/dev/null || mkdir -p "$cdir"

  local dbin allow=() spec rel
  dbin="$(resolve_docker_bin 2>/dev/null || true)"
  if [[ "${P_SUDO_ALL:-0}" -eq 1 ]]; then
    allow+=("Bash(sudo:*)")
  else
    for spec in ${P_SUDO[@]+"${P_SUDO[@]}"}; do
      rel="$spec"
      [[ -n "$dbin" ]] && rel="${rel//$dbin/docker}"
      allow+=("Bash(sudo $rel)")
    done
  fi
  allow+=("Bash(llm2ssh-ctx)")

  printf '%s\n' "${allow[@]}" | jq -R . | jq -s '{permissions:{allow:.}}' \
    | atomic_write "$cdir/settings.json" 0644 "root:root"
}
