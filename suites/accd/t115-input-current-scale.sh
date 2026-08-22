#!/system/bin/sh
# t115 - a collapsed input on a microamp phone must not read as five amps.
#
# THE DEFECT, from real readings on both test phones.
#
#   Mi A3, charging:    usb/input_current_now = 2696040     (microamps: 2.696 A)
#   Mi A3, collapsed:   usb/input_current_now = 5353        (microamps: 5.35 mA - dead)
#
# rc24 normalises with a magnitude heuristic: a reading above 20000 cannot be milliamps, because the
# bus never carries 20 A, so it must be microamps and is divided by 1000. At or below 20000 it is
# taken as already-milliamps. That is right for the charging reading and wrong for the collapsed one:
# 5353 microamps is read as 5353 MILLIAMPS, and a supply delivering five thousandths of an amp is
# classified as delivering five amps.
#
# The band it gets wrong is exactly the band that matters. On a microamp kernel any reading from
# about 51 to 20000 - that is 0.05 mA to 20 mA, the whole of "collapsed but not quite zero" - is
# reported as alive. The A3's own measured collapse sat at 5190-5353, in the middle of it. A reading
# of 0 still normalises correctly, which is why this was never caught: the fixtures used zero.
#
# WHAT IT COSTS. The collapse detector never reaches its threshold, so the input current limit is
# never lifted and a collapsed A3 input is not repaired. It does NOT cause a spurious re-detection:
# `_hv_may_kick` requires the supply to be PROVEN dead and an ambiguous reading fails closed, which
# is why this is a missed repair rather than a hazard.
#
# THE FIX UNDER TEST. Learn the scale from the node instead of guessing per reading. Any reading
# above 20000 proves the node is microamps, and that is remembered for the boot; from then on every
# reading from that node is divided, including the small ones. A phone that has never shown a high
# reading keeps today's conservative behaviour and still fails closed.
#
# NO HARDWARE. Fabricated nodes under a scratch directory.

ID=t115
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
W=${W:-/data/local/tmp/t115}
[ -f "$MF" ] || { no "misc-functions.sh not found at $MF"; fin; }
rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

# Pull the real readers out of the shipped file - nothing here is reimplemented.
{
  sed -n '/^_ma() {/,/^}/p' "$MF"
  sed -n '/^_iin_ma() {/,/^}/p' "$MF"
} > $W/readers.sh
grep -q '_iin_ma' $W/readers.sh || { no "could not extract _iin_ma"; fin; }
ok "extracted the shipped current readers ($(grep -c . $W/readers.sh) lines)"

# read <sequence of raw values> -> the mA each one reports, in order, through one TMPDIR
seq_read(){
  rm -rf $W/box 2>/dev/null; mkdir -p $W/box/usb 2>/dev/null
  {
    echo "TMPDIR=$W/box"
    cat $W/readers.sh
    echo "cd $W/box || exit 1"
    for _v in "$@"; do
      echo "printf '%s' \"\$(printf '%s' $_v > usb/input_current_now; _iin_ma || echo ERR)\"; printf ' '"
    done
  } > $W/box.sh
  /system/bin/sh $W/box.sh 2>/dev/null
}

# ---- 1: THE DEFECT. A microamp node that has shown its scale must read a small value as small. ----
_r=$(seq_read 2696040 5353)
set -- $_r
_charge=$1; _dead=$2
echo "  (microamp node: 2696040 then 5353 -> [$_r])"
[ "$_charge" = 2696 ] \
  && ok "the charging reading normalises to 2696 mA" \
  || no "the charging reading came back as '$_charge', expected 2696"
if [ "$_dead" = 5 ]; then
  ok "after the node has proven itself microamps, 5353 reads as 5 mA - a collapsed supply"
else
  no "5353 on a proven-microamp node read as '$_dead' mA - a 5mA supply is being called ${_dead}mA, so the collapse is never detected"
fi

# ---- 2: and it must therefore satisfy the dead test ------------------------------------------------
if [ "$_dead" != ERR ] && [ "${_dead:-99999}" -le 50 ] 2>/dev/null; then
  ok "the collapsed reading is at or below the 50 mA dead threshold"
else
  no "the collapsed reading ($_dead mA) is above the 50 mA threshold, so no lift is ever attempted"
fi

# ---- 3: a genuine milliamp phone must NOT be divided ------------------------------------------------
# The Pixel reports usb/current_now, and a phone whose readings never exceed 20000 has never proven
# itself microamps. Dividing there would turn 2696 mA into 2 mA and call a healthy supply dead.
_r=$(seq_read 2696 1800)
set -- $_r
echo "  (never-high node: 2696 then 1800 -> [$_r])"
if [ "$1" = 2696 ] && [ "$2" = 1800 ]; then
  ok "a node that never reads high keeps its values untouched"
else
  no "an unproven node was rescaled: got [$_r], expected [2696 1800]"
fi

# ---- 4: zero still works, in both scales -------------------------------------------------------------
_r=$(seq_read 0)
[ "$_r" = "0 " ] || [ "$(printf '%s' "$_r" | tr -d ' ')" = 0 ] \
  && ok "a zero reading is zero in either scale" \
  || no "zero came back as [$_r]"

# ---- 5: the scale must survive within the boot but be per-NODE ----------------------------------------
# Two kernels never share a process, but one kernel can expose several current nodes with different
# units. Proving one microamp must not rescale a different node.
rm -rf $W/box2 2>/dev/null; mkdir -p $W/box2/usb 2>/dev/null
{
  echo "TMPDIR=$W/box2"
  cat $W/readers.sh
  echo "cd $W/box2 || exit 1"
  echo "printf '%s' 2696040 > usb/input_current_now; _iin_ma >/dev/null"
  echo "rm -f usb/input_current_now"
  echo "printf '%s' 1800 > usb/current_now"
  echo "printf 'other=%s' \"\$(_iin_ma)\""
} > $W/box2.sh
_o=$(/system/bin/sh $W/box2.sh 2>/dev/null)
case "$_o" in
  other=1800) ok "proving one node microamps does not rescale a different node ($_o)" ;;
  *)          no "a second node was rescaled by the first node's scale: $_o" ;;
esac

# ---- 6: can this suite still fail? --------------------------------------------------------------------
# Take the learned scale away and confirm case 1 catches it - otherwise every green above could come
# from a harness that never exercised the reader.
# _ma alone IS the old rule - the per-value magnitude guess with no learned scale. Run it on its
# own (deleting lines by pattern left a half-function and the mutation silently produced nothing,
# which reads as "caught" only if you do not check what came back).
rm -rf $W/box3 2>/dev/null; mkdir -p $W/box3 2>/dev/null
{
  echo "TMPDIR=$W/box3"
  sed -n '/^_ma() {/,/^}/p' "$MF"
  echo "printf '%s' \"\$(_ma 5353)\""
} > $W/box3.sh
_m=$(/system/bin/sh $W/box3.sh 2>/dev/null)
[ "$_m" = 5353 ] \
  && ok "mutation caught: the bare magnitude rule still reports 5353, which is the defect" \
  || no "mutation NOT caught: the bare rule returned '$_m', so case 1 cannot fail"

fin
