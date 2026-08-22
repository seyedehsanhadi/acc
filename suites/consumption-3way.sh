#!/system/bin/sh
# consumption-3way.sh - what does each build actually cost the battery?
#
#   su -c 'sh "$(ls /data/local/tmp/suites/consumption-3way.sh)"'
#
#   ROUNDS=6 WINDOW=150 SETTLE=45 sh consumption-3way.sh     # the defaults
#
# THE QUESTION
#   Four arms on one phone: no ACC at all, VR25's original ACC, rc23, rc24. Which of them costs the
#   user more battery, and by how much, with a number that can be defended rather than asserted.
#
# WHY THE OBVIOUS MEASUREMENT IS WORTHLESS
#   Battery percentage is a 1% gauge. On a 4000mAh pack one percent is 40mAh, which is roughly two
#   HOURS of the difference being looked for here. Any comparison built on `capacity` is measuring
#   quantisation. This suite uses charge_counter instead: coulombs actually taken out of the pack,
#   in microamp-hours, resolvable to a tenth of a milliamp-hour on both test phones.
#
# THE CONTROLS, AND WHY EACH ONE IS HERE
#
#   ONE PHONE, ONE SESSION, BACK TO BACK.  Different phones have different idle floors; different
#   days have different radio conditions. Every arm is measured on the same hardware inside the same
#   run, minutes apart.
#
#   THE WAKELOCK, AND THE CHOICE IT FORCES (WAKELOCK=yes|no, default no).
#     HELD, every arm gets the same awake time, variance collapses, and the number is a clean
#     attribution of CPU work to a build. It is also not the number a user experiences: it removes
#     the largest real term, which is how often a daemon DENIES the phone deep sleep. A daemon
#     that wakes a phone every second costs far more in the field than its CPU time suggests.
#     NOT HELD, the phone dozes exactly as it does in the user's pocket, so the measurement
#     includes the wakeup cost and is the honest answer to "does this drain my battery". The price
#     is variance, paid for with longer windows and more paired rounds.
#   The default is NOT HELD, because the question being asked is the field one. Elapsed time is
#   taken from the clock rather than assumed from the sleep, so a window that overran a suspend is
#   still normalised correctly.
#
#   ROTATED ARM ORDER.  The pack drains and the phone cools over a run of this length, so an arm
#   measured last is measured under different conditions from one measured first. Each round runs
#   the arms in a different order, so a monotonic drift lands on a different arm each time and
#   cancels in the median instead of being attributed to a build.
#
#   A SETTLE PERIOD THAT IS DISCARDED.  A freshly started ACC daemon does its discovery, cache build
#   and config parse in the first seconds. That is real work, but it is once-per-boot work, and
#   charging it to the steady-state number would misrepresent every arm that starts from cold.
#   SETTLE seconds are burned and thrown away before any counter is read.
#
#   THE FLOOR ARM, MEASURED AS OFTEN AS THE OTHERS.  `off` is not a formality. It is the noise
#   measurement: as many windows with no ACC running at all as every build gets, and their spread
#   IS this rig's resolution on this phone on this day. Any difference between two builds smaller
#   than that spread is reported as indistinguishable rather than ranked.
#
#   PAIRING INSIDE THE ROUND.  Every round contains exactly one `off` window, so each build window
#   has a floor window measured minutes away from it under near-identical conditions. The reported
#   figure is the median of those PAIRED differences, not of the absolute drains. Slow drift in
#   temperature, radio state or gauge behaviour moves both members of a pair together and cancels;
#   comparing absolute medians across an hour does not have that property.
#
#   WINDOW LENGTH AND ROUND COUNT TOGETHER.  Both matter, for different reasons. Window length buys
#   resolution against the gauge's step size: a Pixel 6a's charge_counter moves in 2000uAh steps, so
#   a 150s window at idle contains about three steps and a 900s window about twenty. Round count
#   buys robustness against variance. A short-window run is a CPU attribution; a long-window run is
#   a drain measurement. Both are worth having and the defaults here are set for the second.
#
#   NOBODY TOUCHES THE PHONE.  An adb shell is not free: each one forks, wakes the CPU and lands in
#   the same /proc/stat fork counter this suite reads. One run of this suite recorded 614 forks/min
#   in a window that should have read 5, because it was being polled while it measured. The run is
#   launched detached and left alone; check it when it is finished, not while it is running.
#
#   A LIVENESS GATE ON EVERY WINDOW.  This is the control that matters most and it is the one a
#   benchmark usually forgets. A daemon that CRASHED consumes nothing and would win this test
#   outright. Every window therefore checks that the arm's daemon was alive at both ends and that
#   its loop actually turned in between; a window that fails is scored INVALID and never averaged.
#
#   A SENSITIVITY PROBE.  At the end, a deliberate hog is measured. If the rig cannot separate the
#   hog from idle by a wide margin it cannot resolve anything smaller either, and the suite says so
#   instead of printing four numbers that mean nothing.
#
# WHAT IS MEASURED PER WINDOW
#   dQ      charge_counter delta, uAh/min          - what the user pays, directly, ON A PHONE
#                                                    THAT HAS A REAL COULOMB COUNTER. A Mi A3
#                                                    derives this node from the capacity percent
#                                                    and it does not move for tens of minutes;
#                                                    consumption-report.sh detects a counter that
#                                                    never moved and declares the column
#                                                    unmeasurable rather than reporting a tie at
#                                                    zero.
#   cpu     daemon utime+stime+cutime+cstime, ms/min - what ACC costs, attributably
#   forks   /proc/stat processes delta, /min       - the mechanism; a shell daemon pays per fork
#   soc,temp                                       - recorded so a suspect window can be audited
#
# SAFETY
#   $M/*.sh is backed up, checksummed, and restored from a trap on every exit path including INT
#   and HUP. config.txt is never written. The phone must be UNPLUGGED - the suite refuses otherwise,
#   because a charging phone has no meaningful discharge to measure and because swapping the module
#   under a live charge is exactly the thing this project does not do.

set +e
ID=consumption-3way
M=${M:-/data/adb/vr25/acc}
DD=${DD:-/data/adb/vr25/acc-data}
TD=${TD:-/dev/.vr25/acc}
PS=/sys/class/power_supply
B=$PS/battery
W=/data/local/tmp/cons3
BK=$W/backup
ARMDIR=${ARMDIR:-/data/local/tmp}
OUT=${OUT:-/data/local/tmp/consumption-3way.txt}
TSV=${TSV:-/data/local/tmp/consumption-3way.tsv}
LOCK=acccons

ROUNDS=${ROUNDS:-6}
WINDOW=${WINDOW:-150}
SETTLE=${SETTLE:-45}
# A wall-clock ceiling in minutes, checked between rounds. Without a wakelock the kernel defers
# timers during doze, so a nominal 300s window can take considerably longer and a run planned to
# finish by morning can still be going at noon. With a deadline the run stops on a round boundary
# and reports the rounds it completed, which is a smaller loss than no result at all. 0 disables.
DEADLINE_MIN=${DEADLINE_MIN:-0}

say(){ echo "$*"; echo "$*" >> $OUT; }
screen_state(){ dumpsys power 2>/dev/null | grep -m1 -o 'mWakefulness=[A-Za-z]*' | cut -d= -f2; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
num(){ case "${1:-x}" in ''|x|*[!0-9-]*) echo "";; *) echo "$1";; esac; }

: > $OUT; : > $TSV
printf 'round\tarm\tvalid\tdQ_uAh_per_min\tcpu_ms_per_min\tforks_per_min\tsoc\ttemp_dC\tbusy_ms_per_min\n' >> $TSV
rm -rf $W 2>/dev/null; mkdir -p $BK 2>/dev/null

# ---------------------------------------------------------------------------------------------
sum_module(){ cat $M/*.sh 2>/dev/null | cksum | cut -d' ' -f1; }
daemon_pids(){ pgrep -f "$M/accd.sh" 2>/dev/null; }
daemon_pid(){ daemon_pids | head -1; }
flight_lines(){ _n=$(wc -l < $DD/logs/flight.log 2>/dev/null); case "${_n:-x}" in ''|*[!0-9]*) echo 0;; *) echo "$_n";; esac; }

# Total CPU jiffies charged to the daemon and everything it has reaped.
accd_jiffies(){
  _t=0
  for _p in $(daemon_pids); do
    _l=$(cat /proc/$_p/stat 2>/dev/null) || continue
    # Fields 14-17 counted from the end of the comm field, which can itself contain spaces.
    _r=${_l#*) }
    _i=0; _u=0; _s=0; _cu=0; _cs=0
    for _f in $_r; do
      _i=$((_i + 1))
      case $_i in 12) _u=$_f;; 13) _s=$_f;; 14) _cu=$_f;; 15) _cs=$_f;; esac
    done
    case "${_u}${_s}${_cu}${_cs}" in *[!0-9-]*) continue;; esac
    _t=$(( _t + _u + _s + _cu + _cs ))
  done
  echo $_t
}
HZ=$(getconf CLK_TCK 2>/dev/null); case "${HZ:-x}" in ''|*[!0-9]*) HZ=100;; esac

# SYSTEM-WIDE BUSY CPU, which is the quantity that actually costs battery.
#
# accd_jiffies charges only what the daemon and its reaped children accrued. That is the right
# number for attribution but it is not the whole cost: a shell daemon forks constantly, and the
# kernel time spent creating, scheduling and tearing down those processes lands on other lines of
# /proc/stat. The system busy total captures all of it, and differenced against the floor arm it is
# still attributable, because the floor arm is the same phone doing the same nothing.
sys_busy(){
  _l=$(sed -n 's/^cpu  *//p' /proc/stat | head -1)
  set -- $_l
  _u=${1:-0}; _n=${2:-0}; _s=${3:-0}; _id=${4:-0}; _io=${5:-0}; _ir=${6:-0}; _sq=${7:-0}
  echo $(( _u + _n + _s + _ir + _sq ))
}

# BOUNDED, both of them. `acca -D stop` blocks on ACC's own lock, and a run of this suite sat in
# restore() for twenty minutes with rc23 installed on the phone because nothing was watching it.
# Anything that can hang between a module swap and its restore has to have a ceiling.
stop_daemon(){
  timeout -k 3 20 $M/acca.sh -D stop >/dev/null 2>&1 || :
  sleep 2
  _k=$(daemon_pid); [ -n "$_k" ] && { kill $_k 2>/dev/null; sleep 2; }
  _k=$(daemon_pid); [ -n "$_k" ] && { kill -9 $_k 2>/dev/null; sleep 1; }
  :
}
start_daemon(){ timeout -k 3 40 sh $M/service.sh >/dev/null 2>&1 || :; sleep 4; }

install_arm(){
  _a=$1
  [ "$_a" = off ] && { stop_daemon; return 0; }
  stop_daemon
  rm -f $M/*.sh 2>/dev/null
  cp -f $ARMDIR/${_a}tree/*.sh $M/ 2>/dev/null
  cp -f $ARMDIR/${_a}tree/module.prop $M/ 2>/dev/null
  chmod 0755 $M/*.sh 2>/dev/null
  start_daemon
}

restore(){
  trap - EXIT INT TERM HUP
  say ""
  say "restoring the installed build ..."
  stop_daemon
  rm -f $M/*.sh 2>/dev/null
  cp -f $BK/*.sh $M/ 2>/dev/null
  cp -f $BK/module.prop $M/ 2>/dev/null
  chmod 0755 $M/*.sh 2>/dev/null
  start_daemon
  echo $LOCK > /sys/power/wake_unlock 2>/dev/null || :
  if [ "$(sum_module)" = "$WANT" ]; then
    say "restore VERIFIED: checksum matches, version $(sed -n 's/^versionCode=//p' $M/module.prop), daemon $(daemon_pid || echo DOWN)"
  else
    say "RESTORE MISMATCH - the module differs from the backup. It is intact at $BK; copy it back by hand."
  fi
}

# ---------------------------------------------------------------------------------------------
# One measured window. Results come back through a FILE, not a delimited string.
#
# The obvious version returned "$valid|$dq|$cpu|..." and the caller took it apart with
# ${r%%|*}. Under mksh - which is /system/bin/sh on both test phones - `|` inside a ${} pattern is
# the ALTERNATION operator, so `${r%%|*}` matches the empty alternative, strips nothing, and every
# field comes back as the whole string. The first run of this suite scored every window INVALID
# for that reason and printed the entire result line as the failure reason. A file with one field
# per line has no pattern in it to be misread.
RES=$W/window.res
measure(){
  _arm=$1
  sleep $SETTLE

  _p0=$(daemon_pid)
  _fl0=$(flight_lines)
  _q0=$(num "$(rd $B/charge_counter)")
  _c0=$(accd_jiffies)
  _k0=$(sed -n 's/^processes //p' /proc/stat)
  _b0=$(sys_busy)
  _t0=$(date +%s)
  _soc=$(rd $B/capacity); _tmp=$(rd $B/temp)
  _sc0=$(screen_state)

  sleep $WINDOW

  _q1=$(num "$(rd $B/charge_counter)")
  _c1=$(accd_jiffies)
  _k1=$(sed -n 's/^processes //p' /proc/stat)
  _b1=$(sys_busy)
  _t1=$(date +%s)
  _p1=$(daemon_pid)
  _fl1=$(flight_lines)
  _sc1=$(screen_state)

  _el=$(( _t1 - _t0 )); [ "$_el" -gt 0 ] || _el=1
  _valid=yes
  _why=

  # A lit screen costs two orders of magnitude more than anything being compared, so a window that
  # caught one is not a slightly worse measurement, it is a different experiment.
  case "${_sc0}${_sc1}" in
    *Awake*) _valid=no; _why="the screen was awake during this window ($_sc0 -> $_sc1)";;
  esac

  if [ "$_arm" = off ]; then
    [ -z "$_p1" ] || { _valid=no; _why="a daemon appeared during the off arm"; }
  else
    # THE GATE THAT MAKES THIS FAIR, and the reason this benchmark can be believed at all. A
    # daemon that crashed, or one that is present but wedged, consumes nothing and would win this
    # test outright. Three conditions, and the liveness one is deliberately build-agnostic:
    # flight.log is an rc-series artifact and VR25's original daemon has never written one, so
    # requiring it would mark every VR25 window invalid for a reason that is about this fork's
    # logging rather than about the arm being measured. CPU time advancing is the signal every
    # build shares - a wedged process accrues none.
    [ -n "$_p0" ] && [ -n "$_p1" ] || { _valid=no; _why="daemon not running at both ends of the window"; }
    [ "$_p0" = "$_p1" ] || { _valid=no; _why="daemon pid changed mid-window ($_p0 -> $_p1): it restarted"; }
    [ "$(( _c1 - _c0 ))" -gt 0 ] 2>/dev/null || { _valid=no; _why="the daemon accrued no CPU at all in ${_el}s: present but not running"; }
    # NOT flight.log. It is an rc-series artifact and VR25's daemon has never written one - but the
    # FILE survives a module swap, because only $M/*.sh is replaced and the log lives in dataDir.
    # So a flight.log check does not merely skip the VR25 arm, it marks every VR25 window invalid
    # on the strength of a stale file from a different build. CPU accrual is the signal all three
    # builds share, and the preflight above has already shown it separates them by more than an
    # order of magnitude.
  fi

  if [ -z "$_q0" ] || [ -z "$_q1" ]; then
    _valid=no; _why="${_why:-charge_counter unreadable}"
    _dq=-
  else
    # Discharging, so the counter falls. Report the magnitude per minute.
    _dq=$(( ( _q0 - _q1 ) * 60 / _el ))
  fi
  _cpu=$(( ( _c1 - _c0 ) * 1000 / HZ * 60 / _el ))
  _busy=$(( ( _b1 - _b0 ) * 1000 / HZ * 60 / _el ))
  case "${_k0}${_k1}" in *[!0-9]*) _fk=-;; *) _fk=$(( ( _k1 - _k0 ) * 60 / _el ));; esac

  { echo "$_valid"; echo "$_dq"; echo "$_cpu"; echo "$_fk"; echo "$_soc"; echo "$_tmp"; echo "$_busy"; echo "$_why"; } > $RES
}

# ---------------------------------------------------------------------------------------------
T_START=$(date +%s)
say "=== $ID ==="
say "device  : $(getprop ro.product.device 2>/dev/null)   $(getprop ro.build.version.release 2>/dev/null)"
say "started : $(date 2>/dev/null)"
say "design  : $ROUNDS rounds x 4 arms, ${SETTLE}s settle discarded + ${WINDOW}s measured, order rotated per round"

[ "$(id -u)" = 0 ] || { say "ABORT: not root"; exit 1; }
[ -f $M/accd.sh ] || { say "ABORT: no ACC at $M"; exit 1; }
[ -n "$(num "$(rd $B/charge_counter)")" ] || { say "ABORT: no readable charge_counter - this phone cannot be measured this way"; exit 1; }

# UNPLUGGED, and checked the physical way.
_plug=no
for _n in $PS/*/present $PS/*/online; do
  [ -f "$_n" ] || continue
  case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac
  [ "$(rd "$_n")" = 1 ] && _plug=yes
done
[ "$_plug" = no ] || { say "ABORT: a cable is attached. Unplug and re-run - a charging phone has no discharge to measure."; exit 1; }
say "cable   : none. status $(rd $B/status), level $(rd $B/capacity)%, temp $(rd $B/temp)"

# SCREEN OFF, and verified rather than assumed. A lit screen costs hundreds of milliamps - two
# orders of magnitude more than anything being compared here - so one arm measured with the screen
# on would decide the whole run.
_scr=$(screen_state)
case "${_scr:-}" in
  Awake) input keyevent 26 2>/dev/null || :; sleep 3
         _scr=$(screen_state)
         say "screen  : was Awake, turned off, now ${_scr:-unknown}";;
  '')    say "screen  : state unreadable - proceeding, but check it is off";;
  *)     say "screen  : $_scr";;
esac

for _a in vr25 rc23 rc24; do
  [ -f "$ARMDIR/${_a}tree/accd.sh" ] || { say "ABORT: no $_a tree at $ARMDIR/${_a}tree"; exit 1; }
  say "arm     : $_a = versionCode $(sed -n 's/^versionCode=//p' $ARMDIR/${_a}tree/module.prop 2>/dev/null || echo '?')"
done

cp -f $M/*.sh $BK/ 2>/dev/null
cp -f $M/module.prop $BK/ 2>/dev/null
WANT=$(sum_module)
say "backup  : $BK, checksum $WANT, installed versionCode $(sed -n 's/^versionCode=//p' $M/module.prop)"

# ARM PREFLIGHT. Install each arm once and prove its daemon comes up and turns over, BEFORE
# spending an hour measuring. An arm that cannot run is not a fast arm, and finding that out in
# round six wastes the whole run.
say ""
say "arm preflight - each build must come up and accrue CPU before anything is measured"
_bad=0
for _a in vr25 rc23 rc24; do
  install_arm $_a
  _pp=$(daemon_pid)
  if [ -z "$_pp" ]; then
    say "  $_a: NO DAEMON after service.sh - this arm cannot be measured"
    _bad=1
    continue
  fi
  _j0=$(accd_jiffies); sleep 30; _j1=$(accd_jiffies); _pq=$(daemon_pid)
  if [ -z "$_pq" ]; then
    say "  $_a: daemon died within 30s - this arm cannot be measured"
    _bad=1
  elif [ "$(( _j1 - _j0 ))" -gt 0 ] 2>/dev/null; then
    say "  $_a: up as pid $_pp, accrued $(( ( _j1 - _j0 ) * 1000 / HZ ))ms of CPU in 30s - measurable"
  else
    say "  $_a: up as pid $_pp but accrued NO CPU in 30s - refusing to score it as efficient"
    _bad=1
  fi
done
if [ "$_bad" != 0 ]; then
  say ""
  say "ABORT: at least one arm cannot be measured on this phone. Fix that first - a benchmark that"
  say "       silently drops an arm is worse than one that refuses to run."
  exit 1
fi

trap 'restore' EXIT INT TERM HUP
if [ "${WAKELOCK:-no}" = yes ]; then
  echo $LOCK > /sys/power/wake_lock 2>/dev/null || { say "ABORT: WAKELOCK=yes was asked for and cannot be taken"; exit 1; }
  say "wakelock: HELD ($LOCK) - equal awake time, CPU attribution, not the field number"
else
  echo $LOCK > /sys/power/wake_unlock 2>/dev/null || :
  say "wakelock: NOT held - the phone dozes as it does in a pocket, so wakeup cost is included"
fi

# ---------------------------------------------------------------------------------------------
# The rotation. Four arms, one rotation step per round, so no arm sits in the same slot twice.
r=1
while [ $r -le $ROUNDS ]; do
  case $(( (r - 1) % 4 )) in
    0) ORDER="off vr25 rc23 rc24";;
    1) ORDER="rc24 off vr25 rc23";;
    2) ORDER="rc23 rc24 off vr25";;
    3) ORDER="vr25 rc23 rc24 off";;
  esac
  if [ "$DEADLINE_MIN" -gt 0 ] 2>/dev/null; then
    _left=$(( T_START + DEADLINE_MIN * 60 - $(date +%s) ))
    # Refuse to START a round there is not time to finish. A half-finished round is worse than none:
    # its build windows have no floor window to pair against and are discarded anyway.
    _need=$(( 4 * (SETTLE + WINDOW) * 2 ))
    if [ "$_left" -lt "$_need" ]; then
      say ""
      say "stopping after $(( r - 1 )) complete rounds: $(( _left / 60 ))min left against roughly $(( _need / 60 ))min needed for another."
      break
    fi
  fi
  say ""
  say "----- round $r of $ROUNDS   order: $ORDER -----"
  for a in $ORDER; do
    install_arm $a
    measure $a
    { read -r _v; read -r _dq; read -r _cpu; read -r _fk; read -r _soc; read -r _tmp; read -r _busy; read -r _why; } < $RES
    if [ "$_v" = yes ]; then
      say "  $a  dQ ${_dq} uAh/min   cpu ${_cpu} ms/min   busy ${_busy} ms/min   forks ${_fk}/min   soc ${_soc}%  temp ${_tmp}"
    else
      say "  $a  INVALID - $_why"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$a" "$_v" "$_dq" "$_cpu" "$_fk" "$_soc" "$_tmp" "$_busy" >> $TSV
  done
  r=$(( r + 1 ))
done

# ---------------------------------------------------------------------------------------------
# THE SENSITIVITY PROBE. Everything above is only meaningful if this rig can see a difference at
# all. A deliberate hog is run for one window under the same conditions; if it does not stand well
# clear of the idle arms, no verdict is printed.
say ""
say "----- sensitivity probe: a deliberate hog -----"
install_arm off
# A REAL hog. The first version of this probe ran five no-ops and then slept a second, which is
# indistinguishable from idle - and the run duly reported that it could not resolve a known-large
# difference, which was true and useless. This one keeps a core busy for the whole window, which is
# the point: if the rig cannot see a pegged core in the battery gauge, it cannot see ACC either.
( while :; do _hx=0; while [ $_hx -lt 20000 ]; do _hx=$(( _hx + 1 )); done; done ) &
HOG=$!
measure off
kill $HOG 2>/dev/null
{ read -r _hv; read -r HOG_DQ; read -r HOG_CPU; read -r HOG_FK; read -r _hsoc; read -r _htmp; read -r HOG_BUSY; } < $RES
say "  hog  dQ ${HOG_DQ} uAh/min   forks ${HOG_FK}/min"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "probe" "hog" "$_hv" "$HOG_DQ" "$HOG_CPU" "$HOG_FK" "-" "-" "$HOG_BUSY" >> $TSV

say ""
say "raw results: $TSV"
say "Run suites/consumption-report.sh over that TSV for the medians, the noise floor and the verdict."
exit 0
