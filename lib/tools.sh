# shellcheck shell=bash
# lib/tools.sh — install a curated set of monitoring/utility packages so the
# agent actually has tooling to work with. Installing a binary grants NO
# privilege; what the agent may RUN is still governed by profiles/sudoers.

[[ -n "${_LLM2SSH_TOOLS_SOURCED:-}" ]] && return 0
_LLM2SSH_TOOLS_SOURCED=1

tools_default_file() { printf '%s/lib/tools.default' "$LLM2SSH_LIB"; }

# tools_list — the effective package list: LLM2SSH_TOOLS from /etc/llm2ssh/config
# (if set) overrides the shipped default file. One package name per line.
tools_list() {
  if [[ -n "${LLM2SSH_TOOLS:-}" ]]; then
    local p
    for p in $LLM2SSH_TOOLS; do printf '%s\n' "$p"; done
    return 0
  fi
  local f; f="$(tools_default_file)"
  [[ -r "$f" ]] || return 0
  # strip comments (whole-line and trailing) and blanks, take the first field
  sed -e 's/#.*$//' -e 's/[[:space:]]*$//' "$f" | awk 'NF{print $1}'
}

_pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

# tools_install [extra...] — best-effort install of the list (+extras). Never
# aborts the caller: a package unavailable on this mirror is logged and skipped.
tools_install() {
  have_cmd apt-get || { warn "apt-get not found; cannot install tools"; return 0; }
  local pkgs=() p
  while IFS= read -r p; do [[ -n "$p" ]] && pkgs+=("$p"); done < <(tools_list)
  pkgs+=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && { log "no tools configured"; return 0; }
  local missing=()
  for p in "${pkgs[@]}"; do _pkg_installed "$p" || missing+=("$p"); done
  [[ ${#missing[@]} -eq 0 ]] && { log "monitoring tools already present"; return 0; }
  log "installing tools: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || warn "apt-get update failed"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1; then
    log "installed ${#missing[@]} tool package(s)"
  else
    warn "batch install failed; retrying package-by-package"
    for p in "${missing[@]}"; do
      if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p" >/dev/null 2>&1; then
        log "  + $p"
      else
        warn "  ! could not install $p (skipped)"
      fi
    done
  fi
  return 0
}

_tools_status() {
  local p any=0 n_inst=0 n_miss=0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    any=1
    if _pkg_installed "$p"; then printf '  [installed] %s\n' "$p"; n_inst=$((n_inst+1))
    else printf '  [ missing ] %s\n' "$p"; n_miss=$((n_miss+1)); fi
  done < <(tools_list)
  [[ "$any" -eq 0 ]] && { log "no tools configured"; return 0; }
  log "$n_inst installed, $n_miss missing (install: llm2ssh tools install)"
}

cmd_tools() {
  local action="${1:-list}"; shift || true
  case "$action" in
    install) require_root; tools_install "$@" ;;
    list|status) _tools_status ;;
    *) die_usage "usage: llm2ssh tools install [pkg...] | list" ;;
  esac
}

doctor_extra_tools() {
  local total=0 n_miss=0 p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    total=$((total+1))
    _pkg_installed "$p" || n_miss=$((n_miss+1))
  done < <(tools_list)
  [[ "$total" -eq 0 ]] && return 0
  if [[ "$n_miss" -eq 0 ]]; then
    doctor_ok "monitoring tools ($total present)"
  else
    doctor_warn "monitoring tools" "$n_miss of $total missing — run: llm2ssh tools install"
  fi
}
