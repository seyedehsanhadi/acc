#!/system/bin/sh
# rc24-repair-path.sh - the one path a healthy charger can never show you, exhausted in logic.
#
#   su -c 'sh /data/local/tmp/suites/rc24-repair-path.sh'
#
# WHY THIS FILE EXISTS
#   Every live plug ever tested on these two phones ended with the kick gate answering HOLD, and
#   correctly so - every supply was healthy. That proves rc24 will not renegotiate a working
#   charger. It proves nothing at all about the other direction: that a supply which really is dead
#   still gets repaired. And the physical case cannot be arranged here. An unpowered cable supplies
#   no VBUS, so `present` stays 0 and ACC is never even asked; producing `present=1` with no current
#   needs a charger that has failed, which is not something you can buy on purpose.
#
#   So the decision is exhausted in logic instead, against the INSTALLED build, driving the real
#   rekick_usb from end to end rather than just asking the gate. Every case states what it fabricates
#   and why a charger could not have produced it.
#
# WHAT "EXHAUSTED" MEANS HERE
#   _hv_may_kick permits a repair only when SIX things are simultaneously true. Section 2 starts
#   from a state where all six hold, then breaks exactly one at a time and requires the answer to
#   flip. A condition that can be broken without changing the answer is not load-bearing, and would
#   mean the gate is permitting on fewer grounds than it claims.
#
# NO HARDWARE IS TOUCHED
#   Every case runs against fabricated power-supply trees under a scratch directory with stubbed
#   present/write. The daemon is never signalled, the real TMPDIR is never written, and no charge
#   node is read for a decision. Safe plugged or unplugged.

set +e
ID=rc24-repair-path
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
info(){ echo "  ....  $*"; }
sec(){ echo; echo "===== $* ====="; }

M=${M:-/data/adb/vr25/acc}
MF=$M/misc-functions.sh
W=/data/local/tmp/rc24rep
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }

rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null
GATE=$W/gate.sh
# _rekick_due MUST be in this list. rekick_usb calls it before it ever reaches the gate, and an
# undefined function is a command-not-found, which the shipped 'if ! _rekick_due' reads as 'due
# has not passed' - so the whole function returned 1 having done nothing, in every case, and the
# suite blamed the build for its own missing extraction.
sed -n '/^_mv() {/,/^}/p;/^_ma() {/,/^}/p;/^_iin_ma() {/,/^}/p;/^_vbus_mv() {/,/^}/p;/^_rekick_due() {/,/^}/p;/^_hv_may_kick() {/,/^}/p;/^_hv_lift() {/,/^}/p;/^rekick_usb() {/,/^}/p' $MF > $GATE

echo "=== $ID ==="
echo "device : $(getprop ro.product.device)"
echo "build  : $(sed -n 's/^version=//p' $M/module.prop)  ($(sed -n 's/^versionCode=//p' $M/module.prop))"

sec "0  THE RIG"
[ "$(id -u)" = 0 ] || { no "not root"; exit 1; }
_nf=$(grep -c '^[_a-z]*() {' $GATE)
[ "${_nf:-0}" -ge 6 ] && ok "cut $_nf shipped functions out of the installed build" \
                      || { no "extracted only $_nf functions - nothing below would grade anything"; exit 1; }
grep -q '^rekick_usb() {' $GATE && ok "rekick_usb itself is present, so the whole path can be driven" \
                                || { no "could not extract rekick_usb"; exit 1; }

# ------------------------------------------------------------------------------------------------
# Build a world. Every argument names a thing a real charger controls, so a reader can see exactly
# which physical situation each case stands for.
#   mkworld <dir> <vbus_uv> <iin_ua> <type> <latched> <peak_mv> <kicked> <rekickoff>
mkworld(){
  _d=$W/$1; rm -rf $_d 2>/dev/null; mkdir -p $_d/ps/usb $_d/ps/main $_d/tmp $_d/data 2>/dev/null
  printf '%s\n' "$2" > $_d/ps/usb/voltage_now
  printf '%s\n' "$3" > $_d/ps/usb/input_current_now
  printf '%s\n' "$4" > $_d/ps/usb/real_type
  printf '%s\n' 500000 > $_d/ps/main/current_max
  printf '%s\n' 500000 > $_d/ps/usb/current_max
  : > $_d/ps/usb/apsd_rerun
  : > $_d/ps/usb/rerun_aicl
  [ "$5" = yes ] && : > $_d/tmp/.hvcontract
  [ -n "$6" ] && printf '%s\n' "$6" > $_d/tmp/.hvpeak
  [ "$7" = yes ] && : > $_d/tmp/.hvkicked
  [ "$8" = yes ] && : > $_d/data/.rekick-off
  echo "$_d"
}
# Ask only the gate.
askgate(){
  ( cd $W/$1/ps 2>/dev/null || exit 1
    TMPDIR=$W/$1/tmp dataDir=$W/$1/data
    . $GATE
    present(){ return 0; }
    _hv_may_kick && echo KICK || echo HOLD ) 2>/dev/null
}
# Drive the WHOLE of rekick_usb, then report what it did to the world.
runrekick(){
  ( cd $W/$1/ps 2>/dev/null || exit 1
    TMPDIR=$W/$1/tmp dataDir=$W/$1/data
    . $GATE
    present(){ return 0; }
    _wlog(){ :; }
    write(){ printf '%s\n' "$1" > "$2" 2>/dev/null; }
    sleep(){ :; }
    rekick_usb probe >/dev/null 2>&1
    echo "rc=$?" ) 2>/dev/null
}
verdictof(){ # <dir> -> what physically happened
  _d=$W/$1
  printf 'apsd=%s aicl=%s kicked=%s stamp=%s mainmax=%s usbmax=%s' \
    "$([ -s $_d/ps/usb/apsd_rerun ] && echo fired || echo no)" \
    "$([ -s $_d/ps/usb/rerun_aicl ] && echo fired || echo no)" \
    "$([ -f $_d/tmp/.hvkicked ] && echo yes || echo no)" \
    "$([ -f $_d/tmp/.rekick ] && echo yes || echo no)" \
    "$(rd $_d/ps/main/current_max)" "$(rd $_d/ps/usb/current_max)"
}

# ------------------------------------------------------------------------------------------------
sec "1  THE STATE A REPAIR IS FOR"
# present, no contract ever latched, a plain type, the plug never went above 5.5V, essentially no
# current crossing the port, no repair yet spent, and the user has not disabled re-kicks. That is a
# supply that is physically there and delivering nothing, which is the only thing worth repairing.
mkworld dead 5000000 0 USB_DCP no 5100 no no >/dev/null
_g=$(askgate dead)
if [ "$_g" = KICK ]; then
  ok "a present, never-negotiated, zero-current supply is PERMITTED a repair"
else
  no "the gate said $_g on a dead supply - nothing would ever repair a phone that will not charge"
fi

sec "2  EVERY CONDITION, BROKEN ONE AT A TIME"
# From that same permitting state, break exactly one thing. Each must flip the answer on its own.
# A condition that can be broken without changing the answer is not doing any work.
brk(){ # <label> <dir built by caller>
  _r=$(askgate "$2")
  [ "$_r" = HOLD ] && ok "$1 -> HOLD" || no "$1 -> $_r, but this alone should block a repair"
}
mkworld c_latch  5000000 0       USB_DCP     yes 5100 no  no >/dev/null
brk "a contract is latched this plug" c_latch
mkworld c_type   5000000 0       USB_HVDCP_3 no  5100 no  no >/dev/null
brk "the charger reports a high-voltage TYPE" c_type
mkworld c_peak   5000000 0       USB_DCP     no  9000 no  no >/dev/null
brk "this plug once reached 9000mV" c_peak
mkworld c_curr   5000000 1500000 USB_DCP     no  5100 no  no >/dev/null
brk "the supply is delivering 1.5A" c_curr
mkworld c_kicked 5000000 0       USB_DCP     no  5100 yes no >/dev/null
brk "a repair has already been spent this plug" c_kicked
mkworld c_off    5000000 0       USB_DCP     no  5100 no  yes >/dev/null
brk "the user set acc -sk off" c_off
# And absence of evidence: no readable current node at all must fail CLOSED.
mkworld c_nonode 5000000 0 USB_DCP no 5100 no no >/dev/null
rm -f $W/c_nonode/ps/usb/input_current_now
brk "there is no readable input-current node" c_nonode

sec "3  THE BOUNDARIES"
# Where an off-by-one would live. Each pair is one unit apart across the documented threshold.
mkworld b_p5499 5000000 0 USB_DCP no 5499 no no >/dev/null
[ "$(askgate b_p5499)" = KICK ] && ok "peak 5499mV is still repairable (under the 5500 bar)" \
                                || no "peak 5499mV was refused - the peak bar is off by one"
mkworld b_p5500 5000000 0 USB_DCP no 5500 no no >/dev/null
[ "$(askgate b_p5500)" = HOLD ] && ok "peak 5500mV is treated as negotiated (at the bar)" \
                                || no "peak 5500mV was permitted - the peak bar is off by one"
mkworld b_i50   5000000 50000 USB_DCP no 5100 no no >/dev/null
[ "$(askgate b_i50)" = KICK ] && ok "50mA counts as dead (at the floor)" \
                              || no "50mA was treated as alive - the dead floor is off by one"
mkworld b_i51   5000000 51000 USB_DCP no 5100 no no >/dev/null
[ "$(askgate b_i51)" = HOLD ] && ok "51mA is alive, not dead (just over the floor)" \
                              || no "51mA was treated as dead - the dead floor is off by one"

sec "4  WHAT THE REPAIR ACTUALLY DOES"
# Driving the whole of rekick_usb, not just the gate. This is the part no fixture had covered:
# what gets WRITTEN when the answer is yes.
mkworld r_dead 5000000 0 USB_DCP no 5100 no no >/dev/null
_rc=$(runrekick r_dead)
_v=$(verdictof r_dead)
info "$_rc  $_v"
case "$_v" in
  *apsd=fired*) ok "a permitted repair actually fires apsd_rerun on the port" ;;
  *) no "a permitted repair fired no apsd_rerun - the repair does nothing" ;;
esac
case "$_v" in
  *aicl=fired*) ok "and re-runs AICL after it" ;;
  *) no "rerun_aicl was not fired" ;;
esac
case "$_v" in
  *kicked=yes*) ok "the plug's single repair is marked as spent" ;;
  *) no ".hvkicked was not set - the budget is not being claimed" ;;
esac
case "$_v" in
  *stamp=yes*) ok "the rate-limit stamp is written where the repair happened" ;;
  *) no "no .rekick stamp - the rate limit would not hold" ;;
esac

sec "5  WHAT A REFUSAL DOES INSTEAD"
# The other half of the policy: when a repair is refused the stall must still be answered, by
# LIFTING the input current limit - which cannot disturb a voltage contract.
mkworld r_live 7000000 1500000 USB_HVDCP_3 yes 7200 no no >/dev/null
_rc=$(runrekick r_live)
_v=$(verdictof r_live)
info "$_rc  $_v"
case "$_v" in
  *apsd=no*) ok "a refused repair fires NO apsd_rerun on a live contract" ;;
  *) no "apsd_rerun fired against a latched 7V contract - this is the 9V to 4.4V path" ;;
esac
case "$_v" in
  *mainmax=5000000*) ok "the refusal still answered the stall by lifting main/current_max" ;;
  *) no "no lift was performed on refusal - a stalled supply gets no answer at all" ;;
esac
case "$_v" in
  *usbmax=500000*) ok "and usb/current_max was left alone (no 100mA collapse)" ;;
  *) no "usb/current_max was written during the lift" ;;
esac

sec "6  ONCE PER PLUG, ACROSS A WHOLE PLUG LIFECYCLE"
# Repair, refuse, then simulate the cable coming out - which is the ONLY thing that resets the
# budget - and repair again.
mkworld life 5000000 0 USB_DCP no 5100 no no >/dev/null
_a=$(askgate life)
_b=$(askgate life)
if [ "$_a" = KICK ] && [ "$_b" = HOLD ]; then
  ok "first ask permits, second ask on the same plug refuses"
else
  no "the budget did not hold across two asks: $_a then $_b"
fi
# The unplug branch clears these three; do exactly what it does, and nothing else.
rm -f $W/life/tmp/.hvkicked $W/life/tmp/.hvpeak $W/life/tmp/.hvcontract
printf '%s\n' 5100 > $W/life/tmp/.hvpeak
_c=$(askgate life)
[ "$_c" = KICK ] && ok "after the cable comes out and goes back in, a fresh repair is earned" \
                 || no "a new plug was refused a repair ($_c) - one failure would be permanent"

sec "7  CAN THIS SUITE STILL FAIL?"
# Every green above claims the gate refuses for a reason. Prove the graders can see a gate that
# does not, by removing the peak guard from a copy and re-running the case it exists for.
sed 's/\[ "\$_pk" -lt "\${hvPeakMaxMv:-5500}" \] 2>\/dev\/null || return 1/: peak guard removed/' $GATE > $W/mut.sh
if cmp -s $GATE $W/mut.sh; then
  sk "could not mutate the peak guard - its source shape has changed"
else
  _m=$( cd $W/c_peak/ps 2>/dev/null && TMPDIR=$W/c_peak/tmp dataDir=$W/c_peak/data /system/bin/sh -c ". $W/mut.sh; present(){ return 0; }; _hv_may_kick && echo KICK || echo HOLD" 2>/dev/null )
  [ "$_m" = KICK ] && ok "mutation caught: without the peak guard, a 9000mV plug becomes kickable again" \
                   || no "mutation NOT caught: the peak case cannot fail, so its PASS above means nothing"
fi

echo
echo "$ID: $P passed, $F failed, $S skipped"
[ "$F" -eq 0 ] && exit 0 || exit 1
