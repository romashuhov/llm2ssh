# shellcheck shell=bash
# lib/hwstat.sh — `llm2ssh hwstat <what>`: hardware readouts from world-readable
# sources (df/free/ps/sensors/lsblk). A first-class subcommand so the Telegram
# bot gets identical output whether the box is local or reached over the hub.

[[ -n "${_LLM2SSH_HWSTAT_SOURCED:-}" ]] && return 0
_LLM2SSH_HWSTAT_SOURCED=1

_hw_disk() {
  printf '💾 disk:\n'
  df -h -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk 'NR>1{
    u=$5; gsub(/%/,"",u); w=(u+0>=85)?" ⚠️":"";
    printf "• %s : %s/%s (%s)%s\n", $6, $3, $2, $5, w }'
}
_hw_mem() {
  printf '🧠 memory:\n'
  free -h 2>/dev/null | awk '/^Mem:/{printf "• RAM: %s used / %s total (free %s)\n",$3,$2,$4} /^Swap:/ && $2!="0B"{printf "• swap: %s / %s\n",$3,$2}'
  printf 'top by mem:\n'
  ps -eo comm,%mem,%cpu --sort=-%mem 2>/dev/null | awk 'NR>1 && NR<=6{printf "  %-16s %5s%%m %5s%%c\n",$1,$2,$3}'
}
_hw_cpu() {
  local load nc
  load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"; nc="$(nproc 2>/dev/null || echo '?')"
  printf '⚙️ cpu: load %s  (%s cores)\n' "${load:-?}" "$nc"
  printf 'top by cpu:\n'
  ps -eo comm,%cpu,%mem --sort=-%cpu 2>/dev/null | awk 'NR>1 && NR<=6{printf "  %-16s %5s%%c %5s%%m\n",$1,$2,$3}'
}
_hw_temp() {
  if ! have_cmd sensors; then
    printf '🌡 sensors not available — install lm-sensors (llm2ssh tools install), then: sudo sensors-detect\n'; return
  fi
  local out; out="$(sensors -A 2>/dev/null | grep -iE '°c|rpm' | sed 's/  */ /g')"
  [[ -n "$out" ]] && { printf '🌡 sensors:\n%s\n' "$out"; } || printf '🌡 no temperature sensors detected (try: sudo sensors-detect)\n'
}
_hw_top() {
  printf '📊 top processes:\n'
  ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | awk 'NR>1 && NR<=9{printf "  %6s %-16s %5s%%c %5s%%m\n",$1,$2,$3,$4}'
}
_hw_overview() {
  local model cores ram disks
  model="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  [[ -n "$model" ]] || model="$(awk -F: '/model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  cores="$(nproc 2>/dev/null || echo '?')"; ram="$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
  printf '🖥 %s\ncpu: %s (%s cores)\nram: %s\n' "$(hostname)" "${model:-?}" "$cores" "${ram:-?}"
  disks="$(lsblk -d -n -o NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3=="disk"{m=""; for(k=4;k<=NF;k++) m=m" "$k; printf "  %s  %s%s\n",$1,$2,m}')"
  [[ -n "$disks" ]] && printf 'disks:\n%s\n' "$disks"
}

cmd_hwstat() {
  case "${1:-all}" in
    disk) _hw_disk ;;
    mem)  _hw_mem ;;
    cpu)  _hw_cpu ;;
    temp|sensors) _hw_temp ;;
    top)  _hw_top ;;
    hw|overview) _hw_overview ;;
    all)  _hw_overview; echo; _hw_disk; echo; _hw_mem; echo; _hw_temp ;;
    *) die_usage "usage: llm2ssh hwstat disk|mem|cpu|temp|top|hw|all" ;;
  esac
}
