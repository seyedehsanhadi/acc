#!/system/bin/sh
# t112 - does the re-kick DECISION do the right thing, scenario by scenario?
#
# t111 proves the gate's individual conditions. This asks a different question, the one that actually
# matters in the field: given a plug that behaves like a REAL charger over time, does ACC decide to
# re-detect at the right moments and refuse at all the others - and does it decide the SAME WAY every
# time, or does the answer wander?
#
# HOW IT WORKS. Each scenario is a time series of (bus voltage, input current, charger type, cable).
# Every step is fed through the SHIPPED code: accd.sh's own latch/peak block updates .hvcontract and
# .hvpeak exactly as the daemon would, then misc-functions.sh's _hv_may_kick is asked for a verdict.
# Nothing about the decision is re-implemented here; both blocks are cut out of the installed files
# at run time, so a change to either one changes this test's answers.
#
# WHAT IT ASSERTS. Two directions, because only proving the refusals would be worthless:
#   MUST-KICK   states where a repair is the correct action, and a build that refuses is broken
#   MUST-HOLD   states where a repair would destroy a working contract
# Every scenario also runs REPEATS times and fails if the verdicts are not byte-identical across
# runs - a decision that is right on average and wrong sometimes is not a decision.
#
# NO HARDWARE. Fabricated nodes under /data/local/tmp. The daemon is untouched.

ID=t112
E=${execDir:-/data/adb/vr25/acc}
W=/data/local/tmp/t112
REPEATS=${REPEATS:-5}
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }

rm -rf $W 2>/dev/null; mkdir -p $W/ps/usb $W/ps/main 2>/dev/null

# ---- cut the two decision sites out of the shipped files ---------------------------------------
sed -n '/^_mv() {/,/^}/p;/^_ma() {/,/^}/p;/^_iin_ma() {/,/^}/p;/^_hv_may_kick() {/,/^}/p' \
  $E/misc-functions.sh > $W/gate.sh
sed -n '/Normalise FIRST, store mV/,/^             done ;;/p' $E/accd.sh \
  | sed 's/ ;;$//' > $W/latch.sh
grep -q '_hv_may_kick()' $W/gate.sh || { echo "$ID: could not extract the gate - no verdict"; exit 1; }
grep -q 'hvLatchMv' $W/latch.sh    || { echo "$ID: could not extract the latch block - no verdict"; exit 1; }

# ---- the replay engine --------------------------------------------------------------------------
# step <vbus_uv> <iin_ua> <type> <present> -> prints KICK or HOLD after updating the real markers
cat > $W/step.sh <<'XEOF'
TMPDIR=$W
dataDir=$W
: ${hvLatchMv:=6500}; : ${hvPeakMaxMv:=5500}; : ${hvDeadMa:=50}
cd $W/ps || exit 1
present(){ [ "$(cat $W/ps/.present)" = 1 ]; }
. $W/gate.sh
_hvv=$(cat $W/ps/usb/voltage_now 2>/dev/null)
if present; then
  . $W/latch.sh
else
  rm -f $TMPDIR/.hvcontract $TMPDIR/.hvpeak $TMPDIR/.hvkicked $TMPDIR/.hvrecover 2>/dev/null
fi
if _hv_may_kick; then echo KICK; else echo HOLD; fi
XEOF

step(){ # $1 vbus_uv  $2 iin_ua  $3 type  $4 present
  echo "$1" > $W/ps/usb/voltage_now
  echo "$2" > $W/ps/usb/input_current_now
  echo "$3" > $W/ps/usb/real_type
  echo "$4" > $W/ps/.present
  W=$W /system/bin/sh $W/step.sh 2>/dev/null | tail -1
}

reset_plug(){ rm -f $W/.hvcontract $W/.hvpeak $W/.hvkicked $W/.hvrecover 2>/dev/null; }

# scenario <name> <expected-sequence> <steps...>  where each step is "uv:ua:type:present"
scenario(){
  _name=$1; _want=$2; shift 2
  _first=
  _r=1
  while [ $_r -le $REPEATS ]; do
    reset_plug
    _got=
    for _s in "$@"; do
      _uv=${_s%%:*}; _rest=${_s#*:}
      _ua=${_rest%%:*}; _rest=${_rest#*:}
      _ty=${_rest%%:*}; _pr=${_rest#*:}
      _v=$(step "$_uv" "$_ua" "$_ty" "$_pr")
      _got="$_got${_v:0:1}"
    done
    [ -z "$_first" ] && _first=$_got
    if [ "$_got" != "$_first" ]; then
      no "$_name is NOT deterministic: run 1 gave $_first, run $_r gave $_got"
      return
    fi
    _r=$(( _r + 1 ))
  done
  if [ "$_got" = "$_want" ]; then
    ok "$_name  [$_got]"
  else
    no "$_name  got [$_got] want [$_want]"
  fi
}

echo "== each scenario replayed $REPEATS times; K=would re-detect, H=holds off"

# -------------------------------------------------------------------------------------------------
echo
echo "-- MUST HOLD: a contract exists or the supply is alive"
# The A3's own recorded plug: 5.1V on insertion, negotiating up to 7.9V over ~12s, then steady.
# Once it clears 6500mV the latch is set and NOTHING may re-detect it for the rest of the plug.
scenario "A3 QC3 negotiation 5.1V -> 7.9V, then steady" "HHHHHH" \
  "5143000:200000:Unknown:1" "6120000:1500000:Unknown:1" "7183000:2300000:Unknown:1" \
  "7917000:2900000:Unknown:1" "7911000:2860000:Unknown:1" "7915000:2870000:Unknown:1"

# THE OUTAGE. A won 7.9V contract that then collapses to 4.7V while the cable stays in. rc23 cleared
# the latch after five such passes and let the next call fire an APSD, which renegotiated the supply
# down and stranded it. rc24 must hold, every single pass.
scenario "won 7.9V then collapses to 4.7V, cable in (the 4.4V outage)" "HHHHHHHH" \
  "7917000:2900000:Unknown:1" "7900000:2880000:Unknown:1" \
  "4700000:150000:Unknown:1" "4700000:120000:Unknown:1" "4700000:90000:Unknown:1" \
  "4700000:40000:Unknown:1" "4700000:10000:Unknown:1" "4700000:0:Unknown:1"

# A labelled HVDCP sitting in a low-voltage phase with current flowing: working, not dead.
scenario "HVDCP_3 label at 4.8V delivering 1.2A" "HHH" \
  "4800000:1200000:HVDCP_3:1" "4850000:1250000:HVDCP_3:1" "4820000:1180000:HVDCP_3:1"

# A healthy 5V charger. Never latched, but alive, so there is nothing to repair.
scenario "plain 5V SDP delivering 1.7A" "HHH" \
  "4625000:1700000:SDP:1" "4630000:1690000:SDP:1" "4625000:1710000:SDP:1"

# A PD phone at 9V: latched by voltage AND by type.
scenario "9V PD steady" "HHH" \
  "9000000:2200000:PD:1" "8975000:2250000:PD:1" "9000000:2280000:PD:1"

# -------------------------------------------------------------------------------------------------
echo
echo "-- MUST KICK: nothing has been won and the supply is delivering nothing"
# The one state a re-detection is for: a 5V port that never negotiated and is now dead.
scenario "5V SDP that goes dead (never negotiated)" "HHK" \
  "4200000:1700000:SDP:1" "4200000:900000:SDP:1" "4200000:0:SDP:1"

# Dead from the moment it was plugged in - a bad cable or a sleeping port.
scenario "dead-on-arrival 5V port" "K" "4200000:0:SDP:1"

# Right at the edges the gate is built on.
scenario "peak 5.49V and dead -> repairable" "K" "5490000:0:SDP:1"
scenario "peak 5.51V and dead -> already negotiating, hold" "H" "5510000:0:SDP:1"
scenario "dead at exactly 50mA -> repairable" "K" "4200000:50000:SDP:1"
scenario "51mA is not dead" "H" "4200000:51000:SDP:1"

# -------------------------------------------------------------------------------------------------
echo
echo "-- ONCE PER PLUG, AND THE CABLE IS THE RESET"
# A dead port must be repaired once and then left alone, however long it stays dead.
scenario "dead 5V port stays dead: one kick, then silence" "KHHHH" \
  "4200000:0:SDP:1" "4200000:0:SDP:1" "4200000:0:SDP:1" "4200000:0:SDP:1" "4200000:0:SDP:1"

# Unplugging clears everything, so the next cable event gets its own single repair.
scenario "unplug and replug earns a fresh repair" "KHHHK" \
  "4200000:0:SDP:1" "4200000:0:SDP:1" "4200000:0:SDP:1" "0:0:Unknown:0" "4200000:0:SDP:1"

# And a plug that WON a contract cannot be repaired even after it dies - by design: re-detecting it
# is what destroys the contract. Only a real unplug reopens the question.
scenario "a won contract that dies stays un-kicked until unplug" "HHHHHK" \
  "7917000:2900000:Unknown:1" "4700000:0:Unknown:1" "4700000:0:Unknown:1" "4700000:0:Unknown:1" \
  "0:0:Unknown:0" "4200000:0:SDP:1"

echo
echo "$ID: $P passed, $F failed"
rm -rf $W 2>/dev/null
[ "$F" -eq 0 ] && exit 0 || exit 1
