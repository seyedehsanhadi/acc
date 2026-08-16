#!/system/bin/sh
# mega2/lib.sh - shared machinery for the super mega test.
#
# Everything here exists because something in this campaign went wrong without it. The comments say
# which, because a safety net whose reason is forgotten is the next thing someone deletes.

# ---- shell traps this harness must not fall into ---------------------------------------------------
# laurus runs BSD grep 2.5.1, bluejay runs toybox 0.8.12. NEITHER implements \s \d \w \b, and toybox
# rejects a trailing backslash outright. A pattern using them matches nothing, which turns a NEGATIVE
# assertion into a guaranteed pass - two of those shipped green for an unknown number of runs.
# Rules for every assertion in this suite:
#   [[:space:]] not \s        grep -E not BRE alternation
#   ^[ ]*name() not ^  *name()  (the latter demands a leading space, misses column-0 functions)
#   never `grep -c ... || echo 0`  (emits TWO values; killed a run mid-suite while printing "0 failed")
#   no /tmp on Android

P=0; F=0; SKIP=0
FAILED_LIST=
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); FAILED_LIST="${FAILED_LIST}
    - $*"; echo "  FAIL  $*"; }
skip(){ SKIP=$((SKIP+1)); echo "  SKIP  $*"; }
note(){ echo "      $*"; }
hdr(){ echo ""; echo "===== $* ====="; }

# Count safely: grep -c prints its count AND exits 1 on zero matches.
cnt(){ _c=$(grep -c "$@" 2>/dev/null) || :; case "${_c:-0}" in ''|*[!0-9]*) _c=0;; esac; echo "$_c"; }

execDir=${execDir:-/data/adb/vr25/acc}
dataDir=${dataDir:-/data/adb/vr25/acc-data}
TD=/dev/.vr25/acc
G=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
CFG=$dataDir/config.txt
LEDGER=$TD/.write-ledger
WORK=${WORK:-/data/local/tmp/mega2}
RECOVER=$WORK/.recover

# ---- state capture and restore -----------------------------------------------------------------------
# The megatest's own crash-recovery file used to save capacity/temp/mcc but NOT the charging switch.
# A run died without its trap and left chargingSwitch=() - the phone had no charge control at all and
# nothing on disk recorded what it should have been. Save the WHOLE config; it is 500 bytes.
save_state() {
  mkdir -p $WORK 2>/dev/null

  # Captured faithfully, including an EMPTY chargingSwitch.
  #
  # An earlier version refused to save an empty switch, on the belief that it meant charge control was
  # gone. It does not: an empty switch is ACC's auto mode. accd clears it deliberately when a switch
  # stops holding (three unsolicited resumes) and re-picks one the next time a cut is needed
  # (`[ -z "${chargingSwitch[0]-}" ] && probe_due` -> disable_charging; enable_charging). Refusing to
  # capture that state meant the restore would put back a PINNED switch the user had deliberately
  # left, which is the opposite of restoring what was there.
  cp -f $CFG $RECOVER.config 2>/dev/null
  cat > $RECOVER.meta <<EOF
O_SW=$(grep -m1 '^chargingSwitch=' $CFG 2>/dev/null)
O_CAP=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
O_TEMP=$(grep -m1 '^temperature=' $CFG 2>/dev/null)
O_MCC=$(grep -m1 '^maxChargingCurrent=' $CFG 2>/dev/null)
O_DAEMON=$(daemon_alive && echo up || echo down)
EOF
  # The physical switch value too: if we latch it during a test and die, this is the only record.
  _sw=$(grep -m1 '^chargingSwitch=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//')
  set -- $_sw
  if [ -n "${1:-}" ] && [ -f "/sys/class/power_supply/$1" ]; then
    echo "O_SWNODE=/sys/class/power_supply/$1" >> $RECOVER.meta
    echo "O_SWVAL=$(cat /sys/class/power_supply/$1 2>/dev/null)" >> $RECOVER.meta
  fi
  echo "  state saved to $RECOVER.config"
}

restore_state() {
  [ -f $RECOVER.config ] || { echo "  no recovery file - nothing to restore"; return 0; }
  echo ""
  echo "  RESTORING..."
  # Restore through acc -s where possible so the daemon's in-memory copy follows; fall back to the
  # raw file. Order matters: config first, THEN release the switch, THEN the daemon.
  cp -f $RECOVER.config $CFG 2>/dev/null
  . $RECOVER.meta 2>/dev/null || :
  # Physically un-latch whatever we may have left cut. This is the one that matters: a phone left
  # with input_suspend=1 cannot charge, and rc22's enable_charging is the only thing that fixes it.
  if [ -n "${O_SWNODE:-}" ] && [ -n "${O_SWVAL:-}" ]; then
    _now=$(cat $O_SWNODE 2>/dev/null)
    if [ "${_now:-}" != "${O_SWVAL:-}" ]; then
      chmod a+w $O_SWNODE 2>/dev/null || :
      echo "$O_SWVAL" > $O_SWNODE 2>/dev/null || :
      echo "    switch node restored: $O_SWNODE = $(cat $O_SWNODE 2>/dev/null)"
    fi
  fi
  # If P3 was interrupted mid-arm, execDir holds an older build. Put the installed one back BEFORE
  # restarting, or the phone runs rc21/VR25 while module.prop claims rc22.
  if command -v restore_arms >/dev/null 2>&1; then
    restore_arms >/dev/null 2>&1
  else
    daemon_stop >/dev/null 2>&1
    daemon_start >/dev/null 2>&1
  fi
  sleep 6
  if daemon_alive; then echo "    daemon back up: $(cat $TD/acc.lock 2>/dev/null)"; else echo "    WARNING daemon did not come back"; fi
  echo "    config: $(grep -m1 '^capacity=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//')  temp: $(grep -m1 '^temperature=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//')"
  echo "    switch: $(grep -m1 '^chargingSwitch=' $CFG 2>/dev/null | cut -c1-56)"
}

# T-COST once shipped without a trap and left ACC stopped on BOTH phones. Every signal, always.
arm_trap() { trap 'restore_state; exit 130' INT TERM HUP; trap 'restore_state' EXIT; }

# ---- daemon ------------------------------------------------------------------------------------------
daemon_pid(){ cat $TD/acc.lock 2>/dev/null; }
daemon_alive(){ _p=$(daemon_pid); [ -n "${_p:-}" ] && [ -d /proc/$_p ]; }
daemon_stop(){ acc -D stop >/dev/null 2>&1 || :; sleep 3; _p=$(daemon_pid); [ -n "${_p:-}" ] && [ -d /proc/$_p ] && { kill -TERM $_p 2>/dev/null; sleep 3; }; :; }
# POLL for the daemon, do not sleep a fixed time.
#
# This slept 8 seconds and then assumed. Two P9 arms failed on that alone: after its tmpfs directory
# is wiped the daemon has to rebuild everything before taking the lock, and on a corrupt config it
# reloads from its known-good copy first. Both exceed 8s on a Mi A3 and both were reported as "the
# daemon cannot start" - a fixed sleep turns "slower than I guessed" into "broken". Retested by hand
# with 12-14s, both started fine (pids 11702 and 12952).
#
# Polling also makes every phase faster in the common case, where the daemon is up in two seconds.
daemon_start(){
  acc -D start >/dev/null 2>&1 || accd >/dev/null 2>&1 || :
  _ds=0
  while [ $_ds -lt ${DSTART_MAX:-30} ]; do
    _p=$(daemon_pid)
    [ -n "${_p:-}" ] && [ -d /proc/$_p ] && return 0
    sleep 2; _ds=$(( _ds + 2 ))
  done
  return 1
}

_cpu(){ set -- $(cat /proc/${1:-0}/stat 2>/dev/null); echo $(( ${14:-0} + ${15:-0} )); }

# THE LAW, learned by reverting a correct fix on a frozen-daemon measurement: acc.lock says "alive"
# for a daemon that is wedged. Before trusting ANY A/B, prove the process actually advanced.
daemon_looping() {  # $1 = seconds to observe, as a CEILING (default 200)
  # A FIXED SLEEP ON A CPU COUNTER IS THE WRONG SHAPE, and it produced a false failure.
  #
  # Unplugged and paused, rc19 parks the daemon in a fork-free nap; laurus measures ~146 s between
  # passes at rest. Observing cpu ticks for 15 or 20 s therefore condemns a perfectly healthy daemon
  # for doing exactly what that release was built to make it do. Seen live: "started after wipe but
  # is not looping", on a daemon that was fine.
  #
  # flight.log is the honest heartbeat -- the daemon appends a record every pass, so the file grows
  # even while it burns no measurable cpu. Poll both, return the moment either moves, and only spend
  # the full budget on a daemon that really does look stopped. Fast when healthy, patient when idle.
  _p=$(daemon_pid); [ -n "${_p:-}" ] && [ -d /proc/$_p ] || return 1
  _fl=${FLIGHT:-/data/adb/vr25/acc-data/logs/flight.log}
  _w=${1:-200}; _el=0
  _a=$(_cpu $_p); _fa=$(wc -c < "$_fl" 2>/dev/null || echo 0)
  while [ "$_el" -lt "$_w" ]; do
    sleep 5; _el=$(( _el + 5 ))
    _p2=$(daemon_pid); [ "$_p" = "${_p2:-}" ] || return 1
    _fb=$(wc -c < "$_fl" 2>/dev/null || echo 0)
    [ "${_fb:-0}" -gt "${_fa:-0}" ] 2>/dev/null && return 0
    _b=$(_cpu $_p)
    [ $(( ${_b:-0} - ${_a:-0} )) -gt 0 ] 2>/dev/null && return 0
  done
  return 1
}

# ---- hardware facts ------------------------------------------------------------------------------------
plugged(){ [ "$(cat $U/present 2>/dev/null)" = 1 ]; }
lvl(){ cat $G/capacity 2>/dev/null; }
tempc(){ echo $(( $(cat $G/temp 2>/dev/null || echo 0) / 10 )); }
cur_raw(){ cat $G/current_now 2>/dev/null; }
vbus(){ cat $U/voltage_now 2>/dev/null; }
kstat(){ cat $G/status 2>/dev/null; }
is_native(){ [ -f /sys/devices/platform/google,charger/charge_stop_level ]; }

sw_node() {
  _sw=$(grep -m1 '^chargingSwitch=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//')
  set -- $_sw
  [ -n "${1:-}" ] || return 1
  case "$1" in /*) echo "$1";; *) echo "/sys/class/power_supply/$1";; esac
}
sw_on_val(){ _sw=$(grep -m1 '^chargingSwitch=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//'); set -- $_sw; echo "${2:-}"; }
sw_off_val(){ _sw=$(grep -m1 '^chargingSwitch=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//'); set -- $_sw; echo "${3:-}"; }

# Is charging currently PERMITTED by the switch?
#
# There are two switch classes and they cannot be checked the same way. Getting this wrong reported a
# perfectly healthy Pixel as "CUT - the phone will not charge when plugged":
#
#   BINARY   battery/input_suspend 0 1     the node holds an on/off value; released == the ON value.
#   LEVEL    google,charger/charge_stop_level 100 pcap
#                                          the node holds a PERCENTAGE. Its OFF value is the literal
#                                          token `pcap`, resolved at runtime to pause_capacity, and
#                                          the node RESTS there for as long as the limit is being
#                                          enforced - which is most of the time on a firmware-limit
#                                          phone. Comparing it against the ON value (100) calls a
#                                          working limit a stranded phone, and comparing a number
#                                          against the string "pcap" could never match anything.
#
# For a level switch the real question is whether the firmware would charge, i.e. whether the stop
# level is above where the pack sits now.
sw_released() {
  _n=$(sw_node 2>/dev/null) || return 0
  [ -n "${_n:-}" ] && [ -f "$_n" ] || return 0
  _v=$(cat "$_n" 2>/dev/null)
  _on=$(sw_on_val)

  # AT OR ABOVE THE USER'S LIMIT, BEING CUT IS CORRECT - WHATEVER THE SWITCH CLASS.
  #
  # This check is shared on purpose. It was written for level switches first, after a Pixel sitting at
  # exactly 74% against a 74% limit was reported as "the phone will not charge when plugged", and then
  # the identical thing happened on a binary switch: a Mi A3 finished a soak at exactly 76% against a
  # 76% limit with input_suspend=1 and was called BLOCKED. Both were the limit doing its job. Four
  # variants of this mistake have now been made by special-casing one class at a time, so the rule
  # lives in one place ahead of any class-specific logic.
  _l=$(lvl)
  _pc=$(grep -m1 '^capacity=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//' | cut -d' ' -f4)
  case "${_pc:-x}" in ''|*[!0-9]*) _pc=;; esac
  case "${_l:-x}" in ''|*[!0-9]*) _l=;; esac
  if [ -n "${_l:-}" ] && [ -n "${_pc:-}" ]; then
    [ "$_l" -ge "$_pc" ] 2>/dev/null && return 0
  fi

  case "$(sw_off_val)" in
    pcap|*%)
      # LEVEL switch: the node holds a percentage, and the firmware charges until the pack reaches it.
      # Below the user's limit the stop level must be above the pack or nothing will charge.
      case "${_v:-x}${_l:-x}" in *[!0-9]*) return 0;; esac
      [ "${_v:-0}" -gt "${_l:-0}" ] 2>/dev/null
      ;;
    *)
      # BINARY switch: released means the node holds its resume value.
      [ "${_v:-}" = "${_on:-}" ]
      ;;
  esac
}

sw_state_desc() {
  _n=$(sw_node 2>/dev/null)
  [ -n "${_n:-}" ] && [ -f "$_n" ] || { echo "no switch node"; return; }
  case "$(sw_off_val)" in
    pcap|*%) echo "level switch $(basename $_n)=$(cat "$_n" 2>/dev/null) vs level $(lvl)%" ;;
    *) echo "binary switch $(basename $_n)=$(cat "$_n" 2>/dev/null) (resume value $(sw_on_val))" ;;
  esac
}

ledger_lines(){ [ -f $LEDGER ] && wc -l < $LEDGER 2>/dev/null || echo 0; }

# ---- STATE OF CHARGE IS A CONFOUND, NOT A DETAIL --------------------------------------------------
# A charger does not behave the same way at 30% and at 85%. Constant-current gives way to constant-
# voltage as the pack fills, current tapers, and on QC3 the negotiated voltage follows it down. So a
# run that starts near full measures the taper, not the build - and every comparison drawn from it is
# against a moving reference. Measured on a Mi A3 in one session: the supply fell 6.31V to 5.85V with
# ACC completely idle, purely because the pack was filling.
#
# Two consequences the harness must respect:
#   1. Report the SoC band a measurement was taken in, so two runs are never silently compared across
#      different regimes.
#   2. Refuse to compare at all above the taper threshold, where the charger is the dominant variable.
soc_band() {
  _l=$(lvl)
  case "${_l:-x}" in ''|*[!0-9]*) echo unknown; return;; esac
  if   [ "$_l" -lt 40 ]; then echo "low(<40)"
  elif [ "$_l" -lt 65 ]; then echo "mid(40-64)"
  elif [ "$_l" -lt 80 ]; then echo "high(65-79)"
  else echo "taper(>=80)"; fi
}

# True when the pack is far enough from full that the charger is not the dominant variable.
soc_comparable() {
  _l=$(lvl)
  case "${_l:-x}" in ''|*[!0-9]*) return 1;; esac
  [ "$_l" -lt "${SOC_MAX:-75}" ] 2>/dev/null
}

# ---- the shutdown_temp prohibition ------------------------------------------------------------------
# Standing user instruction, repeated twice: DO NOT TEST SHUTDOWN TEMP. A numeric shutdown_temp of 9
# powers the phone off at room temperature; there is no safe way to exercise it on a real device.
# This is checked mechanically rather than trusted to reviewer discipline.
assert_no_shutdown_temp_writes() {
  _hits=0
  for _f in "$1"/*.sh; do
    [ -f "$_f" ] || continue
    case "$_f" in *lib.sh) continue;; esac
    _n=$(sed 's/#.*//' "$_f" 2>/dev/null | cnt -E 'shutdown_temp=[0-9]')
    _hits=$(( _hits + _n ))
  done
  [ "${_hits:-0}" -eq 0 ] 2>/dev/null
}
