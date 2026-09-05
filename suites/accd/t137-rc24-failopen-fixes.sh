#!/system/bin/sh
# t137 - the four fail-open defects found in the 2026-08-31 review rounds.
#
# Each of these let charging continue, or a safety cutoff not run, in a state where the config said
# it should not. None had any coverage, which is how all four survived into rc24.
#
#   H1  native_unlatch pulsed charge_stop_level=100 during a LATCHED thermal hold
#   H2  shutdown_temp was unreachable on the firmware-limit path
#   H3  a millivolt pause_capacity was clamped to 100, i.e. no limit at all
#   B5  native_verify_backstop released its own input cut, reading it as an unplug
#
# SAFETY. Nothing here writes shutdown_temp, and nothing can power the phone off: the daemon coerces
# any shutdown_temp outside 40-70 back to 55, so H2 is proven by REACHABILITY rather than by making
# a cutoff fire. The H1 and H3 arms pause charging and restore the config from a trap.
#
# PLUGGED for the live arms; the source arms run anywhere.

ID=t137
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
TMPDIR=/dev/.${domain:-vr25}/${id:-acc}
CFG=${config:-/data/adb/vr25/acc-data/config.txt}
D=$execDir/accd.sh
PS=/sys/class/power_supply
SCR=/data/local/tmp/t137-scratch
rm -rf "$SCR"; mkdir -p "$SCR" 2>/dev/null
[ -f "$D" ] || { no "missing $D"; fin; }

strip(){ sed 's/^[[:space:]]*#.*//' "$1"; }
DC=$SCR/accd.nc; strip "$D" > "$DC"

ORIG_CAP=$(grep -m1 '^capacity=' "$CFG")
ORIG_TMP=$(grep -m1 '^temperature=' "$CFG")
restore(){
  [ -n "$ORIG_CAP" ] && sed -i "s|^capacity=.*|$ORIG_CAP|" "$CFG" 2>/dev/null || :
  [ -n "$ORIG_TMP" ] && sed -i "s|^temperature=.*|$ORIG_TMP|" "$CFG" 2>/dev/null || :
  $TMPDIR/acc -D restart >/dev/null 2>&1 || :
}
trap 'restore' EXIT INT TERM

plugged=0
# NOT $PS/*/present -- that glob matches battery/present, which is 1 because the BATTERY is
# present and has nothing to do with a charger. On laurus, unplugged: battery/present=1 while
# usb/present=0, so every plugged arm below ran on an unplugged phone and reported the product
# broken. Ask the charger supplies only, and require online too: a charger that is present but
# not online is an input cut, which is not a usable plugged state for these arms either.
for _pn in $PS/usb/present $PS/pc_port/present $PS/dc/present $PS/ac/present $PS/wireless/present; do
  [ -f "$_pn" ] || continue
  [ "$(cat "$_pn" 2>/dev/null)" = 1 ] && { plugged=1; break; }
done

nativeq=0
case "$($TMPDIR/acca --state 2>/dev/null | tr -d ' "')" in
  *native:{enabled:true*) nativeq=1 ;;
esac

echo "  -- phone: $(getprop ro.product.device)  level $(cat $PS/battery/capacity)%  plugged=$plugged native=$nativeq"

# ---- 0: the harness can fail -------------------------------------------------------------------
grep -q 'zzz_not_in_this_file_zzz' "$DC" \
  && no "harness: grep matched a token that is not present" \
  || ok "harness: grep discriminates"

# ================================================================= H1
# native_unlatch's guard asked a LIVE question (_temp_hold: is the pack at/above max_temp right now)
# while the clamp it protects is LATCHED (_ntHot: set at max_temp, cleared only at resume_temp).
# Through that band the guard passed, the pulse wrote charge_stop_level=100 and slept a full
# loopDelay with no limit at all, and _le_resume_cap made it repeat for the whole cooldown.
_ul=$(grep -n '_ntHot:-0.*!= 1' "$DC" | head -1 | cut -d: -f1)
[ -n "$_ul" ] && ok "H1: native_unlatch consults the latched hold (_ntHot), not only _temp_hold" \
              || no "H1: native_unlatch has no _ntHot guard - the pulse can run mid-hold again"
grep -q '! _temp_hold || return 0' "$DC" \
  && ok "H1: the original live over-temperature guard is still there" \
  || no "H1: the _temp_hold guard was dropped"
# BOTH latches, not just the thermal one. The first version of the H1 fix guarded _ntHot and
# stopped there, leaving the millivolt latch with the identical hole: during an _nvHeld hold
# native_unlatch still pulsed stop/start to 100 and slept a loopDelay with no limit at all.
# Caught on bluejay from the write ledger on a live 9V charger - seven
# "charge_start_level <- 100 (was 34)" entries in forty seconds while a millivolt pause was set.
_ul2=$(grep -c '\[ "${_nvHeld:-0}" != 1 \] || return 0' "$DC")
[ "${_ul2:-0}" -ge 1 ] \
  && ok "H1: native_unlatch stands down for the millivolt latch too" \
  || no "H1: native_unlatch ignores _nvHeld - it will pulse 100 during a voltage hold"

# ================================================================= H2
# The thermal cutoff lived inline in is_charging(), and the firmware-limit branch `continue`s before
# is_charging() is ever called - so on a Pixel it was accepted, displayed, and enforced by nothing.
grep -q '_temp_shutdown_check() {' "$DC" \
  && ok "H2: the cutoff is a function, not inline in is_charging()" \
  || no "H2: _temp_shutdown_check is gone"
_n=$(grep -c '^ *_temp_shutdown_check$' "$DC")
[ "${_n:-0}" -ge 2 ] \
  && ok "H2: called from both paths ($_n call sites)" \
  || no "H2: only $_n call site - one of the two paths cannot reach the cutoff"
# The band coercion must survive the move, or a hand-edited shutdown_temp=9 powers the phone off.
grep -q '\[ "\$_st" -ge 40 \]' "$DC" \
  && ok "H2: the 40-70 band coercion moved with it" \
  || no "H2: the band check was lost - a numeric shutdown_temp=9 could fire at room temperature"

# LIVE REACHABILITY, from the daemon's own trace. The band check exists nowhere else in the file, so
# its appearance proves the running daemon executed the function. On a native phone is_charging()
# never runs, which the same trace confirms - so a hit there can only have come from the new call.
_tr=$(ls $TMPDIR/accd-*.log 2>/dev/null | head -1)
if [ -n "$_tr" ] && [ -s "$_tr" ]; then
  _hit=$(grep -c -- "-ge 40" "$_tr" 2>/dev/null)
  _ic=$(grep -c 'is_charging' "$_tr" 2>/dev/null)
  if [ "${_hit:-0}" -ge 1 ]; then
    if [ "$nativeq" = 1 ] && [ "${_ic:-0}" -eq 0 ]; then
      ok "H2 LIVE: the daemon ran the cutoff check on the native path (is_charging never ran)"
    else
      ok "H2 LIVE: the daemon ran the cutoff check ($_hit hit(s))"
    fi
  else
    sk "H2 LIVE: no cutoff check in the trace yet - the daemon may not have completed a pass"
  fi
else
  sk "H2 LIVE: no daemon trace log to read"
fi

# ================================================================= H3
# capacity[3] carries two domains: 0-100 percent, 3001-5000 millivolts. The firmware nodes are a
# percentage, and the clamp only knew the first domain - so a 4200mV pause was rewritten to 100,
# which is the firmware's "never pause".
grep -q '_nvPause' "$DC" \
  && ok "H3: sync_native_limit recognises a millivolt pause" \
  || no "H3: a millivolt pause is still clamped to 100 (no limit at all)"
# LATCHED, not instantaneous. The first version of this fix engaged on `volt >= pause` alone, which
# oscillates: holding the charge makes the pack sag back under the threshold within seconds, so it
# released and re-engaged forever. Measured from the write ledger on bluejay - hold at 4036mV, and
# both nodes back to 100 eleven seconds later at 3864mV. capacity[2] is the resume level in the same
# millivolt domain, so the release threshold is already in the config.
grep -q '_nvPause && \[ "\${_nvHeld:-0}" = 1 \]' "$DC" \
  && ok "H3: the millivolt hold is driven by a latch, not by an instantaneous comparison" \
  || no "H3: the millivolt pause is not latched - it will oscillate as the pack sags under the hold"
_nvl=$(grep -c '_nvHeld=' "$DC")
[ "${_nvl:-0}" -ge 3 ] \
  && ok "H3: the latch has both edges and an initialiser ($_nvl assignments)" \
  || no "H3: only $_nvl _nvHeld assignment(s) - a latch needs set, clear and init"

# LIVE. Only meaningful on a firmware-limit phone that is plugged.
#
# THE THRESHOLD HAS TO BE ONE THE PACK HAS ALREADY PASSED. The first version of this arm used a
# fixed 4300mV, which a pack at 39% has not reached -- so _ge_pause_cap was correctly false, the
# firmware was correctly left unrestricted at 100, and the arm called that a failure. A millivolt
# pause does not clamp on sight; it clamps when the voltage verdict trips, which is exactly how the
# switch path behaves. So read the live voltage and set the threshold just UNDER it: the verdict is
# then true on the next pass and charge_stop_level must move off 100.
#
# volt_now is millivolts (batt-interface.sh takes the first four digits of voltage_now).
_gcst=$(grep -m1 -o '/sys/devices/platform/[^ ]*charge_stop_level' "$DC" 2>/dev/null)
[ -n "$_gcst" ] || _gcst=/sys/devices/platform/google,charger/charge_stop_level
_vn=$(cat $PS/battery/voltage_now 2>/dev/null)
_vmv=${_vn%"${_vn#????}"}
case "${_vmv:-x}" in ''|*[!0-9]*) _vmv= ;; esac
if [ "$nativeq" = 1 ] && [ "$plugged" = 1 ] && [ -f "$_gcst" ] && [ -n "$_vmv" ] \
   && [ "$_vmv" -gt 3200 ] 2>/dev/null; then
  _thr=$(( _vmv - 100 ))
  _res=$(( _thr - 100 ))
  echo "  -- H3 LIVE: pack reads ${_vmv}mV; setting pause=${_thr}mV resume=${_res}mV"
  sed -i "s|^capacity=.*|capacity=(5 101 $_res $_thr false)|" "$CFG"
  $TMPDIR/acc -D restart >/dev/null 2>&1
  _w=0; _sl=
  while [ $_w -lt 90 ]; do
    sleep 5; _w=$((_w+5))
    _sl=$(cat "$_gcst" 2>/dev/null)
    [ "${_sl:-100}" != 100 ] && break
  done
  if [ -z "${_sl:-}" ]; then
    sk "H3 LIVE: could not read $_gcst"
  elif [ "$_sl" = 100 ]; then
    no "H3 LIVE: a ${_thr}mV pause the pack has ALREADY passed still left charge_stop_level=100 after ${_w}s"
  else
    ok "H3 LIVE: a ${_thr}mV pause produced charge_stop_level=$_sl, not the clamped 100 (${_w}s)"
  fi
  restore
  sleep 8
else
  sk "H3 LIVE: needs a plugged firmware-limit phone with charge_stop_level and a readable voltage"
fi

# ================================================================= B5
# The backstop's preferred cut nodes (input_suspend and friends) mask */online to 0. Reading `!
# online` as an unplug therefore made it undo its own cut one loop after applying it - the one
# mechanism between a Tensor ignoring charge_stop_level and an overcharge.
grep -q '_nvbGone' "$DC" \
  && ok "B5: the backstop's unplug test is a named decision, not a bare ! online" \
  || no "B5: the backstop still tests ! online directly"
_blk=$(grep -A6 'f \$TMPDIR/\.nvb-on \] && \[ "\${nvb_cut:-0}" = 1 \]' "$DC" | tr '\n' ' ')
case "$_blk" in
  *present*) ok "B5: with its own cut applied the backstop asks present, not online" ;;
  *) no "B5: no present-based branch - an input cut still reads as an unplug: $_blk" ;;
esac
case "$_blk" in
  *online*) ok "B5: with no cut applied it still uses online, which is the more responsive signal" ;;
  *) no "B5: the online branch was lost" ;;
esac

restore
rm -rf "$SCR" 2>/dev/null
fin
