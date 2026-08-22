#!/system/bin/sh
# t81 - enable_charging must not run a switch DISCOVERY SWEEP on an unplugged phone.
#
# THE DEFECT, measured on a Mi A3 (laurus) with rc23 installed, unplugged, screen off:
#     system forks with ACC stopped :    96 per 600s
#     system forks with ACC running :  4068 per 600s
#     accd CPU                      :  5452 ticks per 600s  (~9% of one core)
#     loop passes logged            :     0
# Nearly 4000 forks and no completed pass. The daemon's own trace showed why:
#     329: flip_sw on        (misc-functions.sh, inside cycle_switches)
#     147: [ on = off ]      (batt-interface.sh, not_charging's verify loop)
#     174: sleep 1           x35
#     171: status  ->  cat battery/current_now
# In 90 seconds: flip_sw on twice, 66 sleeps, 67 status calls, 67 forks of cat. Two back-to-back
# 35-second verify loops, continuously.
#
# THE CHAIN. enable_charging ends with `flip_sw on || cycle_switches on`. flip_sw returns 2
# immediately when no switch is configured ([ -f ${1:-//} ] || return 2), so on a phone with
# chargingSwitch=() the `||` fires and runs the FULL candidate sweep - a discovery operation - as
# the resume path, with no cable attached and nothing to resume. The Pixel never sees it because it
# HAS a configured switch, which is exactly why it costs 83 forks a pass and the A3 costs 6.6 a
# second. The same empty-switch configuration is what the Pixel 6 Pro field report shipped with.
#
# THE FIX IS NARROW ON PURPOSE. Only the SWEEP is gated on present(). Releasing a latched switch
# while unplugged must still happen - that is the rc22 fix for a phone left unable to charge with
# the cable out - and it is done by the .sw restore block and by flip_sw itself, both above and both
# untouched. What is gated is only the blind candidate sweep, which cannot re-arm anything
# electrically when there is no charger to re-arm.
#
# NO HARDWARE. enable_charging's tail is executed against stubs.

ID=t81
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
[ -f "$MF" ] || { no "misc-functions.sh not found"; fin; }

# ---- 1: the sweep fallback is gated on a cable being attached ---------------------------------------
_line=$(grep -n 'flip_sw on || ' "$MF" | head -1)
if [ -z "$_line" ]; then
  no "could not find the 'flip_sw on || ...' fallback in enable_charging"
else
  echo "  (found: $_line)"
  case "$_line" in
    *present*) ok "the cycle_switches fallback is gated on present()" ;;
    *cycle_switches*|*_rearm_sweep*) no "the fallback sweeps with NO present() gate - an unplugged phone with no configured switch sweeps forever (the shipped bug)" ;;
    *) no "unrecognised fallback form: $_line" ;;
  esac
fi

# ---- 2: the latched-switch release is NOT gated -------------------------------------------------------
# rc22 fixed a phone left unable to charge because a latched switch was never released while
# unplugged. That release must still run with no cable. It lives in the .sw restore block.
_sw=$(sed -n '/^enable_charging() {/,/^}/p' "$MF" | grep -c 'flip_sw on 2>/dev/null')
case "${_sw:-0}" in ''|*[!0-9]*) _sw=0;; esac
[ "${_sw:-0}" -ge 1 ] 2>/dev/null \
  && ok "the unconditional latched-switch release is still present (${_sw} site)" \
  || no "the latched-switch release is gone - a switch cut with the cable out would never be undone"

# ---- 3: EXECUTE the tail - unplugged with no switch must NOT sweep --------------------------------------
_run(){ # $1 present-rc  $2 chargingSwitch value
  ( flip_sw(){ set -- ${chargingSwitch[@]-}; [ -f "${1:-//}" ] || return 2; echo FLIPPED; }
    cycle_switches(){ echo SWEEP; }
    # rc24 routes the fallback through _rearm_sweep, which is cycle_switches with a budget. Stub
    # BOTH names: a stub that only covers the old one makes an undefined-command failure look
    # exactly like "discovery was lost", and this suite reported precisely that against a build
    # whose discovery was intact.
    _rearm_sweep(){ echo SWEEP; }
    eval "present(){ return $1; }"
    chargingSwitch="$2"
    # the line under test, as it appears in enable_charging
    eval "$(grep 'flip_sw on || ' "$MF" | head -1 | sed 's/^ *//')" ) 2>/dev/null
}

_out=$(_run 1 "")
case "$_out" in
  *SWEEP*) no "unplugged with no switch STILL sweeps (got [$_out]) - this is the 4000-fork bug" ;;
  *)       ok "unplugged with no configured switch does not sweep (got [${_out:-nothing}])" ;;
esac

# ---- 4: plugged behaviour must be unchanged ---------------------------------------------------------------
# With a cable attached and no switch, discovery is still legitimate - do not regress it.
_out=$(_run 0 "")
case "$_out" in
  *SWEEP*) ok "plugged with no switch still sweeps - discovery is preserved" ;;
  *)       no "plugged discovery was lost (got [${_out:-nothing}]) - ACC could no longer find a switch" ;;
esac

# ---- 5: a configured switch never reaches the fallback at all ----------------------------------------------
# a REGULAR file: flip_sw tests -f, and /dev/null is a character device, so it would fail the test
# for the wrong reason
_out=$(_run 0 "$MF 0 1")
case "$_out" in
  *FLIPPED*) case "$_out" in
               *SWEEP*) no "a working flip still fell through to the sweep" ;;
               *)       ok "a configured switch flips and never sweeps" ;;
             esac ;;
  *) no "a configured switch did not flip: [$_out]" ;;
esac

# ---- 6: it still parses ---------------------------------------------------------------------------------------
sh -n "$MF" 2>/dev/null && ok "misc-functions.sh parses" || no "misc-functions.sh does not parse"

fin
