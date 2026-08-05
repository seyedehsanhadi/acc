#!/system/bin/sh
# hangwatch.sh - catch the daemon hanging while it is still "alive", and record WHERE.
#
# Observed on a Pixel 6a: acc.lock pointed at pid 30188, /proc/30188 existed, process state S,
# and flight.log had not grown in 20s. The loop was dead. Nothing enforced a limit, the firmware
# charge level stayed wherever it happened to be, and every health check said "daemon alive".
# `acc -D restart` fixed it instantly.
#
# Every existing check tests the wrong thing: acc.lock plus /proc/$pid answers "does the process
# exist", not "is it doing anything". flight.log is the honest heartbeat, because the daemon appends
# to it once per loop.
#
# Read-only. Watches, and on a stall captures what the process is blocked on.

D=/data/adb/vr25/acc-data
F=$D/logs/flight.log
TD=/dev/.vr25/acc
OUT=/sdcard/Download/acc-hang-$(date +%Y%m%d-%H%M%S).txt
[ -d /sdcard/Download ] && [ -w /sdcard/Download ] || OUT=/data/local/tmp/acc-hang-$(date +%Y%m%d-%H%M%S).txt
STALL=${1:-45}      # seconds without a flight.log line before we call it a stall
RUNFOR=${2:-1800}

log(){ echo "$*"; echo "$*" >> "$OUT"; }

log "=== hangwatch $(date) ==="
log "device=$(getprop ro.product.device) stall-threshold=${STALL}s run=${RUNFOR}s"

capture(){
  P=$(cat $TD/acc.lock 2>/dev/null)
  log ""
  log "--- STALL DETECTED $(date) ---"
  log "pid=$P exists=$([ -d /proc/$P ] && echo yes || echo NO)"
  [ -d "/proc/$P" ] || { log "the process is gone - it died rather than hung"; return; }
  log "state    : $(awk '{print $3}' /proc/$P/stat 2>/dev/null)"
  log "wchan    : $(cat /proc/$P/wchan 2>/dev/null)"
  log "utime/stime: $(awk '{print $14"/"$15}' /proc/$P/stat 2>/dev/null)"
  log "cmdline  : $(tr '\0' ' ' < /proc/$P/cmdline 2>/dev/null)"
  log "--- open fds (a blocked write shows its target here) ---"
  ls -l /proc/$P/fd 2>/dev/null | sed 's/^/    /' >> "$OUT"
  log "--- stack ---"
  cat /proc/$P/stack 2>/dev/null | sed 's/^/    /' >> "$OUT" || log "    (kernel stack not readable)"
  log "--- children (a backgrounded write that never returned) ---"
  for c in /proc/[0-9]*; do
    _p=${c#/proc/}
    _pp=$(awk '{print $4}' $c/stat 2>/dev/null)
    [ "$_pp" = "$P" ] || continue
    log "    child $_p state=$(awk '{print $3}' $c/stat 2>/dev/null) wchan=$(cat $c/wchan 2>/dev/null) cmd=$(tr '\0' ' ' < $c/cmdline 2>/dev/null)"
    ls -l $c/fd 2>/dev/null | sed 's/^/        /' >> "$OUT"
  done
  log "--- last daemon writes ---"
  tail -8 $TD/.write-ledger 2>/dev/null | sed 's/^/    /' >> "$OUT"
  log "--- charge state right now ---"
  log "    stop=$(cat /sys/devices/platform/google,charger/charge_stop_level 2>/dev/null) cfg=$(sed -n 's/^capacity=//p' $D/config.txt)"
  log "    level=$(cat /sys/class/power_supply/maxfg/capacity 2>/dev/null)$(cat /sys/class/power_supply/battery/capacity 2>/dev/null) kernel=$(cat /sys/class/power_supply/battery/status 2>/dev/null)"
}

last=$(wc -l < "$F" 2>/dev/null); case "${last:-x}" in ''|*[!0-9]*) last=0;; esac
quiet=0; i=0; stalls=0
while [ "$i" -lt "$RUNFOR" ]; do
  sleep 15; i=$((i + 15))
  now=$(wc -l < "$F" 2>/dev/null); case "${now:-x}" in ''|*[!0-9]*) now=$last;; esac
  if [ "$now" -gt "$last" ]; then
    quiet=0
  else
    quiet=$((quiet + 15))
    if [ "$quiet" -ge "$STALL" ]; then
      stalls=$((stalls + 1))
      capture
      quiet=0
    fi
  fi
  last=$now
done

log ""
log "=== done: $stalls stall(s) in ${RUNFOR}s ==="
log "$OUT"
