#!/system/bin/sh
# t66 - idle_discharging: the charge-direction arbiter, EXECUTED.
#
# WHY THIS FILE EXISTS
#   idle_discharging decides whether the phone is charging. Everything else in ACC is downstream of
#   that one answer, and rc22 changed it in four ways after both test phones reported "Charging"
#   with nothing plugged in - for OPPOSITE current-sign reasons on the same day.
#
#   The coverage gate called it covered. It was not: the name appeared only inside comments. The
#   rc21->rc22 audit put it on the high-risk uncovered list.
#
#   Each driver below runs the real function from the installed build against a controlled set of
#   readings and checks the verdict it reaches. _status is a GLOBAL, so it survives back to the
#   driver and can be read directly.
#
# NO HARDWARE. Nothing is written to sysfs; every input is a stub or a file in a scratch directory.

ID=t66
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
BI=$execDir/batt-interface.sh
AWKF=$execDir/suites/xf.awk
[ -f "$BI" ] || { no "batt-interface.sh not found"; fin; }
[ -f "$AWKF" ] || { no "xf.awk not found at $AWKF"; fin; }

W=${TMPDIR:-/data/local/tmp}/t66-$$
rm -rf "$W"; mkdir -p "$W" 2>/dev/null
xf(){ awk -v fn="$1" -f "$AWKF" "$BI"; }
[ -n "$(xf idle_discharging)" ] || { no "could not extract idle_discharging"; rm -rf "$W"; fin; }

# Each driver gets its OWN directory. .cc_then and .dpol_flips carry over between runs otherwise, and
# a stale coulomb stamp silently changes the answer of the next test.
drive(){ # $1 dir  $2 curNow  $3 _DPOL  $4 _kstatus  $5 cc_now  $6 present-rc(0=cable in)  $7 prev cc
  D=$W/$1; rm -rf $D; mkdir -p $D
  # $6 INSIDE a function body is that FUNCTION's sixth argument, not drive's. Written as
  # `present(){ return $6; }` the stub returned 0 every time - "cable attached" - so both gate
  # assertions passed vacuously against a build where the gate works. Bind the values first.
  _cc=$5; _pr=$6; _ccprev=${7:-$5}
  ( TMPDIR=$D
    eval "$(xf idle_discharging)"
    cc_now(){ echo "$_cc"; }
    present(){ return $_pr; }
    eq(){ return 1; }
    curNow=$2; idleThreshold=50000; curThen=null; _DPOL=$3; _kstatus=$4; _status=
    # A coulomb stamp aged into the 3-90s window, so the counter block is live rather than skipped
    # for being too fresh or too stale.
    # THE STAMP IS "counter timestamp", IN THAT ORDER. idle_discharging reads it as
    # `read -r _ccp _ccts` and the writer emits `echo "$_cc $_ccnow"`. This driver wrote the two the
    # other way round, so _ccts came back as a counter reading (500000) and the freshness test
    # `_ccnow - _ccts <= 90` compared against a 1970s timestamp -- about 1.79e9 seconds, never in
    # window. The coulomb block was therefore SKIPPED in every case in this file, and the two
    # assertions that exist to exercise it -- 1 (a flat counter must not rule) and 4 (the physical
    # gate outranks a counter-proved Charging) -- were green because the arbiter never ran at all.
    if [ "$5" != 0 ]; then printf '%s %s\n' "$_ccprev" "$(( $(date +%s) - 10 ))" > $D/.cc_then; fi
    idle_discharging >/dev/null 2>&1
    echo "$_status" ) 2>/dev/null
}

# ---- 1: a flat coulomb counter must not rule -----------------------------------------------------------
# rc21 set _ccd unconditionally from the raw delta, so a counter that had not moved (delta 0) counted
# as a verdict and parked the answer on the wrong side. rc22 sets _ccd only when the counter really
# moved (>=150uAh either way) and keeps the raw figure separately.
_s=$(drive f1 -2410000 - Charging 500000 0)
[ "$_s" = Charging ] \
  && ok "a flat coulomb counter does not rule; the kernel status decides (got Charging)" \
  || no "a flat coulomb counter still rules the verdict - got '${_s}', rc21's answer (Discharging)"

# ---- 2: the sign-vs-kernel tie-break --------------------------------------------------------------------
# The field report: battery/status said Charging, current_now read -2410000, and acc -i reported
# Discharging. rc22 overrides a Discharging sign verdict when the kernel says Charging and the
# coulomb arbiter could not rule. cc_now=0 skips the counter block entirely.
_s=$(drive f2 -2410000 + Charging 0 0)
[ "$_s" = Charging ] \
  && ok "the kernel's own Charging status breaks a tie the current sign got wrong" \
  || no "the sign verdict still wins over the kernel status - got '${_s}', the shipped field bug"

# ---- 3: no cable means not charging, whatever the readings say -------------------------------------------
# The Pixel 6a signature: draining while reading NEGATIVE with a cached + polarity, so the sign arm
# concludes Charging. present() is the physical last word. Gated on present, not online: an
# input-cut switch zeroes online while the cable is still attached.
_s=$(drive f3 -2410000 + Discharging 0 1)
[ "$_s" = Discharging ] \
  && ok "a Charging verdict is overruled when no cable is present" \
  || no "ACC reports '${_s}' with nothing plugged in - the present() gate is gone (rc21 behaviour)"

# ---- 4: the gate is LAST, so it also overrides the counter ------------------------------------------------
# Distinct from 3 and worth its own row: moving the gate earlier passes 3 and fails this.
_s=$(drive f4 2410000 + Charging 500000 1 300000)
[ "$_s" = Discharging ] \
  && ok "the physical gate runs after the coulomb arbiter, so even a counter-proved Charging is overruled" \
  || no "got '${_s}' with no cable while the counter said charging - the gate is not the last word"

# ---- 5: the gate does not fire when the cable IS attached ---------------------------------------------------
# The control. Without it, a gate that returned Discharging unconditionally would pass 3 and 4.
_s=$(drive f5 2410000 + Charging 0 0)
[ "$_s" = Charging ] \
  && ok "with a cable attached the gate stays out of the way (control)" \
  || no "got '${_s}' with a cable attached and every reading saying charging - the gate fires unconditionally"

# ---- 6: the coulomb block RUNS, and this file can now prove it --------------------------------------------
# The control for the stamp order. Same inputs as case 2, whose sign+kernel path answers Charging,
# but with a counter that FELL 200000 uAh inside the window. With the block skipped this reads
# Charging and is indistinguishable from 2; only a live arbiter can turn it over.
_s=$(drive f6 -2410000 + Charging 300000 0 500000)
[ "$_s" = Discharging ] \
  && ok "a falling coulomb counter overrules the sign and the kernel status" \
  || no "got '${_s}' with the counter down 200000 uAh - the coulomb block is not executing"

# ...and the same window rising, which nothing else here covers. _DPOL=- so the SIGN path answers
# Discharging on this negative reading and the kernel agrees: only a rising counter can turn it
# over. Written with _DPOL=+ the sign path already said Charging and the case passed with the
# arbiter dead, which is the whole failure this file just came back from.
_s=$(drive f7 -2410000 - Discharging 500000 0 300000)
[ "$_s" = Charging ] \
  && ok "a rising coulomb counter overrules a Discharging sign" \
  || no "got '${_s}' with the counter up 200000 uAh - the coulomb block is not executing"

# ---- 8: THE FAIRPHONE 5 SHAPE, end to end ------------------------------------------------------
# 2026-09-09 field bundle. Everything this function can lean on was gone at once:
#   _DPOL   never learned  -- no .dpol, no .dpol_flips anywhere in /dev/.vr25/acc
#   curThen still "null"   -- it is written only by a switch-flip test (misc-functions.sh:1620),
#                             and that phone had never run one, so the sign branch was skipped
#   _kstatus Charging      -- with the pack at -1329669 uA and the SoC walking 23 -> 21%
# cc_now was the last arbiter standing and it returned 0 for the whole 78576s boot, so the verdict
# fell to the status node and ACC called a drain "Charging" -- which is what put "Slow charge" on
# a dashboard next to a falling percentage.
#
# With cc_now reading the uevent the counter rules again. This case is the regression: same three
# failures, a live counter, and the answer has to be Discharging.
_s=$(drive f8 -1329669 - Charging 700000 0 749841)
[ "$_s" = Discharging ] \
  && ok "FP5 shape: no polarity, no prior sample, lying kernel status - the counter still rules" \
  || no "got '${_s}' - a 49841 uAh drop could not overturn a lying Charging (the shipped field bug)"

# ...and the control: identical, except the counter is DEAD, which is the phone as it shipped.
_s=$(drive f9 -1329669 - Charging 0 0)
[ "$_s" = Charging ] \
  && ok "FP5 shape with the counter dead: the lying status stands (what the bundle recorded)" \
  || no "got '${_s}' - expected the field build's own wrong answer, so this file is not modelling it"

rm -rf "$W" 2>/dev/null
fin
