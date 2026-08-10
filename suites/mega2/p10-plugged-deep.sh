#!/system/bin/sh
# P10 - the whole plugged question in one pass: does enforcement work, and what does it cost?
#
# WHY THIS REPLACES P6 + P7
#   Those two phases sampled the same thing twice. P6 cycled the limit and watched vbus; P7 ran an
#   idle arm and a cycling arm and watched vbus. The cycling arm of P7 and the whole of P6 are the
#   same experiment, run twice, for 22 minutes.
#
#   Merged, arm C does double duty: it is the soak (latency, writes per cycle, apsd_rerun, latch
#   lifecycle, stranding) AND the enforcement-cost arm of the attribution. Same evidence, ~10 minutes.
#
#   THREE ARMS, same charger, screen off, wakelock held:
#     A  daemon STOPPED   no ACC process at all -> the kernel and charger on their own
#     B  daemon idle      ACC alive and arbitrating, but never pausing
#     C  daemon cycling   ACC actively pausing and resuming
#
#   Attribution:
#     A          what the supply does by itself. Nothing in ACC can be blamed for this.
#     B - A      the cost of ACC merely being alive.
#     C - B      the cost of the enforcement path - the only part ACC controls.
#
# WHAT MAKES THE NUMBERS TRUSTWORTHY
#   - The tolerance is DERIVED from arm A's own measured swing, not a constant. A Mi A3's QC3 supply
#     moved 1.09V inside one 150s window with ACC stopped; a fixed 200mV margin declared a 370mV
#     "erosion" that was pure supply movement, and a Pixel on PD held 8.800-8.850V over the same
#     window. One constant cannot serve both protocols.
#   - Arms run in a fixed order with a settle between them, and each arm's first sample is taken
#     AFTER that settle - never at the instant the previous arm ended. A control that started at the
#     bottom of the hole cycling had just dug reported a -7uV drop against a real 534mV.
#   - The pack must be below its limit and below the taper threshold, or the charge curve is the
#     dominant variable rather than the build.
#
# SAFETY: config restored between arms and at the end; nothing writes shutdown_temp.

hdr "P10 PLUGGED: ENFORCEMENT AND ITS COST"

plugged || { no "cable NOT attached - P10 needs it in"; return 0 2>/dev/null || exit 0; }

REPS=${REPS:-3}
WIN=${WIN:-50}
_orig_cap=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
# P10's own snapshot, NOT the run-wide RECOVER.config.
#
# The phase restored from RECOVER.config (taken in P0, before every other phase) but then asserted
# against _orig_cap (read here, after them). When an earlier phase left the config changed the two
# disagree and P10 reports "capacity NOT restored" for a difference it did not create - which is
# exactly what a Mi A3 run reported after the fault-recovery phase preceding it left 70/75 behind.
# Restore what THIS phase changed; RECOVER.config stays the crash net for the trap.
_P10SNAP=$TMPDIR/p10.config
cp -f $CFG $_P10SNAP 2>/dev/null
_apsd0=$(cnt -F 'apsd_rerun' $LEDGER)

input keyevent 26 >/dev/null 2>&1 || :
echo mega2p > /sys/power/wake_lock 2>/dev/null || :

# The pack must be able to charge in EVERY arm, or arm A charges while B and C sit paused and the
# comparison reflects load rather than build. Caught on a Pixel at exactly its 74% limit.
_lv=$(lvl)
_pc=$(printf '%s' "$_orig_cap" | sed 's/.*(//;s/).*//' | cut -d' ' -f4)
_raised=no
if [ -n "${_lv:-}" ] && [ -n "${_pc:-}" ] && [ "${_lv:-0}" -ge $(( ${_pc:-100} - 1 )) ] 2>/dev/null; then
  _np=$(( _lv + 12 )); [ "$_np" -gt 100 ] 2>/dev/null && _np=100
  _nr=$(( _lv + 8 ));  [ "$_nr" -gt 99 ]  2>/dev/null && _nr=99
  note "pack at ${_lv}% against a ${_pc}% limit - raising to ${_nr}/${_np} so every arm charges"
  acc -s resume_capacity=$_nr pause_capacity=$_np >/dev/null 2>&1
  sleep 5; _raised=yes
fi
case "$(kstat)" in
  Charging|Full) ok "charging at the start, so all three arms see the same load" ;;
  *) no "not charging at the start - the arms would not be comparable"; ;;
esac

# Samples vbus across REPS windows. Notes go to STDERR: this function's stdout is consumed by
# `set --`, and printing commentary there turned the label into $1/$2/$3 and every figure to noise.
vwin() {   # $1 label -> "first last drop swing"
  sleep 20                       # settle: never sample at the instant the previous arm ended
  _f=$(vbus); _lo=$_f; _hi=$_f; _i=0; _seq="$_f "
  while [ $_i -lt "$REPS" ]; do
    sleep $WIN; _i=$(( _i + 1 ))
    _c=$(vbus); _seq="${_seq}${_c} "
    [ "${_c:-0}" -lt "${_lo:-0}" ] 2>/dev/null && _lo=$_c
    [ "${_c:-0}" -gt "${_hi:-0}" ] 2>/dev/null && _hi=$_c
  done
  note "$1: ${_seq}" >&2
  note "$1: $(awk -v a=$(cur_raw) 'BEGIN{x=a/1000000;if(x<0)x=-x;printf "%.2fA",x}') x $(awk -v v=$(cat $G/voltage_now) 'BEGIN{printf "%.2fV",v/1000000}')  lvl $(lvl)%  temp $(tempc)C  band $(soc_band)" >&2
  echo "$_f $_c $(( ${_f:-0} - ${_c:-0} )) $(( ${_hi:-0} - ${_lo:-0} ))"
}

# ---- ARM A: no ACC at all --------------------------------------------------------------------------
daemon_stop >/dev/null 2>&1
if daemon_alive; then
  no "could not stop the daemon - the kernel-only reference cannot be measured"; DA=; SA=
else
  ok "daemon stopped - arm A is the kernel and charger with no ACC process"
  set -- $(vwin "ARM A kernel-only"); DA=$3; SA=$4
fi

# ---- ARM B: ACC alive, never pausing ----------------------------------------------------------------
cp -f $_P10SNAP $CFG 2>/dev/null
daemon_start >/dev/null 2>&1
if daemon_alive; then
  ok "daemon running and below the limit, so it cannot pause"
  set -- $(vwin "ARM B acc-idle"); DB=$3; SB=$4
else
  no "the daemon would not start for arm B"; DB=; SB=
fi

# ---- ARM C: ACC cycling. This IS the soak. -----------------------------------------------------------
# Pause/resume detected by polling every 3s rather than 10s: the transitions are instantaneous, so a
# coarse poll only adds dead time to every cycle.
_cf=$(vbus); _clo=$_cf; _chi=$_cf
_lat=; _wr=; _fails=0; _cyc=1
while [ $_cyc -le "$REPS" ]; do
  _l=$(lvl)
  case "${_l:-x}" in ''|*[!0-9]*) no "cycle ${_cyc}: level unreadable"; break;; esac
  _p=$(( _l + 1 )); _r=$(( _l - 3 )); [ "$_r" -lt 5 ] 2>/dev/null && _r=5
  _lw=$(ledger_lines)

  acc -s resume_capacity=$_r pause_capacity=$_p >/dev/null 2>&1
  _i=0; _paused=no
  while [ $_i -lt 150 ]; do
    sleep 3; _i=$(( _i + 3 ))
    case "$(kstat)" in Discharging|Not?charging|Idle) _paused=yes; break;; esac
  done

  # Both levels move: on Tensor only charge_start_level re-arms, so raising the pause alone does not
  # restart charging.
  acc -s resume_capacity=$(( _l + 5 )) pause_capacity=$(( _l + 8 )) >/dev/null 2>&1
  _j=0; _res=no
  while [ $_j -lt 150 ]; do
    sleep 3; _j=$(( _j + 3 ))
    case "$(kstat)" in Charging|Full) _res=yes; break;; esac
  done

  _v=$(vbus)
  [ "${_v:-0}" -lt "${_clo:-0}" ] 2>/dev/null && _clo=$_v
  [ "${_v:-0}" -gt "${_chi:-0}" ] 2>/dev/null && _chi=$_v
  _wn=$(( $(ledger_lines) - ${_lw:-0} ))
  _lat="${_lat}${_j} "; _wr="${_wr}${_wn} "

  if [ "$_paused" = yes ] && [ "$_res" = yes ]; then
    ok "cycle ${_cyc}: paused ${_i}s, resumed ${_j}s, vbus ${_v}, ${_wn} writes"
  else
    _fails=$(( _fails + 1 ))
    no "cycle ${_cyc}: paused=${_paused} resumed=${_res} - enforcement did not complete"
  fi
  sw_released || no "cycle ${_cyc} ended with charging BLOCKED ($(sw_state_desc))"
  _cyc=$(( _cyc + 1 ))
done
_cl=$(vbus); DC=$(( ${_cf:-0} - ${_cl:-0} )); SC=$(( ${_chi:-0} - ${_clo:-0} ))
note "ARM C acc-cycling: ${_cf} -> ${_cl}  (drop ${DC}uV, swing ${SC}uV)"

cp -f $_P10SNAP $CFG 2>/dev/null
daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1; sleep 5
echo mega2p > /sys/power/wake_unlock 2>/dev/null || :

# ---- soak assertions, from arm C ----------------------------------------------------------------------
[ "${_apsd0:-0}" -eq "$(cnt -F 'apsd_rerun' $LEDGER)" ] \
  && ok "no apsd_rerun fired across ${REPS} cycles" \
  || no "$(( $(cnt -F 'apsd_rerun' $LEDGER) - _apsd0 )) apsd_rerun(s) - each costs the contract until a replug"

set -- $_lat
if [ $# -ge 2 ]; then
  _f1=$1; eval "_l1=\${$#}"
  note "resume latencies: ${_lat}"
  [ "${_l1:-0}" -le $(( ${_f1:-1} * 2 + 3 )) ] 2>/dev/null \
    && ok "resume latency stayed flat (${_f1}s -> ${_l1}s)" \
    || no "resume latency grew ${_f1}s -> ${_l1}s - work accumulating per cycle"
fi
set -- $_wr
if [ $# -ge 2 ]; then
  _w1=$1; eval "_w2=\${$#}"
  note "writes per cycle: ${_wr}"
  [ "${_w2:-0}" -le $(( ${_w1:-1} + 3 )) ] 2>/dev/null \
    && ok "writes per cycle stable (${_w1} -> ${_w2}) - idempotency holds under repetition" \
    || no "writes per cycle climbed ${_w1} -> ${_w2} - idempotency decaying"
fi
[ "${_fails:-0}" -eq 0 ] && ok "all ${REPS} cycles completed enforcement" \
                         || no "${_fails} of ${REPS} cycles failed to enforce"

# ---- attribution ----------------------------------------------------------------------------------------
echo ""
note "vbus drop over ${REPS}x${WIN}s per arm (positive = falling)"
note "  A kernel-only : ${DA:-n/a}uV  (swing ${SA:-n/a})"
note "  B acc-idle    : ${DB:-n/a}uV  (swing ${SB:-n/a})"
note "  C acc-cycling : ${DC:-n/a}uV  (swing ${SC:-n/a})"

# THE TOLERANCE COMES FROM ARMS A AND B ONLY - NEVER FROM THE ARM UNDER TEST.
#
# It was the largest swing across all three arms, which on a noisy supply is arm C's own. That makes
# the cycling verdict circular: arm C is judged against a bar it sets itself, so it cannot fail no
# matter how much cycling costs. Measured on a Mi A3: A swung 244mV, B 230mV, C 678mV, the tolerance
# was taken as 678mV, and a 440mV cycling cost was passed as "no measurable voltage". That is the
# noise-floor mistake from the arm baseline wearing a different hat.
#
# A and B are both ACC-invariant with respect to CYCLING - one has no daemon at all, the other has a
# daemon that never pauses - so their spread measures the supply and the load, which is exactly the
# reference arm C should be held against.
#
# A consequence worth stating rather than hiding: on a supply whose own wander exceeds any plausible
# ACC cost, this method cannot resolve the question, and the phase now says so instead of passing.
# EVERY COMPARISON IS JUDGED ONLY AGAINST THE ARMS THAT ARE NOT IN IT.
#
#   B vs A  ->  reference SA        (arm A alone; B is under test)
#   C vs B  ->  reference SA,SB     (neither is C)
#
# The old code used one tolerance, the largest swing across ALL THREE arms, for both comparisons. On
# a noisy supply the largest is the arm being judged, so each verdict set its own bar and neither
# could fail. Measured on a Mi A3: A swung 244mV, B 230mV, C 678mV, the tolerance was taken as 678mV,
# and a 440mV cycling cost passed as "no measurable voltage". The same circularity applied to the
# B-vs-A verdict through SB. Both are gone.
#
# A floor of 100mV because no reading is finer than that.
_ref(){   # $@ swings of the arms NOT under test -> the reference
  _r=0
  for _s in "$@"; do
    case "${_s:-x}" in ''|*[!0-9]*) continue;; esac
    [ "$_s" -gt "$_r" ] 2>/dev/null && _r=$_s
  done
  [ "$_r" -lt 100000 ] 2>/dev/null && _r=100000
  echo "$_r"
}
_tolB=$(_ref "${SA:-}")
_tolC=$(_ref "${SA:-}" "${SB:-}")
note "reference for B (arm A only): ${_tolB}uV;  for C (arms A and B): ${_tolC}uV"

# If the reference arms wander further than any effect worth finding, there is no verdict to give.
# Saying so is the honest outcome; emitting a pass would be the circularity coming back by the door.
_incB=no; _incC=no
[ "${_tolB:-0}" -gt 300000 ] 2>/dev/null && _incB=yes
[ "${_tolC:-0}" -gt 300000 ] 2>/dev/null && _incC=yes

# Arm A on its own carries no assertion. A drop can never exceed its own window's swing - both come
# from the same samples - so any test of it passes by construction, and a can't-fail check counted as
# a PASS is how a suite reports coverage it does not have.
[ -n "${DA:-}" ] && note "arm A moved ${DA}uV with NO ACC RUNNING - the reference, not a verdict"

if [ -n "${DA:-}" ] && [ -n "${DB:-}" ]; then
  _ca=$(( DB - DA ))
  if [ "$_incB" = yes ]; then
    skip "ACC-alive cost is INCONCLUSIVE: the difference is ${_ca}uV but arm A wanders ${_tolB}uV by itself"
  elif [ "${_ca:-0}" -le "${_tolB:-0}" ] 2>/dev/null; then
    ok "ACC being alive costs no measurable supply voltage (${_ca}uV against arm A's ${_tolB}uV)"
  else
    no "the supply falls ${_ca}uV MORE with the daemon alive than without it, against arm A's ${_tolB}uV"
  fi
  baseline_record alive_cost_uv "$_ca"
fi
if [ -n "${DB:-}" ] && [ -n "${DC:-}" ]; then
  _cc=$(( DC - DB ))
  if [ "$_incC" = yes ]; then
    skip "cap cycling is INCONCLUSIVE on this charger: the difference is ${_cc}uV but arms A and B wander ${_tolC}uV by themselves. Re-run on a supply that holds steady, or at a lower state of charge."
  elif [ "${_cc:-0}" -le "${_tolC:-0}" ] 2>/dev/null; then
    ok "cap cycling costs no measurable supply voltage (${_cc}uV against a ${_tolC}uV reference) - enforcement does not erode the contract"
  else
    no "cap cycling costs ${_cc}uV beyond an idle daemon, against a ${_tolC}uV reference - the enforcement path IS eroding the contract"
  fi
  baseline_record cycling_cost_uv "$_cc"
fi

# ---- restore -----------------------------------------------------------------------------------------------
if [ "$_raised" = yes ]; then
  _ov=$(printf '%s' "$_orig_cap" | sed 's/.*(//;s/).*//')
  set -- $_ov
  acc -s resume_capacity=$3 pause_capacity=$4 >/dev/null 2>&1
  sleep 4
fi
[ "$(grep -m1 '^capacity=' $CFG 2>/dev/null)" = "$_orig_cap" ] \
  && ok "capacity settings restored" || no "capacity NOT restored (was ${_orig_cap})"
sw_released && ok "charging permitted at the end" || no "charging BLOCKED at the end ($(sw_state_desc))"
daemon_alive && ok "daemon alive at the end" || no "daemon DOWN at the end"
