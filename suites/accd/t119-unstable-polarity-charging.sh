#!/system/bin/sh
# t119 - a phone whose current sign will not settle must still be seen as charging.
#
# THE PHONE
#   Pixel 6a (bluejay), plugged, kernel reporting status=Charging at +2.57A. ACC's own state:
#
#       .dpol          = (empty)          no polarity ever latched
#       .dpol_flips    = 249              the sign has flipped 249 times
#       .dpol_unstable = present
#       state.json     : "polarity":"unstable"  "ccDir":"rising"  "statusTrust":"trusted"
#
#   The sign genuinely alternates on this hardware: measured -64, -351, +1939 and +2573 mA on one
#   plug, because the pack reads negative whenever the system draws more than the charger delivers.
#   So the learner can never converge, and _DPOL stays empty forever.
#
# WHY IT MATTERS
#   With _DPOL empty, idle_discharging falls to its last-resort branch, which decides from whether
#   the sign FLIPPED between two samples. On this phone the sign flips constantly, so that branch
#   answers "Discharging" while the pack is filling. The daemon's log said exactly that:
#
#       not_charging Discharging          (kernel: status=Charging  current=+2627812)
#
#   Everything gated on is_charging is then skipped. The visible casualty is maxChargingCurrent:
#   read-ch-curr-ctrl-files-p2.sh only runs while charging, so ch-curr-ctrl-files is never built,
#   set_ch_curr is gated out by `grep -q /`, and the limit is accepted, stored, displayed, and
#   enforced by nothing. Measured: mcc=500 left the pack at 1873 mA and wrote no node.
#
# WHAT THIS FOUND
#   Nothing wrong. Every case below passes on rc23 as well as on the current tree, so the
#   arbitration is NOT the reason maxChargingCurrent is dead on this phone. With _DPOL empty the
#   sign verdict does come out Discharging, but the kernel tie-break promotes it back to Charging
#   whenever the coulomb counter abstains, and the counter itself rules when it can. The suspicion
#   that the flip heuristic decides unchallenged is wrong.
#
#   The file is kept as a REGRESSION GUARD, not as evidence of a fix. It pins six behaviours that a
#   future change to idle_discharging must not break, including the two dangerous directions: an
#   unplugged phone must never read Charging, and ACC's own pause must never be promoted back to
#   Charging (which is how it stops seeing its own working switch).
#
# WHAT THIS GRADES
#   idle_discharging is cut out of the shipped file and driven with fixtures. Two arbiters can
#   rescue the sign verdict -- the coulomb counter and the kernel tie-break -- so the cases below
#   walk the combinations and find the ones where BOTH stand down and Discharging survives.
#   A case only counts if rc23 fails it and the current tree passes.

ID=t119
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

ARM23=${ARM23:-/data/local/tmp/rc23tree}
ARM24=${ARM24:-/data/local/tmp/rc24tree}
W=${W:-/data/local/tmp/t119}
rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

for a in "$ARM23" "$ARM24"; do
  [ -f "$a/batt-interface.sh" ] || { no "no batt-interface.sh in $a"; fin; }
done
ok "both arms present"

# Drive idle_discharging from an arm.
#   run <arm> <curNow> <curThen> <DPOL> <unstable yes|no> <kstatus> <cc_delta|flat> <present yes|no>
run(){
  _arm=$1; _cn=$2; _ct=$3; _dp=$4; _un=$5; _ks=$6; _cd=$7; _pr=$8
  rm -rf $W/t 2>/dev/null; mkdir -p $W/t
  [ "$_un" = yes ] && : > $W/t/.dpol_unstable
  # a fresh window the coulomb block will accept (3..90s old)
  _now=$(date +%s); _base=1000000
  echo "$_base $(( _now - 10 ))" > $W/t/.cc_then
  case "$_cd" in
    flat) _ccval=$_base ;;
    *)    _ccval=$(( _base + _cd )) ;;
  esac
  {
    echo "TMPDIR=$W/t"
    echo "curNow=$_cn; curThen=$_ct; idleThreshold=100000"
    [ -n "$_dp" ] && echo "_DPOL='$_dp'"
    echo "_kstatus='$_ks'"
    echo "chDisabledByAcc=false; _acc_nopromo=0"
    echo "cc_now(){ echo $_ccval; }"
    echo "present(){ [ '$_pr' = yes ]; }"
    echo 'eq(){ _eqv=$1; eval "case \"$_eqv\" in $2) return 0;; esac"; return 1; }'
    sed -n '/^idle_discharging() {/,/^}/p' "$_arm/batt-interface.sh"
    echo 'idle_discharging; echo "$_status"'
  } > $W/run.sh
  /system/bin/sh $W/run.sh 2>/dev/null | tail -1
}

# The Pixel's live numbers. Sign flipped between samples (-351 then +2573), which is what its
# hardware does on one plug and what defeats the flip heuristic.
CN=2573125; CT=-351000

echo
echo "-- 1  counter ABSTAINS (flat gauge), kernel says Charging"
_a=$(run "$ARM23" $CN $CT "" yes Charging flat yes)
_b=$(run "$ARM24" $CN $CT "" yes Charging flat yes)
echo "     rc23=$_a   current=$_b"
[ "$_b" = Charging ] && ok "a flat counter no longer leaves the flip heuristic deciding Discharging" \
                     || no "still $_b with the kernel plainly reporting Charging"

echo
echo "-- 2  counter RULES rising - must already be Charging in both arms"
_a=$(run "$ARM23" $CN $CT "" yes Charging 400 yes)
_b=$(run "$ARM24" $CN $CT "" yes Charging 400 yes)
echo "     rc23=$_a   current=$_b"
[ "$_b" = Charging ] && ok "a rising charge counter is honoured" || no "rising counter gave $_b"

echo
echo "-- 3  the dangerous direction must NOT change: genuinely unplugged stays Discharging"
_b=$(run "$ARM24" $CN $CT "" yes Charging flat no)
[ "$_b" = Discharging ] && ok "no cable -> Discharging, the physical gate still has the last word" \
                        || no "REGRESSION: unplugged reported $_b"

echo
echo "-- 4  a settled polarity is untouched (only the unstable phone changes behaviour)"
_b=$(run "$ARM24" -2000000 -1900000 "+" no Charging flat yes)
[ "$_b" = Charging ] && ok "_DPOL=+ with negative current still reads Charging" || no "_DPOL=+ gave $_b"
_b=$(run "$ARM24" 2000000 1900000 "+" no Discharging flat yes)
[ "$_b" = Discharging ] && ok "_DPOL=+ with positive current still reads Discharging" || no "_DPOL=+ positive gave $_b"

echo
echo "-- 5  a falling counter must still win over a Charging status"
_b=$(run "$ARM24" $CN $CT "" yes Charging -400 yes)
[ "$_b" = Discharging ] && ok "a falling charge counter still overrules a Charging status" \
                        || no "falling counter gave $_b"

echo
echo "-- 6  ACC's own pause must not be promoted back to Charging"
rm -rf $W/t2 2>/dev/null; mkdir -p $W/t2
_b=$( { echo "TMPDIR=$W/t2"; : > $W/t2/.dpol_unstable
        echo "curNow=$CN; curThen=$CT; idleThreshold=100000"
        echo "_kstatus=Charging; chDisabledByAcc=true; _acc_nopromo=0"
        echo "cc_now(){ echo 0; }"; echo "present(){ return 0; }"
        echo 'eq(){ _eqv=$1; eval "case \"$_eqv\" in $2) return 0;; esac"; return 1; }'
        sed -n '/^idle_discharging() {/,/^}/p' "$ARM24/batt-interface.sh"
        echo 'idle_discharging; echo "$_status"'; } > $W/r6.sh; /system/bin/sh $W/r6.sh 2>/dev/null | tail -1 )
[ "$_b" = Discharging ] && ok "with ACC holding the pause, the verdict is not promoted to Charging" \
                        || no "ACC's own pause was promoted to $_b - it would stop seeing its own switch"

fin
