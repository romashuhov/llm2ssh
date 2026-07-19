# test/helpers.bash — shared bats setup. Sourced by *.bats via `load helpers`.

setup_common() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export LLM2SSH_LIB="$REPO"
  LLM2SSH="$REPO/bin/llm2ssh"
  export LLM2SSH

  # Sandbox root so unit tests never touch the real system.
  export LLM2SSH_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$LLM2SSH_ROOT/etc" "$LLM2SSH_ROOT/run" \
           "$LLM2SSH_ROOT/var/lib/llm2ssh/agents" \
           "$LLM2SSH_ROOT/var/log/llm2ssh"
  # Fake os-release so os_check passes without depending on the host.
  printf 'ID=ubuntu\nID_LIKE=debian\n' >"$LLM2SSH_ROOT/etc/os-release"
}

# Source the library into the current shell (for function-level tests).
load_lib() {
  # shellcheck disable=SC1090
  . "$LLM2SSH_LIB/lib/common.sh"
  # shellcheck disable=SC1090
  . "$LLM2SSH_LIB/lib/state.sh"
}
