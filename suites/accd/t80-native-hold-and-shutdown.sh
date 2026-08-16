#!/system/bin/sh
# t80 - the firmware-limit path must take the long standby hold, and must honour shutdown_capacity.
#
# TWO MORE OF THE SAME BUG. The $nativeLimit branch `continue`s before the bottom of the loop, so
# everything that lives down there has never run on a Pixel. That structure has now produced five
# separate user-visible faults: allowIdleAbovePcap (fixed rc21), idleApps (rc22c), the deep idle nap
# (rc23b), and these two.
#
# 1. STANDBY HOLD. _nap_hold exists because plugged-and-paused is the overnight-on-charger state:
#    nothing is actionable until the pack drifts down to resume (about 1%/hour) or the cable moves,
#    yet the loop kept its 9s cadence all night. rc19 fixed that - for the switch path only.
#    Measured on rc23, both phones plugged and holding at their limit, 150s windows:
#        Mi A3    (switch path, reaches _nap_hold)     3 passes
#        Pixel 6a (firmware path, never reached it)   17 passes
#    Roughly ten times the wakeups, all night, to watch a level that moves 1% an hour.
#
# 2. LOW-BATTERY SHUTDOWN. The auto-shutdown block sits at the bottom of the loop too, so
#    shutdown_capacity is accepted by AccA, written to config, echoed back by acc -sp, and silently
#    ignored on every firmware-limit phone. Both test phones ran the same config overnight:
#        Mi A3    shutdown_capacity=5 -> stopped at 5%, .sd-latched written
#        Pixel 6a shutdown_capacity=5 -> ran to 1%, 81 samples under 6%, no latch ever created
#    A user setting 5% to protect the pack from deep discharge gets Android's own ~1% cutoff.
#
#    The code documents the intent ("Low-battery shutdown + thermal are handled by the firmware/OS
#    in this mode"), but the thermal half of that claim was already wrong and rc23 fixed it - which
#    is what t74/t75 pin. This fixes the other half.
#
# THE SHUTDOWN PATH IS THE ONE PLACE A WRONG MOVE POWERS OFF SOMEONE'S PHONE, so the guards get
# tested harder than the trigger: the once-per-episode latch, the disabled setting, and the
# above-threshold re-arm all have their own case here.
#
# NO HARDWARE. Both functions are extracted and executed against stubs.

ID=t80
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "accd.sh not found"; fin; }
_src=$(sed 's/^[[:space:]]*#.*//' "$AD")

# ================= PART 1: the standby hold =========================================================
_FN=$(sed -n '/^  _nap_native() {/,/^  }/p' "$AD")
[ -n "$_FN" ] || { no "could not extract _nap_native()"; fin; }

_hold(){ # $1 present-rc  $2 _gt_resume_cap-rc  $3 minCapMax-present(y/n)
  ( eval "$_FN"
    eval "present(){ return $1; }"
    eval "_gt_resume_cap(){ return $2; }"
    _le_shutdown_cap(){ return 1; }
    capacity=5; loopDelay=9; idleDelay=120
    TMPDIR=$(mktemp -d 2>/dev/null || echo /data/local/tmp/t80.$$)
    mkdir -p $TMPDIR 2>/dev/null
    [ "$3" = y ] && : > $TMPDIR/.minCapMax
    _nap_idle(){ echo DEEP; }
    _nap_hold(){ echo "HOLD:${1:-}"; }
    _nap(){ echo "SHORT:${1:-}"; }
    _nap_native ) 2>/dev/null
}

# plugged, holding ABOVE the resume level, nothing pending -> the long hold
case "$(_hold 0 0 n)" in
  HOLD*) ok "plugged and above resume takes the long standby hold" ;;
  *)     no "plugged and above resume gives [$(_hold 0 0 n)] - a Pixel polls all night on the charger (the shipped bug)" ;;
esac
# plugged but already down at resume -> short cadence, resume timing must not be blunted
case "$(_hold 0 1 n)" in
  SHORT*) ok "plugged and at/below resume keeps the short cadence" ;;
  *)      no "at the resume level the nap is [$(_hold 0 1 n)] - resume would be delayed" ;;
esac
# the min-capacity marker means something IS pending -> no long hold
case "$(_hold 0 0 y)" in
  SHORT*) ok ".minCapMax pending keeps the short cadence" ;;
  *)      no "with .minCapMax set the nap is [$(_hold 0 0 y)]" ;;
esac
# unplugged still takes the deep idle nap (rc23b, must not regress)
case "$(_hold 1 0 n)" in
  DEEP*) ok "unplugged still takes the deep idle nap" ;;
  *)     no "unplugged nap regressed to [$(_hold 1 0 n)]" ;;
esac

# rc23c: the hold is gated on .minCapMax being ABSENT, and that marker is touched once at daemon
# start and removed at the BOTTOM of the loop - which this branch never reaches. Without a clear of
# its own, the marker survived from boot and the hold above could never fire on any firmware-limit
# phone. Measured: 16 SHORT, 0 HOLD, even with an 8-point hysteresis. So the function must clear it.
printf '%s' "$_FN" | grep -q 'rm .*\.minCapMax' \
  && ok "_nap_native clears .minCapMax, so the hold is reachable after the first pass" \
  || no "_nap_native never clears .minCapMax - it persists from boot and the hold branch is dead code"
# and it must clear AFTER the nap, or the very first pass would take the long hold instead of the
# short cadence the generic path uses. Compare CODE line numbers: the comments in this function
# discuss both _nap_hold and .minCapMax by name, so a plain grep matches prose and orders it wrongly.
_fnc=$(printf '%s' "$_FN" | sed 's/^[[:space:]]*#.*//')
_lh=$(printf '%s' "$_fnc" | grep -n '_nap_hold 30' | head -1 | cut -d: -f1)
_lr=$(printf '%s' "$_fnc" | grep -n 'rm .*minCapMax' | head -1 | cut -d: -f1)
if [ -n "${_lh:-}" ] && [ -n "${_lr:-}" ]; then
  [ "$_lr" -gt "$_lh" ] 2>/dev/null \
    && ok "the clear (line $_lr) is ordered after the nap decision (line $_lh)" \
    || no "the clear (line $_lr) comes before the nap (line $_lh) - the first pass would hold instead of polling"
else
  no "could not locate both _nap_hold and the .minCapMax clear in the function"
fi

# ================= PART 2: low-battery shutdown =====================================================
_SD=$(sed -n '/^  auto_shutdown() {/,/^  }/p' "$AD")
if [ -z "$_SD" ]; then
  no "auto_shutdown() does not exist - the shutdown check is still inline at the bottom of the loop, so the firmware-limit path can never reach it (the shipped bug)"
else
  ok "auto_shutdown() is a function, so both paths can call it"
  # both call sites guard with `|| :` (set -e: a function returns its last command's status), so
  # match the guarded form too rather than only a bare call
  _n=$(printf '%s' "$_src" | grep -cE '^ *auto_shutdown( \|\| :)?$') || _n=0
  case "${_n:-0}" in ''|*[!0-9]*) _n=0;; esac
  [ "${_n:-0}" -ge 2 ] 2>/dev/null \
    && ok "it is called from ${_n} places (firmware path and switch path)" \
    || no "only ${_n} call site - one of the two paths still cannot reach the shutdown check"

  _sd(){ # $1 _le_shutdown_cap-rc  $2 latched(y/n)  $3 capacity0  $4 discharging-rc
    ( eval "$_SD"
      eval "_le_shutdown_cap(){ return $1; }"
      eval "not_charging(){ return $4; }"
      _uptime(){ return 0; }
      batt_cap(){ echo 4; }
      notif(){ return 0; }
      shutdownWarnings=false
      isAccd=false
      eval "set -A capacity $3 101 70 74" 2>/dev/null || capacity=$3
      dataDir=$(mktemp -d 2>/dev/null || echo /data/local/tmp/t80sd.$$)
      mkdir -p $dataDir 2>/dev/null
      [ "$2" = y ] && : > $dataDir/.sd-latched
      loopDelay=0
      shutdown(){ echo SHUTDOWN; }
      sleep(){ :; }
      auto_shutdown
      [ -f $dataDir/.sd-latched ] && echo LATCHED || echo NOLATCH ) 2>/dev/null
  }

  case "$(_sd 0 n 5 0)" in
    *SHUTDOWN*) ok "at or below shutdown_capacity, undischarged latch: it shuts down" ;;
    *)          no "at shutdown_capacity it did NOT shut down: [$(_sd 0 n 5 0)]" ;;
  esac
  case "$(_sd 0 y 5 0)" in
    *SHUTDOWN*) no "it shut down again with the latch already set - a flat phone would power off every 15 minutes" ;;
    *)          ok "the once-per-episode latch stops a second shutdown" ;;
  esac
  case "$(_sd 0 n 0 0)" in
    *SHUTDOWN*) no "shutdown_capacity=0 (disabled) still powered the phone off" ;;
    *)          ok "shutdown_capacity disabled never shuts down" ;;
  esac
  case "$(_sd 1 y 5 0)" in
    *NOLATCH*) ok "back above the threshold clears the latch, so the next flat battery re-arms" ;;
    *)         no "above the threshold the latch was not cleared - the next episode would be skipped" ;;
  esac
  case "$(_sd 0 n 5 1)" in
    *SHUTDOWN*) no "it shut down while NOT discharging" ;;
    *)          ok "it never shuts down unless the phone is actually discharging" ;;
  esac
fi

# ================= PART 3: reachability from the firmware-limit branch ===============================
_start=$(printf '%s' "$_src" | grep -n '^ *if \$nativeLimit; then' | head -1 | cut -d: -f1)
if [ -z "${_start:-}" ]; then
  no "could not find the \$nativeLimit branch"
else
  _ind=$(printf '%s' "$_src" | sed -n "${_start}p" | sed 's/[^ ].*//')
  _rel=$(printf '%s' "$_src" | tail -n +$((_start + 1)) | grep -n "^${_ind}fi\$" | head -1 | cut -d: -f1)
  _end=$((_start + ${_rel:-0}))
  _blk=$(printf '%s' "$_src" | sed -n "${_start},${_end}p")
  printf '%s' "$_blk" | grep -q 'auto_shutdown' \
    && ok "the firmware-limit branch calls auto_shutdown (lines $_start-$_end)" \
    || no "the firmware-limit branch never calls auto_shutdown - shutdown_capacity stays dead on every Pixel"
fi

sh -n "$AD" 2>/dev/null && ok "accd.sh parses" || no "accd.sh does not parse"
fin
