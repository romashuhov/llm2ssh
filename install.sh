#!/usr/bin/env bash
# install.sh — llm2ssh installer / upgrader.
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/llm2ssh/main/install.sh | sudo bash
#
# Two modes:
#   LOCAL  — run from a repo checkout / unpacked tarball (installs from here).
#   REMOTE — piped via curl (downloads the pinned release tarball, verifies
#            its sha256, then installs from the unpacked copy).
#
# Re-running upgrades code in /usr/local/lib/llm2ssh and /usr/local/bin only;
# it never touches /etc/llm2ssh, /var/lib/llm2ssh, or /var/log/llm2ssh.
set -euo pipefail

# sshd/useradd/visudo live in sbin, which may be absent from a sudo/root PATH.
case ":$PATH:" in *:/usr/sbin:*) ;; *) PATH="/usr/sbin:/sbin:$PATH"; export PATH ;; esac

# ---- Pinned release (REMOTE mode). Fill these in at release time. ----------
LLM2SSH_REPO="OWNER/llm2ssh"
LLM2SSH_PIN_VERSION=""            # e.g. v0.1.0
LLM2SSH_PIN_SHA256=""             # sha256 of the release tarball

PREFIX_BIN="/usr/local/bin"
PREFIX_LIB="/usr/local/lib/llm2ssh"

_log()  { printf '[install] %s\n' "$*" >&2; }
_die()  { printf '[install] error: %s\n' "$*" >&2; exit 1; }

# ---- Preconditions ---------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || _die "must run as root (pipe to 'sudo bash')"

_os_ok() {
  [[ -r /etc/os-release ]] || return 1
  local ID ID_LIKE
  ID="$(. /etc/os-release; printf '%s' "${ID:-}")"
  ID_LIKE="$(. /etc/os-release; printf '%s' "${ID_LIKE:-}")"
  case "$ID" in ubuntu|debian) return 0 ;; esac
  case " $ID_LIKE " in *" debian "*) return 0 ;; esac
  return 1
}
_os_ok || _die "unsupported OS; llm2ssh v1 targets Ubuntu/Debian"

# ---- Options ---------------------------------------------------------------
WITH_AUDITD=1
WITH_TOOLS=1
for arg in "$@"; do
  case "$arg" in
    --no-auditd) WITH_AUDITD=0 ;;
    --no-tools)  WITH_TOOLS=0 ;;
    *) _die "unknown option: $arg" ;;
  esac
done

# ---- Locate the source tree ------------------------------------------------
SRC=""
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ -n "$_self_dir" && -f "$_self_dir/lib/common.sh" && -f "$_self_dir/bin/llm2ssh" ]]; then
  SRC="$_self_dir"
  _log "local install from $SRC"
else
  # REMOTE mode
  [[ -n "$LLM2SSH_PIN_VERSION" && -n "$LLM2SSH_PIN_SHA256" ]] \
    || _die "remote install not configured (no pinned version/sha256). Clone the repo and run ./install.sh"
  command -v curl >/dev/null || _die "curl is required"
  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' EXIT
  url="https://github.com/${LLM2SSH_REPO}/archive/refs/tags/${LLM2SSH_PIN_VERSION}.tar.gz"
  _log "downloading $url"
  curl -fsSL "$url" -o "$tmpd/src.tgz" || _die "download failed"
  got="$(sha256sum "$tmpd/src.tgz" | awk '{print $1}')"
  [[ "$got" == "$LLM2SSH_PIN_SHA256" ]] || _die "sha256 mismatch (got $got, want $LLM2SSH_PIN_SHA256)"
  tar -xzf "$tmpd/src.tgz" -C "$tmpd"
  SRC="$(find "$tmpd" -maxdepth 1 -type d -name 'llm2ssh-*' | head -n1)"
  [[ -n "$SRC" ]] || _die "unpacked tree not found"
fi

# ---- Dependencies ----------------------------------------------------------
_apt_install() {
  local pkgs=("$@") missing=()
  local p
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  _log "installing: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || _die "apt-get update failed"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" || _die "apt-get install failed"
}
_apt_install sudo curl jq tmux
if [[ "$WITH_AUDITD" -eq 1 ]]; then
  _apt_install auditd || _log "auditd install failed; non-sudo command audit will be DISABLED"
fi

# ---- Users & groups --------------------------------------------------------
# Two groups: llm2ssh (marks agents; drives sshd Match) and llm2ssh-bot (the
# bot's private group so agents cannot write the bot-only notify/res spools).
getent group llm2ssh >/dev/null || { _log "creating group llm2ssh"; groupadd --system llm2ssh; }
getent group llm2ssh-bot >/dev/null || { _log "creating group llm2ssh-bot"; groupadd --system llm2ssh-bot; }
if ! getent passwd llm2ssh-bot >/dev/null; then
  _log "creating system user llm2ssh-bot"
  # Primary group llm2ssh-bot (notify/res ownership); supplementary llm2ssh
  # (to READ agent-written approval requests in req/).
  useradd --system --gid llm2ssh-bot --groups llm2ssh --home-dir /nonexistent \
          --shell /usr/sbin/nologin --comment "llm2ssh telegram bot" llm2ssh-bot
else
  usermod -g llm2ssh-bot -aG llm2ssh llm2ssh-bot 2>/dev/null || true
fi

# ---- Install code (upgrade-safe) -------------------------------------------
_log "installing code to $PREFIX_LIB"
install -d -m 0755 "$PREFIX_LIB"
# Mirror the tree; only code dirs, never state.
for d in lib profiles wrappers hooks bot systemd tmpfiles.d; do
  [[ -d "$SRC/$d" ]] || continue
  rm -rf "${PREFIX_LIB:?}/$d"
  cp -a "$SRC/$d" "$PREFIX_LIB/$d"
done
install -m 0644 "$SRC/VERSION" "$PREFIX_LIB/VERSION"
# Make wrappers/hooks executable.
[[ -d "$PREFIX_LIB/wrappers" ]] && chmod 0755 "$PREFIX_LIB/wrappers/"* 2>/dev/null || true
[[ -d "$PREFIX_LIB/hooks" ]]    && chmod 0755 "$PREFIX_LIB/hooks/"* 2>/dev/null || true
[[ -d "$PREFIX_LIB/bot" ]]      && chmod 0755 "$PREFIX_LIB/bot/llm2ssh-botd" "$PREFIX_LIB/bot/relay-exec" 2>/dev/null || true

# Sudo-whitelisted wrappers go under a stable path referenced by sudoers.
install -d -m 0755 "$PREFIX_LIB/bin"
[[ -f "$SRC/wrappers/llm2ssh-svc" ]] && install -m 0755 "$SRC/wrappers/llm2ssh-svc" "$PREFIX_LIB/bin/llm2ssh-svc"
[[ -f "$SRC/bot/relay-exec" ]]       && install -m 0755 "$SRC/bot/relay-exec"       "$PREFIX_LIB/bin/relay-exec"

# CLI entrypoint.
install -m 0755 "$SRC/bin/llm2ssh" "$PREFIX_BIN/llm2ssh"
# World-executable helpers used by agents (list may grow).
# shellcheck disable=SC2043
for helper in llm2ssh-ctx; do
  [[ -f "$SRC/wrappers/$helper" ]] && install -m 0755 "$SRC/wrappers/$helper" "$PREFIX_BIN/$helper"
done
# Approval client (called by hook as agent, and by gated sudo wrappers).
[[ -f "$SRC/wrappers/llm2ssh-approve" ]] && install -m 0755 "$SRC/wrappers/llm2ssh-approve" "$PREFIX_BIN/llm2ssh-approve"

# ---- Create state/config dirs (preserve existing) --------------------------
_log "creating state directories"
install -d -m 0755 /etc/llm2ssh
install -d -m 0755 /etc/llm2ssh/keys
install -d -m 0755 /etc/llm2ssh/profiles.d
install -d -m 0700 /var/lib/llm2ssh
install -d -m 0700 /var/lib/llm2ssh/agents
install -d -m 0700 /var/log/llm2ssh

# Default config — never clobber an existing one.
if [[ ! -f /etc/llm2ssh/config ]]; then
  install -m 0600 /dev/null /etc/llm2ssh/config
  cat >/etc/llm2ssh/config <<'CFG'
# /etc/llm2ssh/config — global llm2ssh configuration (root 0600).
# May later hold the Telegram bot token; keep it 0600.

# Extra binaries to forbid in profile `sudo` lines, beyond the built-in
# shell-escape denylist. Space-separated absolute names or basenames.
LLM2SSH_EXTRA_DENYLIST=""

# Override the monitoring/utility packages installed at init (space-separated).
# Leave unset to use the shipped default list (see: llm2ssh tools list).
# LLM2SSH_TOOLS=""
CFG
fi

# ---- tmpfiles (runtime spool tree) -----------------------------------------
if [[ -f "$PREFIX_LIB/tmpfiles.d/llm2ssh.conf" ]]; then
  install -m 0644 "$PREFIX_LIB/tmpfiles.d/llm2ssh.conf" /etc/tmpfiles.d/llm2ssh.conf
  if command -v systemd-tmpfiles >/dev/null; then
    systemd-tmpfiles --create /etc/tmpfiles.d/llm2ssh.conf || _log "systemd-tmpfiles apply warned"
  fi
fi
# Create the /run tree explicitly too (works in containers / before first boot).
mkdir -p /run/llm2ssh/agents /run/llm2ssh/approvals/req /run/llm2ssh/approvals/res \
         /run/llm2ssh/notify /run/llm2ssh/relay
chmod 0755 /run/llm2ssh /run/llm2ssh/agents /run/llm2ssh/approvals
chown root:llm2ssh     /run/llm2ssh/approvals/req    && chmod 3770 /run/llm2ssh/approvals/req
chown llm2ssh-bot:llm2ssh     /run/llm2ssh/approvals/res && chmod 2750 /run/llm2ssh/approvals/res
chown root:llm2ssh-bot  /run/llm2ssh/notify          && chmod 2770 /run/llm2ssh/notify
chown llm2ssh-bot:llm2ssh-bot /run/llm2ssh/relay     && chmod 2770 /run/llm2ssh/relay

# ---- sshd hardening drop-in (only if sshd is installed) --------------------
if command -v sshd >/dev/null && [[ -f "$SRC/templates/sshd-match.conf" ]]; then
  install -d -m 0755 /etc/ssh/sshd_config.d
  dropin=/etc/ssh/sshd_config.d/60-llm2ssh.conf
  backup=""
  [[ -f "$dropin" ]] && { backup="$dropin.bak.$$"; cp -a "$dropin" "$backup"; }
  install -m 0644 "$SRC/templates/sshd-match.conf" "$dropin"
  # sshd -t needs the privsep dir; create it if the daemon was never started.
  [[ -d /run/sshd ]] || mkdir -p /run/sshd
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || _log "ssh reload deferred"
    [[ -n "$backup" ]] && rm -f "$backup"
    # Warn if the main config won't even read the drop-in dir.
    if ! grep -Rqs -E '^\s*Include\s+.*sshd_config\.d' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null; then
      _log "WARNING: /etc/ssh/sshd_config has no 'Include .../sshd_config.d/*.conf' — the llm2ssh drop-in may be ignored"
    fi
  else
    _log "WARNING: sshd -t failed with the llm2ssh drop-in; rolling it back"
    if [[ -n "$backup" ]]; then mv -f "$backup" "$dropin"; else rm -f "$dropin"; fi
  fi
fi

# ---- systemd units (installed if present; enabled in later milestones) -----
if [[ -d "$PREFIX_LIB/systemd" ]] && command -v systemctl >/dev/null; then
  for unit in "$PREFIX_LIB"/systemd/*.{service,timer}; do
    [[ -f "$unit" ]] || continue
    install -m 0644 "$unit" "/etc/systemd/system/$(basename "$unit")"
  done
  systemctl daemon-reload || true
  if [[ -f /etc/systemd/system/llm2ssh-gc.timer ]]; then
    systemctl enable --now llm2ssh-gc.timer >/dev/null 2>&1 || _log "gc timer enable deferred"
  fi
fi

# ---- Monitoring / utility tools -------------------------------------------
if [[ "$WITH_TOOLS" -eq 1 ]]; then
  _log "installing monitoring/utility tools (skip with --no-tools)…"
  "$PREFIX_BIN/llm2ssh" tools install || _log "some tools could not be installed (continuing)"
fi

_log "installed llm2ssh $(cat "$PREFIX_LIB/VERSION")"
_log "run 'sudo llm2ssh doctor' to verify, then 'llm2ssh help'"
