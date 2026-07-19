# shellcheck shell=bash
# lib/profile.sh — profile parser, validator, and preview.
#
# Profiles are DECLARATIVE and parsed with a read loop. They are NEVER sourced:
# a shared/untrusted profile that could run code would be RCE as root.
#
# profile_load NAME populates these globals (reset on every call):
#   P_NAME P_DESC              — strings
#   P_GROUPS[]                 — supplementary groups to add
#   P_SUDO[]                   — validated, absolute sudoers Cmnd specs
#   P_WARN[]                   — warnings printed at grant time
#   P_NEEDS_SERVICES           — 0/1 (requires --services)
#   P_SUDO_ALL                 — 0/1 (full root)

[[ -n "${_LLM2SSH_PROFILE_SOURCED:-}" ]] && return 0
_LLM2SSH_PROFILE_SOURCED=1

# Built-in denylist of binaries that must never appear in a profile `sudo` line.
# These grant a root shell (shell/pager/interpreter escapes) or read/write
# arbitrary files as root. A malicious shared profile must not be able to
# smuggle them in. Extendable via LLM2SSH_EXTRA_DENYLIST in /etc/llm2ssh/config.
_LLM2SSH_SUDO_DENYLIST="\
bash sh dash zsh ksh csh tcsh \
env find vi vim vim.basic view nano less more most pager man info \
tar rsync dd tee cp mv install \
awk gawk mawk sed perl python python2 python3 ruby node nodejs php lua \
xargs script expect socat nc ncat netcat ncat.openbsd \
ssh scp sftp wget curl ftp tftp \
chroot mount umount unshare nsenter setpriv capsh \
systemctl journalctl loginctl machinectl \
apt apt-get aptitude dpkg pip pip3 npm pipx gem \
make gcc cc g++ clang ld emacs ed ex pico busybox toybox \
crontab at visudo su sudo sudoedit passwd chpasswd usermod useradd \
mysql psql sqlite3 redis-cli \
git gdb strace ltrace zip unzip 7z cpio ionice taskset flock watch \
apt-key ansible ansible-playbook cmake scp.openssh rsh telnet screen byobu"

# Resolve the docker binary (supports snap at /snap/bin/docker). Prints the
# absolute path; returns non-zero if not found or not root-owned/secure.
resolve_docker_bin() {
  local bin
  bin="$(command -v docker 2>/dev/null || true)"
  [[ -n "$bin" ]] || return 1
  # Canonicalize and require root ownership + not group/other-writable.
  local real owner perms
  real="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
  owner="$(stat -c '%U' "$real" 2>/dev/null || echo '?')"
  perms="$(stat -c '%a' "$real" 2>/dev/null || echo '777')"
  [[ "$owner" == "root" ]] || { err "docker binary $real is not root-owned (owner=$owner)"; return 1; }
  # reject if group- or other-writable (last two octal digits' 2-bit)
  if (( 0${perms: -2:1} & 2 )) || (( 0${perms: -1:1} & 2 )); then
    err "docker binary $real is writable by non-root; refusing"; return 1
  fi
  printf '%s' "$real"
}

# profile_file NAME -> path, or non-zero if not found.
profile_file() {
  local name="$1" f
  for f in "$LLM2SSH_PROFILES_ETC/$name.profile" "$LLM2SSH_PROFILES_SYS/$name.profile"; do
    [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# _sudo_binary_denied SPEC -> 0 if the command's binary is on the denylist.
_sudo_binary_denied() {
  local spec="$1" bin base
  bin="${spec%% *}"          # first token = the binary path/token
  base="${bin##*/}"          # basename
  local deny="$_LLM2SSH_SUDO_DENYLIST ${LLM2SSH_EXTRA_DENYLIST:-}"
  local d
  for d in $deny; do
    [[ "$base" == "$d" ]] && return 0
    [[ "$bin"  == "$d" ]] && return 0
  done
  return 1
}

# profile_validate_sudo_line SPEC -> 0 if safe, else prints reason and returns 1.
# SPEC is a fully-resolved sudoers Cmnd (absolute path already substituted).
profile_validate_sudo_line() {
  local spec="$1"
  # Must start with an absolute path.
  [[ "$spec" == /* ]] || { err "sudo line must start with an absolute path: '$spec'"; return 1; }
  # No sudoers metacharacters (comma splits alias members => injection).
  case "$spec" in
    *,*|*:*|*=*|*\\*|*\(*|*\)*) err "sudo line contains a sudoers metacharacter (, : = \\ ( )): '$spec'"; return 1 ;;
  esac
  # No embedded newline (defensive; read already splits on \n).
  [[ "$spec" == *$'\n'* ]] && { err "sudo line contains a newline"; return 1; }
  # Binary must exist.
  local bin="${spec%% *}"
  [[ -x "$bin" ]] || { err "sudo binary not found or not executable: '$bin'"; return 1; }
  # Binary must not be a shell/pager/interpreter escape.
  if _sudo_binary_denied "$spec"; then
    err "sudo binary '${bin##*/}' is on the shell-escape denylist (would grant root shell): '$spec'"
    return 1
  fi
  return 0
}

# _profile_parse_into FILE  — low-level: append directives to P_* globals.
# Handles one directive per line; caller manages include recursion.
_profile_parse_into() {
  # is_include=1 when parsing an included profile: its name/description must NOT
  # clobber the top-level profile's (only groups/sudo/warn merge upward).
  local file="$1" is_include="${2:-0}" directive rest docker_bin="" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    # strip leading whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    directive="${line%%[[:space:]]*}"
    rest="${line#"$directive"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"   # ltrim value
    case "$directive" in
      name)        [[ "$is_include" == 0 ]] && P_NAME="$rest" ;;
      description) [[ "$is_include" == 0 ]] && P_DESC="$rest" ;;
      group)       P_GROUPS+=("$rest") ;;
      warn)        P_WARN+=("$rest") ;;
      ask)         P_ASK+=("$rest") ;;
      needs-services) [[ "$rest" == "yes" ]] && P_NEEDS_SERVICES=1 ;;
      sudo-all)       [[ "$rest" == "yes" ]] && P_SUDO_ALL=1 ;;
      include)
        # Cycle/dup guard: a profile is merged at most once. Because every
        # include is recorded in _PROFILE_VISITED and skipped thereafter, the
        # recursion is bounded by the number of distinct profiles — no infinite
        # loop is possible, and diamonds don't double-merge.
        case " $_PROFILE_VISITED " in
          *" $rest "*) continue ;;   # already merged (or self-include) — skip
        esac
        local inc; inc="$(profile_file "$rest")" || die_validation "included profile not found: '$rest'"
        _PROFILE_VISITED+=" $rest"
        _profile_parse_into "$inc" 1
        ;;
      sudo)
        # Resolve the %DOCKER% token to the real docker binary.
        if [[ "$rest" == *"%DOCKER%"* ]]; then
          if [[ -z "$docker_bin" ]]; then
            docker_bin="$(resolve_docker_bin)" || die_validation "profile '$P_NAME' needs docker, but no secure docker binary was found"
          fi
          rest="${rest//%DOCKER%/$docker_bin}"
        fi
        profile_validate_sudo_line "$rest" || die_validation "invalid sudo directive in profile"
        P_SUDO+=("$rest")
        ;;
      *)
        die_validation "unknown profile directive '$directive' (typo?)"
        ;;
    esac
  done <"$file"
}

# profile_load NAME — populate P_* globals. Dies on any validation error.
profile_load() {
  local name="$1" file
  file="$(profile_file "$name")" || die_notfound "no such profile: '$name'"
  P_NAME="$name"; P_DESC=""
  P_GROUPS=(); P_SUDO=(); P_WARN=(); P_ASK=()
  P_NEEDS_SERVICES=0; P_SUDO_ALL=0
  _PROFILE_VISITED=" $name "     # top profile counts as visited (self-include guard)
  _profile_parse_into "$file"
}

# list_profile_names — all available profile names (custom shadow shipped).
list_profile_names() {
  local seen=" " f n
  for f in "$LLM2SSH_PROFILES_ETC"/*.profile "$LLM2SSH_PROFILES_SYS"/*.profile; do
    [[ -e "$f" ]] || continue
    n="$(basename "$f" .profile)"
    [[ "$seen" == *" $n "* ]] && continue
    seen+="$n "
    printf '%s\n' "$n"
  done
}

cmd_profiles() {
  local n
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    P_DESC=""
    # cheap description read without full validation
    local f; f="$(profile_file "$n")"
    local desc; desc="$(grep -m1 '^description' "$f" 2>/dev/null | sed 's/^description[[:space:]]*//')"
    printf '%-16s %s\n' "$n" "$desc"
  done < <(list_profile_names)
}

cmd_profile() {
  local action="${1:-}"; shift || true
  case "$action" in
    show)
      local name="${1:-}"; [[ -n "$name" ]] || die_usage "usage: llm2ssh profile show <profile>"
      profile_load "$name"
      printf 'profile: %s\n' "$P_NAME"
      printf 'description: %s\n' "$P_DESC"
      if [[ "$P_SUDO_ALL" -eq 1 ]]; then
        printf 'grants: UNRESTRICTED ROOT (sudo ALL)\n'
      fi
      if [[ ${#P_GROUPS[@]} -gt 0 ]]; then
        printf 'groups: %s\n' "${P_GROUPS[*]}"
      fi
      if [[ ${#P_SUDO[@]} -gt 0 ]]; then
        printf 'sudo (as root, NOPASSWD):\n'
        local s; for s in "${P_SUDO[@]}"; do printf '  %s\n' "$s"; done
      elif [[ "$P_SUDO_ALL" -ne 1 ]]; then
        printf 'sudo: (none)\n'
      fi
      [[ "$P_NEEDS_SERVICES" -eq 1 ]] && printf 'requires: --services <unit,...>\n'
      if [[ ${#P_ASK[@]} -gt 0 ]]; then
        printf 'owner approval required for:\n'
        local a; for a in "${P_ASK[@]}"; do printf '  %s\n' "$a"; done
      fi
      local w; for w in ${P_WARN[@]+"${P_WARN[@]}"}; do printf 'warning: %s\n' "$w"; done
      ;;
    *)
      die_usage "usage: llm2ssh profile show <profile>"
      ;;
  esac
}
