# shellcheck shell=bash
# shellcheck disable=SC2034,SC1090,SC1091
# lib/common.sh — shared constants and helpers for llm2ssh.
# (Path constants are consumed by other sourced modules — hence SC2034 is off;
#  os-release is a trusted key=value system file — hence SC1090/SC1091 are off.)
# Sourced by bin/llm2ssh and every lib/*.sh. No side effects at source time
# beyond defining variables/functions. NEVER `source` untrusted files with this.

# --- Guard against double-sourcing -----------------------------------------
[[ -n "${_LLM2SSH_COMMON_SOURCED:-}" ]] && return 0
_LLM2SSH_COMMON_SOURCED=1

# Ensure sbin dirs are on PATH — sshd, useradd, usermod, visudo live there and
# a non-login root shell (or sudo env) may not include them.
case ":$PATH:" in
  *:/usr/sbin:*) ;;
  *) PATH="/usr/sbin:/sbin:$PATH"; export PATH ;;
esac

# --- Canonical paths (single source of truth) ------------------------------
# Library root: overridable so tests can run from a repo checkout.
: "${LLM2SSH_LIB:=/usr/local/lib/llm2ssh}"
# Prefix roots: overridable for rootless/container tests via LLM2SSH_ROOT.
: "${LLM2SSH_ROOT:=}"

LLM2SSH_ETC="${LLM2SSH_ROOT}/etc/llm2ssh"
LLM2SSH_VAR="${LLM2SSH_ROOT}/var/lib/llm2ssh"
LLM2SSH_LOG="${LLM2SSH_ROOT}/var/log/llm2ssh"
LLM2SSH_RUN="${LLM2SSH_ROOT}/run/llm2ssh"
LLM2SSH_SUDOERSD="${LLM2SSH_ROOT}/etc/sudoers.d"
LLM2SSH_SSHDD="${LLM2SSH_ROOT}/etc/ssh/sshd_config.d"
LLM2SSH_AUDITD="${LLM2SSH_ROOT}/etc/audit/rules.d"

LLM2SSH_CONFIG="${LLM2SSH_ETC}/config"
LLM2SSH_KEYS="${LLM2SSH_ETC}/keys"                  # AuthorizedKeysFile /etc/llm2ssh/keys/%u
LLM2SSH_AGENTS="${LLM2SSH_VAR}/agents"             # per-agent state dir
LLM2SSH_PROFILES_SYS="${LLM2SSH_LIB}/profiles"     # shipped presets (upgraded in place)
LLM2SSH_PROFILES_ETC="${LLM2SSH_ETC}/profiles.d"   # user/custom profiles (never upgraded)

# Shared group marking all managed agents (drives sshd Match Group).
LLM2SSH_GROUP="llm2ssh"
# Dedicated unprivileged user the Telegram bot daemon runs as.
LLM2SSH_BOT_USER="llm2ssh-bot"

# Load the trusted, root-owned global config if we can read it. Provides
# LLM2SSH_EXTRA_DENYLIST, LLM2SSH_TOOLS, etc. Guarded so the bot user (which
# cannot read the 0600 config) and rootless test sandboxes don't error.
if [[ -r "$LLM2SSH_CONFIG" ]]; then
  # shellcheck disable=SC1090
  . "$LLM2SSH_CONFIG" 2>/dev/null || true
fi

# Version string (read from installed VERSION or repo VERSION).
_llm2ssh_read_version() {
  local vf
  for vf in "${LLM2SSH_LIB}/VERSION" "$(dirname "${BASH_SOURCE[0]}")/../VERSION"; do
    if [[ -r "$vf" ]]; then head -n1 "$vf"; return 0; fi
  done
  echo "unknown"
}
LLM2SSH_VERSION="$(_llm2ssh_read_version)"

# --- Output helpers --------------------------------------------------------
# All human output goes to stderr so `--json` payloads on stdout stay clean.
_llm2ssh_color() {
  # Emit color codes only when stderr is a TTY and NO_COLOR is unset.
  if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then printf '%s' "$1"; fi
}
log()  { printf '%s[llm2ssh]%s %s\n' "$(_llm2ssh_color $'\033[36m')" "$(_llm2ssh_color $'\033[0m')" "$*" >&2; }
warn() { printf '%s[llm2ssh]%s %s\n' "$(_llm2ssh_color $'\033[33m')" "$(_llm2ssh_color $'\033[0m')" "warning: $*" >&2; }
err()  { printf '%s[llm2ssh]%s %s\n' "$(_llm2ssh_color $'\033[31m')" "$(_llm2ssh_color $'\033[0m')" "error: $*" >&2; }

# Exit codes (contract): 0 ok, 1 error, 2 usage, 3 validation failed, 4 not found.
EX_OK=0; EX_ERR=1; EX_USAGE=2; EX_VALIDATION=3; EX_NOTFOUND=4

die()       { err "$*"; exit "$EX_ERR"; }
die_usage() { err "$*"; exit "$EX_USAGE"; }
die_validation() { err "$*"; exit "$EX_VALIDATION"; }
die_notfound()   { err "$*"; exit "$EX_NOTFOUND"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Time helpers (used across many modules — kept here so daemons that don't source
# grant.sh still have them).
now_epoch() { date -u +%s; }
fmt_epoch() { # fmt_epoch EPOCH -> human UTC, or "never" for 0/empty
  local e="${1:-0}"
  [[ -z "$e" || "$e" -eq 0 ]] && { printf 'never'; return; }
  date -u -d "@$e" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || printf '@%s' "$e"
}

# confirm PROMPT [EXPECT]
#   With EXPECT: require the user to type EXPECT exactly (used for `full`/destructive).
#   Without: a plain y/N. Honors --yes via the global LLM2SSH_ASSUME_YES.
confirm() {
  local prompt="$1" expect="${2:-}"
  if [[ "${LLM2SSH_ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  if [[ ! -t 0 ]]; then
    err "confirmation required but stdin is not a TTY (use --yes to proceed non-interactively)"
    return 1
  fi
  if [[ -n "$expect" ]]; then
    local ans
    read -r -p "$prompt " ans
    [[ "$ans" == "$expect" ]]
  else
    local ans
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]]
  fi
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "must run as root (try: sudo llm2ssh ...)"
  fi
}

# os_check: refuse anything that is not Debian/Ubuntu family.
os_check() {
  local osrel="${LLM2SSH_ROOT}/etc/os-release"
  [[ -r "$osrel" ]] || die "cannot read $osrel — unsupported OS"
  # shellcheck disable=SC1090
  local ID="" ID_LIKE=""
  ID="$(. "$osrel"; printf '%s' "${ID:-}")"
  ID_LIKE="$(. "$osrel"; printf '%s' "${ID_LIKE:-}")"
  case "$ID" in
    ubuntu|debian) return 0 ;;
  esac
  case " $ID_LIKE " in
    *" debian "*) return 0 ;;
  esac
  die "unsupported OS (ID=$ID ID_LIKE=$ID_LIKE); llm2ssh v1 targets Ubuntu/Debian"
}

# Agent name policy: lowercase, starts with letter/underscore, <=32 chars.
# Rejects anything that could be a shell/sudoers/glob metacharacter.
valid_agent_name() {
  local name="$1"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

require_valid_agent_name() {
  valid_agent_name "$1" || die_usage "invalid agent name '$1' (allowed: ^[a-z_][a-z0-9_-]{0,31}\$)"
}

# atomic_install SRC DEST MODE [OWNER:GROUP]
# Install a file atomically with mode/owner (rename on same filesystem).
atomic_install() {
  local src="$1" dest="$2" mode="$3" owner="${4:-}"
  local tmp
  tmp="$(dirname "$dest")/.$(basename "$dest").tmp.$$"
  cat "$src" >"$tmp"
  chmod "$mode" "$tmp"
  [[ -n "$owner" ]] && chown "$owner" "$tmp"
  mv -f "$tmp" "$dest"
}

# atomic_write DEST MODE [OWNER:GROUP]  (content on stdin)
atomic_write() {
  local dest="$1" mode="$2" owner="${3:-}"
  local tmp
  tmp="$(dirname "$dest")/.$(basename "$dest").tmp.$$"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  [[ -n "$owner" ]] && chown "$owner" "$tmp"
  mv -f "$tmp" "$dest"
}

# ensure_dir DIR MODE [OWNER:GROUP]
ensure_dir() {
  local dir="$1" mode="$2" owner="${3:-}"
  mkdir -p "$dir"
  chmod "$mode" "$dir"
  [[ -n "$owner" ]] && chown "$owner" "$dir"
}

# Global lock around mutating operations (gc vs interactive races).
# with_lock CMD...  — runs CMD under an flock on /run/llm2ssh.lock.
with_lock() {
  local lockfile="${LLM2SSH_RUN%/}/.llm2ssh.lock"
  mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true
  if have_cmd flock; then
    exec 9>"$lockfile" || die "cannot open lock $lockfile"
    flock 9 || die "cannot acquire lock $lockfile"
  fi
  "$@"
}
