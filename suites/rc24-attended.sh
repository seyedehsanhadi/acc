#!/system/bin/sh
# rc24-attended.sh - everything the unattended round cannot do, in the order that costs the
# operator the fewest cable changes.
#
#   su -c 'sh /data/local/tmp/plug/rc24-attended.sh'
#
# WHY THIS ORDER. Each of these has a precondition about the cable, and run in the wrong order they
# demand five swaps. Sorted by the state each one STARTS from, two swaps cover all five:
#
#   phase 1  UNPLUGGED   9vramp        must start unplugged, then asks for the 9V brick
#   phase 2  9V attached deep          grades a real high-voltage charge
#   phase 3  9V attached 2b            needs >62%, so it runs after the 9V charge has lifted it
#   phase 4  WEAK supply weak-supply   both want a deliberately weak source
#                        weak-supply2
#
# Every phase states what it needs and waits for the cable to actually be in that state before
# starting, rather than starting and failing on a precondition. STEP_TIMEOUT bounds each wait so a
# walked-away operator cannot hang the run.

set -u
P=${P:-/data/local/tmp/plug}
D=/data/adb/vr25/acc-data
A=/dev/.vr25/acc
PS=/sys/class/power_supply
OUT=$P/ATTENDED.log
WAIT=${STEP_TIMEOUT:-600}
SUITE_TIMEOUT=${SUITE_TIMEOUT:-1200}

# PHASES="2 3 4" re-runs only those phases. A phase that already passed should not be repeated to
# reach one that has not - 9vramp costs a full charge ramp and passed 21/0 first time.
PHASES=${PHASES:-1 2 3 4}
want(){ case " $PHASES " in *" $1 "*) return 0;; esac; return 1; }

exec > "$OUT" 2>&1
say(){ echo "$*"; }
hr(){ say ""; say "################ $* ################"; }

present(){ [ "$(cat $PS/usb/present 2>/dev/null)" = 1 ]; }
lvl(){ cat $PS/battery/capacity 2>/dev/null; }
vbus(){ cat $PS/usb/voltage_now 2>/dev/null; }
ptype(){ cat $PS/usb/real_type 2>/dev/null; }

# Restore whatever a suite left, on EVERY exit path. The plugged round learned this the hard way:
# copying the config back does not release a limit that lives in sysfs.
cp $D/config.txt $P/config.attbak 2>/dev/null || :
_restore(){
  $A/acc $D/config.txt -s mcv= >/dev/null 2>&1 || :
  $A/acc $D/config.txt -s mcc= >/dev/null 2>&1 || :
  [ -s $P/config.attbak ] && cp $P/config.attbak $D/config.txt 2>/dev/null || :
  $A/accd --init $D/config.txt >/dev/null 2>&1 || :
}
trap '_restore; exit 130' INT TERM HUP
trap _restore EXIT

await(){   # await <want-present 0|1> <label>
  _w=0
  while [ $_w -lt $WAIT ]; do
    if [ "$1" = 1 ] && present; then return 0; fi
    if [ "$1" = 0 ] && ! present; then return 0; fi
    sleep 5; _w=$((_w+5))
  done
  say "  TIMED OUT after ${WAIT}s waiting for: $2"
  return 1
}

run(){     # run <suite>
  say ""
  say "---- $1 ----"
  if [ ! -f "$P/$1" ]; then say "  not staged, skipped"; return 0; fi
  execDir=/data/adb/vr25/acc timeout "$SUITE_TIMEOUT" sh "$P/$1" > "$P/.att.$1.out" 2>&1
  [ $? = 124 ] && say "  !! TIMED OUT after ${SUITE_TIMEOUT}s"
  grep -E '^  (FAIL|SKIP)' "$P/.att.$1.out" | head -8 || :
  v=$(grep -E '^[a-zA-Z0-9_-]+: [0-9]+ passed' "$P/.att.$1.out" | tail -1)
  say "  => ${v:-(no assertion summary)}"
  _restore
}

hr "0  START"
say "started : $(date '+%Y-%m-%d %H:%M:%S')"
say "level   : $(lvl)%   present=$(cat $PS/usb/present 2>/dev/null)   type=$(ptype)"
say "config  : $(grep '^capacity=' $D/config.txt)"

if want 1; then
hr "1  UNPLUG NOW  (9vramp must start with no cable)"
say ">>> UNPLUG the phone. Waiting up to ${WAIT}s."
if await 0 "cable removed"; then
  say "  unplugged at $(lvl)%"
  say ">>> Now PLUG THE 9V QC/PD BRICK when the suite asks."
  run rc24-plugged-9vramp.sh
else
  say "  skipping 9vramp"
fi

fi

if want 2; then
hr "2  9V ATTACHED  (deep grades a real high-voltage charge)"
say ">>> Make sure the 9V brick is CONNECTED. Waiting up to ${WAIT}s."
if await 1 "9V brick connected"; then
  # A cable is not a 9V cable. This accepted any supply and graded plugged-deep against a 4.9V
  # weak charger, which is not what that suite measures. Require the vbus to actually be high.
  _mv=$(( $(vbus) / 1000 ))
  if [ "${_mv:-0}" -lt 6000 ]; then
    say "  REFUSED: vbus is ${_mv}mV, not a 9V supply. Attach the QC/PD brick and re-run PHASES=2."
    _skip2=1
  fi
  say "  plugged at $(lvl)%  vbus=$(vbus)  type=$(ptype)"
  [ "${_skip2:-0}" = 1 ] || run rc24-plugged-deep.sh
else
  say "  skipping deep"
fi

fi

if want 3; then
hr "3  LIVE IDLE-AVOIDANCE  (needs >62%)"
_l=$(lvl)
if [ "${_l:-0}" -gt 62 ] && present; then
  say "  level ${_l}% and plugged - running section 2b via the round's own IA_ONLY mode"
  IA_ONLY=1 timeout "$SUITE_TIMEOUT" sh $P/rc24-plugged-auto.sh > $P/.att.ia 2>&1
  grep -E 'IDLE-AVOIDANCE|t\+|level=|SKIP|DEFERRED' $P/.att.ia | head -20 || :
else
  say "  SKIPPED: level ${_l}%, plugged=$(cat $PS/usb/present 2>/dev/null)."
  say "  Leave it on the 9V brick until it passes 65%, then re-run this script - it will pick up here."
fi

fi

if want 4; then
hr "4  WEAK SUPPLY  (both weak-supply suites)"
say ">>> Swap to a DELIBERATELY WEAK source now (an old 5V charger, or a PC USB port)."
say ">>> Unplug first, then attach the weak one. Waiting up to ${WAIT}s for it."
# START THE SUITES WHILE UNPLUGGED. Both grade the PLUG EDGE and the per-plug markers, which only
# exist from the moment the supply appears - so they abort outright if a cable is already on. This
# waited for the cable BEFORE starting them and got "ABORT: a cable is already attached" twice.
# Phase 1 had it right: wait for unplugged, start the suite, let the suite wait for the plug.
if await 0 "cable removed"; then
  say "  unplugged at $(lvl)% - starting the suites now; PLUG THE WEAK SUPPLY when each asks"
  run rc24-weak-supply.sh
  # weak-supply2 grades the plug EDGE just as weak-supply does, and weak-supply leaves the cable
  # attached - so back to back the second one aborts on "a cable is already attached".
  say ">>> UNPLUG again now, then re-attach the weak supply when the next suite asks."
  await 0 "cable removed before the second weak-supply suite" || :
  run rc24-weak-supply2.sh
else
  say "  skipping the weak-supply pair"
fi

fi

hr "5  VERDICT"
say "config now : $(grep '^capacity=' $D/config.txt)"
say "mcc/mcv    : $(grep -E '^maxCharging' $D/config.txt | tr '\n' ' ')"
n=0
for p in $(pgrep -f accd.sh 2>/dev/null); do
  c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
  set -f; set -- $c; set +f
  case "${1:-}" in sh|*/sh|mksh|*/mksh|busybox|*/busybox) ;; *) continue;; esac
  [ "${1##*/}" = busybox ] && shift
  case "${2:-}" in */accd.sh|accd.sh) n=$((n+1));; esac
done
say "daemons    : $n   level: $(lvl)%   present=$(cat $PS/usb/present 2>/dev/null)"
say "finished   : $(date '+%Y-%m-%d %H:%M:%S')"
say "ATTENDED RUN COMPLETE"
