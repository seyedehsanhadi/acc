#!/system/bin/sh
# consumption-4arm.sh - what each build actually costs the battery, measured so the number can be
#                       published, argued with, and reproduced by someone else.
#
#   su -c 'ROUNDS=3 WINDOW=180 SETTLE=45 sh /data/local/tmp/suites/consumption-4arm.sh'
#
# THE FOUR ARMS
#   off    no ACC daemon at all - the floor everything else is measured against
#   vr25   VR25's original ACC (202505180)
#   rc23   the build users are running today
#   rc24   the candidate
#
# THE METRIC, AND WHY IT IS THIS ONE
#   Earlier attempts on these phones used charge_counter and produced nothing usable. It is
#   quantised at 2000uAh on a Pixel 6a, and on a Mi A3 it is derived from the capacity percentage
#   and does not move for tens of minutes - ten identical readings across 200s of confirmed
#   discharge. A metric that cannot move cannot rank anything.
#
#   battery/current_now is an instantaneous current with no such quantisation. One reading is noisy;
#   the mean of ~45 readings across a window is not. So the primary figure here is the MEAN ABSOLUTE
#   current over the window, in milliamps, and it works on both phones.
#
#   The sampler wakes at a fixed 0.2Hz and is byte-identical in every arm, so whatever it costs is
#   present in all four and cancels in the differences. That is the point of measuring the `off` arm
#   with the same sampler rather than assuming a floor.
#
# WHAT IS EXACT AND WHAT IS ESTIMATED
#   Daemon CPU time and fork counts come from /proc and are exact - they are counters, not samples.
#   The current mean is a measurement with a spread, and the spread is reported next to it. Nothing
#   here extrapolates from a synthetic load; an earlier version derived a coefficient from a pegged
#   CPU core and produced an energy figure that contradicted its own direct measurement, because a
#   pegged core sits at the top of the DVFS range and a daemon that wakes for milliseconds does not.
#
# THE CONTROLS
#   one phone, one session, arms rotated every round so drift lands on a different arm each time;
#   screens verified off per window and the window discarded if one woke; unplugged verified per
#   window; the daemon verified alive AND accruing CPU, so a crashed build cannot win by doing
#   nothing; a settle period discarded before every measurement; median across rounds, not mean.
#
# SAFETY
#   $M/*.sh is backed up and checksum-verified, and restored from a trap on every exit path. The
#   config is never written. No charge node is written. The phone must be unplugged.

set +e
ID=consumption-4arm
M=${M:-/data/adb/vr25/acc}
DD=${DD:-/data/adb/vr25/acc-data}
PS=/sys/class/power_supply
ARMDIR=${ARMDIR:-/data/local/tmp}
W=/data/local/tmp/cons4
BK=$W/backup
OUT=${OUT:-/data/local/tmp/consumption-4arm.txt}
TSV=${TSV:-/data/local/tmp/consumption-4arm.tsv}

ROUNDS=${ROUNDS:-3}
WINDOW=${WINDOW:-180}
SETTLE=${SETTLE:-45}
STEP=${STEP:-5}

say(){ echo "$*"; echo "$*" >> $OUT; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
abs(){ _a=${1#-}; case "${_a:-x}" in ''|x|*[!0-9]*) echo 0;; *) echo "$_a";; esac; }
# current_now is microamps on both test phones; anything above 20000 must be, since no pack
# sustains 20A. Below that it is already milliamps.
ma(){ _a=$(abs "$1"); [ "$_a" -gt 20000 ] 2>/dev/null && echo $(( _a / 1000 )) || echo "$_a"; }
screen_state(){ dumpsys power 2>/dev/null | awk -F= '/mWakefulness=/{gsub(/[ \t\r]/,"",$2); print $2; exit}'; }
daemon_pids(){ pgrep -f "$M/accd.sh" 2>/dev/null; }
daemon_pid(){ daemon_pids | head -1; }
present_any(){ _p=no; for _n in $PS/*/present $PS/*/online; do case "$_n" in */battery/*|*/bms/*|*/maxfg/*) continue;; esac; [ -f "$_n" ] || continue; [ "$(rd "$_n")" = 1 ] && _p=yes; done; echo $_p; }

HZ=$(getconf CLK_TCK 2>/dev/null); case "${HZ:-x}" in ''|*[!0-9]*) HZ=100;; esac
accd_jiffies(){
  _t=0
  for _p in $(daemon_pids); do
    _l=$(cat /proc/$_p/stat 2>/dev/null) || continue
    _r=${_l#*) }; _i=0; _u=0; _s=0; _cu=0; _cs=0
    for _f in $_r; do _i=$((_i+1)); case $_i in 12) _u=$_f;; 13) _s=$_f;; 14) _cu=$_f;; 15) _cs=$_f;; esac; done
    case "${_u}${_s}${_cu}${_cs}" in *[!0-9-]*) continue;; esac
    _t=$(( _t + _u + _s + _cu + _cs ))
  done
  echo $_t
}

sum_module(){ cat $M/*.sh 2>/dev/null | cksum | cut -d' ' -f1; }
stop_daemon(){
  timeout -k 3 20 $M/acca.sh -D stop >/dev/null 2>&1 || :
  sleep 2
  for _k in $(daemon_pids); do kill $_k 2>/dev/null; done; sleep 2
  for _k in $(daemon_pids); do kill -9 $_k 2>/dev/null; done; sleep 1
  :
}
start_daemon(){ timeout -k 3 40 sh $M/service.sh >/dev/null 2>&1 || :; sleep 4; }
install_arm(){
  _a=$1
  stop_daemon
  [ "$_a" = off ] && return 0
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
  if [ "$(sum_module)" = "$WANT" ]; then
    say "restore VERIFIED: checksum $WANT, versionCode $(sed -n 's/^versionCode=//p' $M/module.prop), daemon $(daemon_pid || echo DOWN)"
  else
    say "RESTORE MISMATCH - module differs from the backup, which is intact at $BK"
  fi
  say "raw: $TSV"
  exit 0
}

# ---------------------------------------------------------------------------------------------
# One measured window. Result -> $W/res  (valid, mA mean, mA spread, samples, cpu ms/min,
# forks/min, soc, temp, reason)
RES=$W/res
measure(){
  _arm=$1
  sleep $SETTLE

  _p0=$(daemon_pid); _c0=$(accd_jiffies)
  _k0=$(sed -n 's/^processes //p' /proc/stat)
  _t0=$(date +%s)
  _soc=$(rd $PS/battery/capacity); _tmp=$(rd $PS/battery/temp)
  _scr0=$(screen_state)

  _n=0; _sum=0; _lo=99999999; _hi=0; _awake=no; _plug=no
  _el=0
  while [ $_el -lt $WINDOW ]; do
    sleep $STEP
    _el=$(( $(date +%s) - _t0 ))
    _i=$(ma "$(rd $PS/battery/current_now)")
    case "${_i:-x}" in ''|x|*[!0-9]*) continue;; esac
    _n=$(( _n + 1 )); _sum=$(( _sum + _i ))
    [ "$_i" -lt "$_lo" ] 2>/dev/null && _lo=$_i
    [ "$_i" -gt "$_hi" ] 2>/dev/null && _hi=$_i
    case "$(screen_state)" in Awake) _awake=yes;; esac
    [ "$(present_any)" = yes ] && _plug=yes
  done

  _c1=$(accd_jiffies); _k1=$(sed -n 's/^processes //p' /proc/stat)
  _t1=$(date +%s); _p1=$(daemon_pid)
  _el=$(( _t1 - _t0 )); [ "$_el" -gt 0 ] || _el=1

  _valid=yes; _why=
  [ "$_n" -ge 10 ] 2>/dev/null || { _valid=no; _why="only $_n current samples"; }
  [ "$_awake" = no ] || { _valid=no; _why="the screen woke during the window"; }
  [ "$_plug" = no ] || { _valid=no; _why="a cable appeared during the window"; }
  if [ "$_arm" = off ]; then
    [ -z "$_p1" ] || { _valid=no; _why="a daemon appeared during the off arm"; }
  else
    [ -n "$_p0" ] && [ -n "$_p1" ] || { _valid=no; _why="daemon not running at both ends"; }
    [ "$_p0" = "$_p1" ] || { _valid=no; _why="daemon pid changed ($_p0 -> $_p1)"; }
    # A crashed build burns nothing and would win outright. CPU must have advanced.
    [ "$(( _c1 - _c0 ))" -gt 0 ] 2>/dev/null || { _valid=no; _why="daemon accrued no CPU at all - present but not running"; }
  fi

  _mean=0; [ "$_n" -gt 0 ] && _mean=$(( _sum / _n ))
  _spread=$(( _hi - _lo ))
  _cpu=$(( ( _c1 - _c0 ) * 1000 / HZ * 60 / _el ))
  case "${_k0}${_k1}" in *[!0-9]*) _fk=0;; *) _fk=$(( ( _k1 - _k0 ) * 60 / _el ));; esac

  { echo "$_valid"; echo "$_mean"; echo "$_spread"; echo "$_n"; echo "$_cpu"; echo "$_fk"; echo "$_soc"; echo "$_tmp"; echo "$_why"; } > $RES
}

# ---------------------------------------------------------------------------------------------
rm -rf $W 2>/dev/null; mkdir -p $BK 2>/dev/null
: > $OUT
printf 'round\tarm\tvalid\tmA_mean\tmA_spread\tsamples\tcpu_ms_per_min\tforks_per_min\tsoc\ttemp\n' > $TSV

say "=== $ID ==="
say "device : $(getprop ro.product.device)   cores=$(nproc 2>/dev/null)"
say "started: $(date 2>/dev/null)"
say "design : $ROUNDS rounds x 4 arms, ${SETTLE}s settle discarded + ${WINDOW}s measured, sampled every ${STEP}s"
say "metric : mean |battery/current_now| in mA; daemon CPU and forks from /proc (exact)"

[ "$(id -u)" = 0 ] || { say "ABORT: not root"; exit 1; }
[ "$(present_any)" = no ] || { say "ABORT: a cable is attached - this measures discharge"; exit 1; }
for _a in vr25 rc23 rc24; do
  [ -f "$ARMDIR/${_a}tree/accd.sh" ] || { say "ABORT: no $_a tree at $ARMDIR/${_a}tree"; exit 1; }
  say "arm    : $_a = versionCode $(sed -n 's/^versionCode=//p' $ARMDIR/${_a}tree/module.prop 2>/dev/null || echo '?')"
done
say "screen : $(screen_state)   cap=$(rd $PS/battery/capacity)%   temp=$(( $(rd $PS/battery/temp) / 10 ))C"

cp -f $M/*.sh $BK/ 2>/dev/null; cp -f $M/module.prop $BK/ 2>/dev/null
WANT=$(sum_module)
say "backup : $BK checksum $WANT (installed versionCode $(sed -n 's/^versionCode=//p' $M/module.prop))"
trap 'restore' EXIT INT TERM HUP

# Arms rotate every round, so a monotonic drift in temperature or state of charge lands on a
# different arm each time instead of being attributed to one build.
r=1
while [ $r -le $ROUNDS ]; do
  case $(( (r - 1) % 4 )) in
    0) ORDER="off vr25 rc23 rc24";;
    1) ORDER="rc24 off vr25 rc23";;
    2) ORDER="rc23 rc24 off vr25";;
    3) ORDER="vr25 rc23 rc24 off";;
  esac
  say ""
  say "----- round $r of $ROUNDS   order: $ORDER -----"
  for a in $ORDER; do
    install_arm $a
    measure $a
    { read -r _v; read -r _mean; read -r _sp; read -r _n; read -r _cpu; read -r _fk; read -r _soc; read -r _tmp; read -r _why; } < $RES
    if [ "$_v" = yes ]; then
      say "  $a   ${_mean}mA (spread ${_sp}, n=${_n})   cpu ${_cpu}ms/min   forks ${_fk}/min   soc ${_soc}%  ${_tmp}"
    else
      say "  $a   DISCARDED - $_why"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$a" "$_v" "$_mean" "$_sp" "$_n" "$_cpu" "$_fk" "$_soc" "$_tmp" >> $TSV
  done
  r=$(( r + 1 ))
done

restore
