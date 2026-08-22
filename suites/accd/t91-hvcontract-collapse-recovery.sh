#!/system/bin/sh
# t91 - a COLLAPSED input contract must be recoverable without unplugging; a SAGGING one must not be
# touched.
#
# THE FAULT, measured twice on a Mi A3 and it invalidated two whole plugged rounds:
#   usb present=1  online=1  ceiling=1400000uA
#   usb input_current_now = 5353          <- 5.35 mA actually flowing
#   pack +516968uA                        <- running off its own battery, plugged in
# The same phone on the same cable pulled 2.5-3.0 A minutes earlier, and 2.89 A again the moment a
# restore wrote the ceilings back by hand. So the supply was not dead; ACC simply had no path back.
#
# WHY THERE IS NO PATH BACK. $TMPDIR/.hvcontract is set the first time a >=6V reading is seen while
# plugged, and cleared ONLY on `! present` - a real cable removal. rekick_usb returns at its very
# first line while that marker exists, which puts the ICL-restore below it out of reach for the whole
# plug. Every QC/HVDCP phone is latched from its first loop.
#
# THE LATCH IS NOT THE BUG AND MUST NOT BE REMOVED. It exists because a high-voltage supply SAGS UNDER
# LOAD: a QC3 contract measured 6433-6712mV on this very phone while delivering ~2A. An instantaneous
# voltage check let a re-kick through on one unlucky sample and the contract dropped to 4860mV/400mA
# permanently. The latch is what stops that.
#
# WHAT SEPARATES THEM IS CURRENT, NOT VOLTAGE. A sagging contract is still delivering amps. A collapsed
# one delivers nothing while still claiming present=1 and online=1. So: allow exactly ONE recovery per
# plug, and only after the input has been near zero for several CONSECUTIVE passes - a condition a sag
# under load can never satisfy, because a sag is caused by current being drawn.
#
# NO HARDWARE.

ID=t91
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
MF=$execDir/misc-functions.sh
[ -f "$AD" ] && [ -f "$MF" ] || { no "sources not found"; fin; }

# ---- 1..6: EXECUTE the discriminator ---------------------------------------------------------------
# collapsed(): is this a dead contract rather than a sag? $1 present $2 online $3 input_current_uA
# $4 pack_current_uA $5 polarity. Threshold 50 mA: far above sensor noise, far below anything a
# working supply delivers.
_collapsed(){
  ( _pr=$1; _on=$2; _in=$3; _pk=$4; _pol=$5
    [ "$_pr" = 1 ] || { echo no; exit; }
    [ "$_on" = 1 ] || { echo no; exit; }
    _ia=${_in#-}
    [ "${_ia:-0}" -lt 50000 ] 2>/dev/null || { echo no; exit; }
    # and the pack must NOT be taking charge - if it is, whatever the input node says, this works
    case "$_pol" in
      neg) case "$_pk" in -*) echo no;; *) echo yes;; esac ;;
      *)   case "$_pk" in -*) echo yes;; *) echo no;; esac ;;
    esac )
}
[ "$(_collapsed 1 1 5353 516968 neg)" = yes ] \
  && ok "(rule) THE MEASURED FAULT: 5.35mA in, pack discharging, present+online -> collapsed" \
  || no "(rule) the measured collapse was not recognised"
[ "$(_collapsed 1 1 1935335 -2008363 neg)" = no ] \
  && ok "(rule) 1.9A in with the pack taking 2.0A -> healthy, never touched" \
  || no "(rule) a healthy contract was called collapsed"
[ "$(_collapsed 1 1 2000000 -2000000 neg)" = no ] \
  && ok "(rule) a SAG under load still delivers amps -> not collapsed, which is what the latch protects" \
  || no "(rule) a sagging-but-working contract would be re-kicked - this is the bug the latch exists for"
[ "$(_collapsed 0 0 0 500000 neg)" = no ] \
  && ok "(rule) unplugged is not a collapse" \
  || no "(rule) unplugged treated as a collapse"
[ "$(_collapsed 1 0 0 500000 neg)" = no ] \
  && ok "(rule) present but offline is the switch's own cut, not a collapse" \
  || no "(rule) an input-cut switch would be mistaken for a collapse"
[ "$(_collapsed 1 1 30000 2500000 pos)" = no ] \
  && ok "(rule) positive-sign phone charging hard -> not collapsed even with a low input reading" \
  || no "(rule) polarity ignored - a charging Pixel would be called collapsed"
[ "$(_collapsed 1 1 30000 -2500000 neg)" = no ] \
  && ok "(rule) inverted-sign phone charging hard -> not collapsed either; the pack decides, not the input node" \
  || no "(rule) a charging Mi A3 would be called collapsed"

# ---- 7..N: LIFT THE SHIPPED BLOCK AND RUN IT ------------------------------------------------------
# Presence greps are what made the first version of this suite inert: deleting the ENTIRE detector
# still scored 11/11, because the strings it grepped for also live in the unplug cleanup. So extract
# the real condition and drive it, the way t75 does for t74.
# End on the OUTER fi (8 spaces), not the inner one (10). Ending at the inner fi truncates the block
# so the eval below cannot parse it - and every executed case then fails, including against a correct
# build, which looks like a caught mutation and is actually a broken harness.
# The shipped current readers, so the harness measures what the daemon measures.
T91W=${T91W:-/data/local/tmp/t91}
rm -rf "$T91W" 2>/dev/null; mkdir -p "$T91W" 2>/dev/null
RD=$T91W/readers.sh
{ sed -n '/^_ma() {/,/^}/p' "$MF"
  sed -n '/^_iin_scale() {/,/^}/p' "$MF"
  sed -n '/^_iin_ma() {/,/^}/p' "$MF"; } > "$RD" 2>/dev/null
_blk=$(sed -n '/! -f \$TMPDIR\/\.hvrecover/,/^        fi$/p' "$AD")
if [ -z "$_blk" ]; then
  no "could not lift the collapse detector out of accd.sh - this suite would otherwise pass on prose"
else
  ok "lifted the shipped detector block ($(printf '%s
' "$_blk" | grep -c .) lines)"

  # Drive it with stubs. Everything the block reads is injected; nothing is reimplemented.
  _drive(){ # $1 chDisabledByAcc  $2 ge_pause_cap(0=true)  $3 online(0=true)  $4 input_uA  $5 startCount
    ( set +u
      W=${TMPDIR:-/data/local/tmp}/t91box; rm -rf $W; mkdir -p $W || exit 1
      TMPDIR=$W
      mkdir -p $W/usb
      # A real plug delivers amps before it collapses, and that high reading is what proves the node
      # is microamps. Without it the reader cannot classify a small value and correctly declines to
      # call the supply dead - so the fixture must charge first, exactly as the hardware does.
      printf '%s
' 2696040 > $W/usb/input_current_now
      printf '%s' "$4" > $W/usb/input_current_now.pending
      cd $W
      # BIND BEFORE DEFINING. Inside a stub, $2 is the STUB's second argument, not _drive's - so
      # `_ge_pause_cap(){ return $2; }` returned 0 (true) every time, the guard failed, and the block
      # under test never executed. t70's harness carries a comment about this exact trap.
      chDisabledByAcc=$1
      _gp=$2; _on=$3
      _ge_pause_cap(){ return $_gp; }
      online(){ return $_on; }
      _wlog(){ :; }
      # rc24 reads the input through _iin_ma and repairs through _hv_lift. Neither existed when this
      # harness was written, and an undefined _iin_ma returns nothing - so the detector never ran and
      # EVERY executed case below passed vacuously, including the ones asserting it must not trip.
      # Source the real readers rather than reimplementing them, and record the lift.
      . "$RD"
      _hv_lift(){ echo lift >> "$T91W/.lifted"; return 0; }
      cd $W && _iin_ma >/dev/null 2>&1 || :
      cp -f $W/usb/input_current_now.pending $W/usb/input_current_now 2>/dev/null
      [ "$5" -gt 0 ] 2>/dev/null && echo "$5" > $W/.hvzero
      : > $W/.hvcontract
      eval "$_blk"
      printf 'hvcontract=%s hvrecover=%s zero=%s'         "$([ -f $W/.hvcontract ] && echo yes || echo no)"         "$([ -f $W/.hvrecover ] && echo yes || echo no)"         "$(cat $W/.hvzero 2>/dev/null || echo -)" ) 2>/dev/null
  }

  # a real collapse, already 4 passes deep -> the 5th trips it and the latch is RELEASED
  # rc24 CONTRACT POLICY: a collapse is repaired by LIFTING the input current limit, never by
  # releasing the voltage contract. Clearing .hvcontract here is what let the next call fire an
  # apsd_rerun at a live plug and renegotiate 9V down to 4.4V - the outage rc24 exists to end. So the
  # latch must still be there afterwards, .hvrecover marks the plug as repaired once, and the lift
  # must have actually fired.
  rm -f "$T91W/.lifted" 2>/dev/null
  _r=$(_drive false 1 0 5353 4)
  case "$_r" in
    *hvcontract=yes*hvrecover=yes*) ok "collapse on the 5th pass HOLDS the latch and marks the plug: $_r" ;;
    *hvcontract=no*) no "the 5th collapse pass RELEASED the contract latch - rc23 behaviour is back: $_r" ;;
    *) no "the 5th consecutive collapse pass did not mark the plug: $_r" ;;
  esac
  [ -s "$T91W/.lifted" ]     && ok "and the input current limit was lifted, which is the repair"     || no "no lift was attempted, so a collapsed input is detected and then left collapsed"

  # the SAME reading one pass earlier must NOT trip it - the consecutive requirement is the whole point
  _r=$(_drive false 1 0 5353 1)
  case "$_r" in
    *hvcontract=yes*hvrecover=no*) ok "one pass short of the budget changes nothing: $_r" ;;
    *) no "released the latch before the consecutive requirement was met: $_r" ;;
  esac

  # ACC's OWN pause has the identical electrical signature and must be ignored
  _r=$(_drive true 1 0 5353 4)
  case "$_r" in
    *hvcontract=yes*hvrecover=no*) ok "ACC's own pause is not mistaken for a collapse: $_r" ;;
    *) no "ACC's own capacity pause cleared .hvcontract - that re-opens the 9V->5V re-kick the latch prevents: $_r" ;;
  esac

  # held at or above the pause level: the firmware zeroes the input, not a dead supply
  _r=$(_drive false 0 0 5353 4)
  case "$_r" in
    *hvcontract=yes*hvrecover=no*) ok "held at the limit is not a collapse: $_r" ;;
    *) no "a phone held at its limit was treated as a collapsed contract: $_r" ;;
  esac

  # a healthy supply must reset the run rather than accumulate toward a false trip
  _r=$(_drive false 1 0 1935335 4)
  case "$_r" in
    *hvcontract=yes*zero=-*) ok "a healthy input resets the consecutive counter: $_r" ;;
    *) no "a healthy input did not reset the counter, so a run could accumulate across good passes: $_r" ;;
  esac

  # offline is the switch's own cut
  _r=$(_drive false 1 1 5353 4)
  case "$_r" in
    *hvcontract=yes*) ok "offline is not a collapse: $_r" ;;
    *) no "an offline port was treated as a collapse: $_r" ;;
  esac
fi

# ---- the latch itself must survive -------------------------------------------------------------------
grep -q 'TMPDIR/.hvcontract' "$MF"   && ok "rekick_usb still refuses on a latched contract - the sag protection is intact"   || no "the .hvcontract gate is gone from rekick_usb - that reopens the contract-killing re-kick"

sh -n "$AD" 2>/dev/null && ok "accd.sh parses" || no "accd.sh does not parse"
fin
