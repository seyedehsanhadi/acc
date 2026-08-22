#!/system/bin/sh
# t93 - a phone that lands on a bad contract must repair itself, without the user replugging.
#
# THE FIELD FAULT, Pixel 9a (tegu) on rc22, reported as "it said draining, the phone flickered, and
# it only started charging after I connected and disconnected a few times".
#
# The flight log says ACC was not the cause. chDisabledByAcc was FALSE on every record through the
# whole event, so nothing was cut; the supply itself kept collapsing, vbus 8850mV -> 25mV -> 0 ->
# 8650 -> 0 -> 5175 -> 0, with ICL flipping 500mA/1.5A/3A.
#
# ACC was the CURE, four minutes late:
#   15:35:07  plugged, chaos begins
#   15:38:30  the user's own disconnect finally sets sawUnplug
#   15:39:19  "plug: aimed for best contract, 0mV -> 8825mV"  <- worked first try
#   15:39:55  stable 8.1V/3A, charging at 4.4A
# The aim is gated on `freshPlug && sawUnplug`, and sawUnplug is set only when the daemon OBSERVES a
# real unplug. Until the user produced one by hand, the one piece of code that could ask the charger
# to try again was not permitted to run. The user was doing manually what this block exists to do.
#
# The collapse detector could not cover it: that needs input under 50mA for five consecutive passes,
# and real current flowed between the collapses here.
#
# WHAT THIS ASSERTS. The second entry exists, and - far more important - it CANNOT fire in the three
# states that look identical to a stalled supply but are not:
#   a live/sagging high-voltage contract   (.hvcontract latched)
#   ACC's own capacity pause               (chDisabledByAcc)
#   a firmware-limit phone held at its cap (_ge_pause_cap, flag false)
# Re-detection is free before a contract exists and DESTRUCTIVE afterwards - it threw a 9V contract
# down to 4860mV/400mA permanently in the curtana report - so a false positive here is worse than the
# bug being fixed.
#
# NO HARDWARE.

ID=t93
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
MF=$execDir/misc-functions.sh
[ -f "$AD" ] || { no "accd.sh not found"; fin; }
W=${TMPDIR:-/data/local/tmp}/.t93.$$
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null
[ -d "$W" ] || { no "scratch not creatable at $W - refusing to report a verdict from an unwritten tree"; fin; }

# ---- 1: the second entry exists at all -------------------------------------------------------------
grep -q '_aimStall' "$AD" \
  && ok "a stalled-supply entry to the aim exists" \
  || { no "no stalled-supply entry - a phone that lands on a bad contract still needs the user to replug"; fin; }

# ---- 2: EXECUTE THE SHIPPED BLOCK, not a copy of it ------------------------------------------------
# The first version of this section reimplemented the gate as a local stub that mirrored the shipped
# logic. Every mutant passed: mutating accd.sh could not change a copy living in the test. That is the
# same defect t89 was rewritten for - a window of context or a lookalike stub proves nothing about the
# code that ships. Lift the real block out and run IT, with only the environment faked.
_blk=$(sed 's/^[[:space:]]*#.*//' "$AD" | awk '/_aimStall=false/{f=1} f{print} f && /^      fi$/{exit}')
if [ -z "$_blk" ]; then
  no "could not extract the _aimStall block - this suite would grade nothing"
  fin
fi

T93RD=${T93RD:-/data/local/tmp/t93-readers.sh}
{ sed -n '/^_mv() {/,/^}/p' "$MF"
  sed -n '/^_ma() {/,/^}/p' "$MF"; } > "$T93RD" 2>/dev/null

_gate(){ # $1 hvaim  $2 hvcontract  $3 chDisabledByAcc  $4 ge_pause_cap  $5 present  $6 vbus  $7 count-so-far
  ( set +u
    TMPDIR=$W/t; dataDir=$W/d
    rm -rf "$TMPDIR" "$dataDir" $W/psy; mkdir -p "$TMPDIR" "$dataDir" $W/psy/usb
    [ "$1" = present ] && : > $TMPDIR/.hvaim
    [ "$2" = present ] && : > $TMPDIR/.hvcontract
    [ "${7:-0}" -gt 0 ] 2>/dev/null && echo "$7" > $TMPDIR/.hvfloor
    printf '%s' "${6}" > $W/psy/usb/voltage_now
    chDisabledByAcc=$3
    _gpcv=$4; _ge_pause_cap(){ $_gpcv; }
    # rc24 (B2) also gates the aim on being BELOW the pause and on ACC not holding a cut. An
    # unstubbed _lt_pause_cap is a command-not-found, which reads as "the aim declined" and would
    # make every case here pass for the wrong reason.
    _lt_pause_cap(){ ! $_gpcv; }
    # rc24 compares normalised millivolts, so the block calls _mv. Unstubbed it is a
    # command-not-found and every voltage test silently evaluates to false - which looks like
    # "the aim declined" for every input, including the ones that should aim.
    . "$T93RD"
    # PRESENT, not online: a collapse can take the online flag down with it, and requiring online
    # made the repair unreachable on a Mi A3 whose contract had died (present=1, online=0, icl=0,
    # vbus 5.9V) - the exact state this exists to fix.
    _prsv=$5; present(){ $_prsv; }
    cd $W/psy || exit 1
    eval "$_blk" >/dev/null 2>&1
    printf '%s' "${_aimStall:-unset}" ) 2>/dev/null
}

# the fault, reproduced: plugged, 5V floor, sustained, nothing latched -> MUST aim
[ "$(_gate absent absent false false true 5175000 9)" = true ]   && ok "(the tegu fault) sustained 5V floor with nothing latched -> the aim is permitted"   || no "the stalled-supply case does NOT reach the aim - the reported fault is not fixed"

# and it must NOT fire in any of the look-alikes
[ "$(_gate absent present false false true 5175000 9)" = false ]   && ok "a latched .hvcontract blocks it - a SAGGING 9V contract can never be re-detected away"   || no "it fires with .hvcontract latched - this re-kicks a live contract, the curtana 9V -> 4860mV fault"
[ "$(_gate absent absent true false true 5175000 9)" = false ]   && ok "ACC's own capacity pause blocks it"   || no "it fires during ACC's own pause, which produces an identical low-voltage idle line"
[ "$(_gate absent absent false true true 5175000 9)" = false ]   && ok "a firmware-limit phone held at its cap blocks it"   || no "it fires while held at the firmware limit, where chDisabledByAcc is false but nothing is wrong"
[ "$(_gate present absent false false true 5175000 9)" = false ]   && ok "the once-per-plug marker blocks a second attempt on the same plug"   || no "it can fire repeatedly on one plug - repeated re-detection is what collapses a handshake to 5V"
[ "$(_gate absent absent false false false 5175000 9)" = false ]   && ok "no cable present blocks it" || no "it fires with no cable present"

# NO LOWER BOUND, and that is deliberate. I originally required vbus > 1V, reasoning that a line with
# nothing behind it was not worth re-detecting. Replaying the Pixel 9a's own records killed that: 14
# of them read vbus=0 with present=1, and vbus=0 while the cable is in IS the collapsed state this
# repair exists for. The floor excluded its own target, and the fix would never have fired on the bug
# it was written for.
# What keeps it honest instead is `present`, the sustain requirement, and the current test in the
# latch-release path - re-detecting a genuinely dead line is harmless and happens once per plug.
[ "$(_gate absent absent false false true 900000 9)" = true ]   && ok "900mV with the cable in DOES reach the aim - a low line is a collapse, not a reason to stay put"   || no "900mV does not reach the aim; the band floor is back and it excludes the 9a's own state"
[ "$(_gate absent absent false false true 0 9)" = true ]   && ok "(14 of the 9a's records) 0mV with the cable in reaches the aim"   || no "0mV does not reach the aim - this is the exact state the 9a was stuck in"
# and the collapsed-but-live case from the A3 must still aim
[ "$(_gate absent absent false false true 5905536 9)" = true ]   && ok "(the A3 collapse) 5905mV with the cable present reaches the aim, which requiring online had blocked"   || no "the A3 collapse state does not reach the aim - the online->present fix is not effective"

# the SUSTAIN requirement: one low read must not be enough
[ "$(_gate absent absent false false true 5175000 0)" = false ]   && ok "a single floor reading does NOT aim - a negotiation in progress reads low for a few seconds"   || no "one low read reaches the aim; interrupting a live negotiation is how a good contract is lost"
# "did not aim" is either false or unset depending on where the extracted block starts, and both
# mean the same thing. Assert the meaning, not one of its two spellings.
case "$(_gate absent absent false false true 8825000 9)" in
  true) no "a won contract still reaches the aim" ;;
  *)    ok "8825mV (the contract tegu eventually won) is above the ceiling and never aims" ;;
esac
[ "$(_gate absent absent false false true '' 9)" = false ]   && ok "an unreadable vbus does not aim - absence of a reading is not evidence of a bad contract"   || no "an unreadable vbus reaches the aim"

# ---- 2b: THE LATCH RELEASE, driven by measured states --------------------------------------------
# The fix as first written would NEVER have fired on the bug it was written for. Replaying tegu's own
# flight records showed 28 of the 39 records after the plug blocked by .hvcontract: the first reading
# was 8850mV, which latches the contract, and the latch cleared only on a physical unplug. A charger
# that collapses seconds after plugging in therefore latched once and blocked the repair for the
# whole plug.
_rel=$(sed 's/^[[:space:]]*#.*//' "$AD" | awk '/if \[ -f \$TMPDIR\/.hvcontract \] && ! \$\{chDisabledByAcc/{f=1} f{print} f && /^      fi$/{exit}')
if [ -z "$_rel" ]; then
  no "no latch-release path found - a contract latched by one transient blip blocks the repair for the entire plug, which IS the reported 9a bug"
else
  ok "a latch-release path exists"
  # $1 vbus  $2 input-current -> held | released, after one pass with the counter one short
  _lost(){
    ( set +u
      TMPDIR=$W/t; dataDir=$W/d
      rm -rf "$TMPDIR" "$dataDir" $W/psy; mkdir -p "$TMPDIR" "$dataDir" $W/psy/usb
      : > $TMPDIR/.hvcontract
      echo 4 > $TMPDIR/.hvlost
      printf '%s' "$1" > $W/psy/usb/voltage_now
      printf '%s' "$2" > $W/psy/usb/input_current_now
      chDisabledByAcc=false
      _ge_pause_cap(){ false; }
      _lt_pause_cap(){ true; }
      present(){ true; }
      cd $W/psy || exit 1
      eval "$_rel" >/dev/null 2>&1
      [ -f $TMPDIR/.hvcontract ] && printf held || printf released ) 2>/dev/null
  }
  # rc24 CONTRACT POLICY. These two used to require the latch to be RELEASED, because in rc23 the
  # only way to repair a collapsed supply was to re-detect it, and re-detection needs the latch gone.
  # rc24 answers a collapse by lifting the input CURRENT limit instead, which cannot disturb the
  # voltage contract - so the repair no longer needs the latch released, and releasing it is exactly
  # what let an apsd_rerun fire at a live plug and take a Mi A3 from 9V to 4.4V.
  #
  # The 9a case these were written for is still fixed, by the lift rather than by re-detection; t91
  # asserts the lift fires on the same input. What must be true here is that the cable is the only
  # thing that clears the latch.
  [ "$(_lost 0 0)" = held ]     && ok "(the 9a state) 0mV with nothing flowing HOLDS the latch - the repair is the lift, not a re-detect"     || no "0mV released the contract latch - rc23 behaviour is back, and an apsd_rerun can now fire at a live plug"
  [ "$(_lost 5904496 5190)" = held ]     && ok "(the A3 collapse) 5904mV delivering 5190uA HOLDS the latch"     || no "a measured collapse released the latch - this is the 9V to 4.4V path"
  # THE SAG THAT MUST NEVER RELEASE - a real contract 26mV under the line, charging at 1.5A
  [ "$(_lost 5974048 1500000)" = held ]     && ok "(the measured sag) 5974mV while drawing 1.5A KEEPS the latch - voltage alone cannot tell a sag from a collapse, and this one is 26mV under the threshold"     || no "a healthy 5974mV/1.5A supply releases the latch - that re-detects a WORKING contract, the curtana 9V -> 4860mV fault"
  [ "$(_lost 8300000 2000000)" = held ]     && ok "a healthy 8300mV contract keeps the latch"     || no "a healthy high-voltage contract releases the latch"
  [ "$(_lost 5000000 '')" = held ]     && ok "an unreadable input current keeps the latch - absence of a reading is not evidence of a collapse"     || no "an unreadable input current releases the latch"
  # THE RELEASE MUST BE SUSTAINED TOO. Every case above starts one pass short of the threshold, so a
  # mutant that drops the requirement to a single pass produced identical results and scored as
  # caught. Starting from zero is the only way to see the difference: one collapsed reading must NOT
  # be enough, or a momentary dip releases the latch and re-detects on the next pass - the sag the
  # latch exists to protect.
  _lost0(){
    ( set +u
      TMPDIR=$W/t; dataDir=$W/d
      rm -rf "$TMPDIR" "$dataDir" $W/psy; mkdir -p "$TMPDIR" "$dataDir" $W/psy/usb
      : > $TMPDIR/.hvcontract
      printf '%s' "$1" > $W/psy/usb/voltage_now
      printf '%s' "$2" > $W/psy/usb/input_current_now
      chDisabledByAcc=false
      _ge_pause_cap(){ false; }
      _lt_pause_cap(){ true; }
      present(){ true; }
      cd $W/psy || exit 1
      eval "$_rel" >/dev/null 2>&1
      [ -f $TMPDIR/.hvcontract ] && printf held || printf released ) 2>/dev/null
  }
  [ "$(_lost0 0 0)" = held ]     && ok "ONE collapsed reading does not release the latch - the release is sustained, so a momentary dip cannot re-detect a live contract"     || no "a single collapsed reading releases the latch immediately; a brief dip would then re-detect a working contract"
fi

# ---- 3: the counter must RESET off the floor --------------------------------------------------------
# Without the reset the count is cumulative across a whole plug, so a phone that dips below 6V ten
# separate times during normal negotiation would eventually aim at a healthy contract.
_blk=$(sed 's/^[[:space:]]*#.*//' "$AD" | awk '/_aimStall=false/{f=1} f{print} f && /_aimStall:-false/{exit}')
printf '%s\n' "$_blk" | grep -q 'rm -f $TMPDIR/.hvfloor' \
  && ok "the floor counter is reset when the supply is off the floor, so only a SUSTAINED floor aims" \
  || no "the floor counter never resets - ten scattered dips across a plug would aim at a healthy contract"

# ---- 4: both markers are per-plug -------------------------------------------------------------------
# If they survive the cable, a phone gets one repair attempt for the rest of the boot.
_unplug=$(sed 's/^[[:space:]]*#.*//' "$AD" | awk '/if ! present 2>\/dev\/null; then/{f=1} f{print} f && /^      fi$/{exit}')
printf '%s\n' "$_unplug" | grep -q '.hvaim' \
  && ok ".hvaim is cleared on unplug, so the next plug gets its own attempt" \
  || no ".hvaim is never cleared on unplug - one repair per boot, not per plug"
printf '%s\n' "$_unplug" | grep -q '.hvfloor' \
  && ok ".hvfloor is cleared on unplug" \
  || no ".hvfloor survives the cable, so its count carries across plugs"

# ---- 5: the freshPlug arm did not lose its guards ---------------------------------------------------
# Turning one condition into an OR is the classic way a guard gets dropped from one side.
_g=$(sed 's/^[[:space:]]*#.*//' "$AD" | grep -A3 'if { { \$freshPlug')
case "$_g" in
  *hvcontract*) ok "the combined gate still requires no .hvcontract on BOTH arms" ;;
  *) no "the OR gate lost the .hvcontract guard - the freshPlug arm can now re-detect a live contract" ;;
esac
case "$_g" in
  *rekick-off*) ok "the combined gate still honours .rekick-off on BOTH arms" ;;
  *) no "the OR gate lost the .rekick-off guard - a user who disabled re-kick would still get one" ;;
esac

rm -rf "$W" 2>/dev/null
sh -n "$AD" 2>/dev/null && ok "accd.sh parses" || no "accd.sh does not parse"
fin
