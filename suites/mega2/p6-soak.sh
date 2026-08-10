#!/system/bin/sh
# P6 - soak. The same enforcement, over and over, looking for what one cycle cannot show.
#
# WHY A SOAK EXISTS SEPARATELY FROM P4
#   P4 proves each mechanism works ONCE. Every failure this project has actually shipped was different:
#   it appeared on the third cycle, or the tenth, or only after a latch had been set and cleared a few
#   times. One pass cannot see any of that.
#
#   Specifically hunted here:
#     CONTRACT EROSION   a QC/PD contract that survives one cap cycle but degrades a step per cycle.
#                        Ledger-proven history: 7.7V -> 4675mV across a run, one re-kick at a time.
#     LATCH LEAK         .hvcontract set and never cleared (blocks every future repair), or cleared when
#                        it should hold (permits the re-kick that destroys the contract).
#     RESUME CREEP       resume latency growing cycle over cycle - the signature of a switch scan or a
#                        verification loop being re-entered when it should be cached.
#     WRITE GROWTH       ledger entries per cycle climbing, meaning idempotency is decaying.
#     STRANDING          any cycle that ends with charging blocked. Checked every cycle, not just at
#                        the end, so the failing cycle is identifiable.
#
# Everything is restored between cycles and again at the end. shutdown_temp is never written.

hdr "P6 SOAK"

plugged || { no "cable NOT attached - P6 requires it in"; return 0 2>/dev/null || exit 0; }

CYCLES=${CYCLES:-5}
_v0=$(vbus); _apsd0=$(cnt -F 'apsd_rerun' $LEDGER); _led0=$(ledger_lines)
_orig_cap=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
note "start: level $(lvl)%  temp $(tempc)C  vbus ${_v0}  status $(kstat)"
note "running ${CYCLES} pause/resume cycles"

_lat=; _wr=; _fails=0; _vmin=$_v0; _vseq=

# Pre-cycle control: the same number of windows, measured BEFORE any cycling, so there is at least one
# reference that cannot be contaminated by the cycling it is meant to be compared against.
_cyc_n=$CYCLES
note "measuring a pre-cycle control (${CYCLES} windows, no cycling)..."
_pf=$(vbus); _pi=0; _ps=
while [ $_pi -lt "$CYCLES" ]; do
  sleep 50
  _pv=$(vbus); _ps="${_ps}${_pv} "
  _pi=$(( _pi + 1 ))
done
set -- $_ps
eval "_pl=\${$#}"
_ctl_pre=$(( ${_pf:-0} - ${_pl:-0} ))
note "pre-cycle control: ${_ps}-> drop ${_ctl_pre}uV"

_cycle=1
while [ $_cycle -le $CYCLES ]; do
  _l=$(lvl)
  case "${_l:-x}" in ''|*[!0-9]*) no "cycle ${_cycle}: battery level unreadable"; break;; esac
  _p=$(( _l + 1 )); _r=$(( _l - 3 )); [ "$_r" -lt 5 ] 2>/dev/null && _r=5
  _lw=$(ledger_lines)

  # ---- pause
  acc -s resume_capacity=$_r pause_capacity=$_p >/dev/null 2>&1
  _i=0; _paused=no
  while [ $_i -lt 150 ]; do
    sleep 10; _i=$(( _i + 10 ))
    case "$(kstat)" in Discharging|Not?charging|Idle) _paused=yes; break;; esac
  done

  # ---- resume: move BOTH levels. On Tensor only charge_start_level re-arms, so raising the pause
  # alone does not restart charging - measured, and the reason this moves the pair.
  acc -s resume_capacity=$(( _l + 5 )) pause_capacity=$(( _l + 8 )) >/dev/null 2>&1
  _j=0; _res=no
  while [ $_j -lt 150 ]; do
    sleep 10; _j=$(( _j + 10 ))
    case "$(kstat)" in Charging|Full) _res=yes; break;; esac
  done

  _vn=$(vbus)
  [ "${_vn:-0}" -lt "${_vmin:-0}" ] 2>/dev/null && _vmin=$_vn
  _vseq="${_vseq}${_vn} "
  _wn=$(( $(ledger_lines) - ${_lw:-0} ))
  _lat="${_lat}${_j} "
  _wr="${_wr}${_wn} "

  # Per-cycle verdicts, so a failure names its cycle.
  if [ "$_paused" = yes ] && [ "$_res" = yes ]; then
    ok "cycle ${_cycle}: paused in ${_i}s, resumed in ${_j}s, vbus ${_vn}, ${_wn} writes"
  else
    _fails=$(( _fails + 1 ))
    no "cycle ${_cycle}: paused=${_paused} resumed=${_res} (level ${_l}%, vbus ${_vn}) - enforcement did not complete"
  fi
  # Never leave a cycle with charge blocked.
  sw_released || no "cycle ${_cycle} ended with charging BLOCKED ($(sw_state_desc))"
  _cycle=$(( _cycle + 1 ))
done

cp -f $RECOVER.config $CFG 2>/dev/null
daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1; sleep 6

# ---- contract erosion, measured AGAINST A CONTROL ----------------------------------------------------
# The first version of this failed only if vbus fell below an absolute 6V, and therefore PASSED a
# textbook erosion pattern on a Mi A3: 7.90 -> 7.69 -> 7.50 -> 7.27 -> 7.26 -> 7.06, monotonic, every
# single cycle. The absolute floor is the wrong criterion; the SLOPE is the signal.
#
# But a slope alone is not a verdict either. A control run on the same phone with NO cap cycling at all
# fell FASTER - 6.29 -> 5.93V, through the 6V line that cycling never crossed - because that charger
# sags under sustained load as the pack fills. Meanwhile a Pixel on a healthy charger held 8.725 ->
# 8.750V through both cycling and control. So a declining contract can be entirely the charger's doing,
# and failing on the trend by itself would have blamed ACC for a warm power brick.
#
# The only honest test is differential: measure the drop across the cycling window, then measure the
# drop across an equally long window with no cycling, and attribute only the EXCESS to ACC.
_v1=$(vbus); _apsd1=$(cnt -F 'apsd_rerun' $LEDGER)
[ "${_v1:-0}" -lt "${_vmin:-0}" ] 2>/dev/null && _vmin=$_v1   # the final read belongs in the minimum too
note "vbus per cycle: ${_vseq}"
note "vbus ${_v0} -> ${_v1} (lowest seen ${_vmin})   apsd_rerun ${_apsd0} -> ${_apsd1}"

set -- $_vseq
_cyc_n=$#
if [ "${_cyc_n:-0}" -ge 3 ]; then
  _cyc_first=$1; eval "_cyc_last=\${$#}"
  _cyc_drop=$(( ${_cyc_first:-0} - ${_cyc_last:-0} ))
  note "drop across ${_cyc_n} CYCLING windows: ${_cyc_drop}uV"

  # TWO controls, one BEFORE the cycles and one AFTER, and the supply is allowed to settle first.
  #
  # The single post-cycle control was worthless and looked fine. Its first sample was taken the instant
  # the last cycle ended - at the bottom of the hole the cycling had just dug - so it could not show the
  # same fall no matter what. Measured on a Mi A3: cycling fell 988mV, the control reported -7uV, and
  # the excess came out as the entire cycling drop. Reading the control's own samples gave it away:
  # 6519024 6098608 6105872 5899296, a 620mV fall from a first value of 5892032. The supply had
  # RECOVERED to 6.52V after cycling stopped and then drifted down again; the control simply started
  # below where it then climbed to.
  #
  # Both arms must start from a comparable state. A pre-cycle control gives one that is not downstream
  # of the cycling at all, the post-cycle one keeps a reading from the same part of the charge, and the
  # settle lets the supply return to steady state before it is sampled.
  ctl_window() {  # prints the drop across $_cyc_n windows of 50s
    _cf=$(vbus); _ci=0; _cs=
    while [ $_ci -lt "$_cyc_n" ]; do
      sleep 50
      _cv=$(vbus); _cs="${_cs}${_cv} "
      _ci=$(( _ci + 1 ))
    done
    set -- $_cs
    eval "_cl=\${$#}"
    note "  samples: ${_cs}" >&2
    echo $(( ${_cf:-0} - ${_cl:-0} ))
  }

  note "settling before the post-cycle control (the supply recovers once cycling stops)..."
  sleep 90
  note "measuring the post-cycle control..."
  _ctl_post=$(ctl_window)
  note "drop across ${_cyc_n} POST-cycle control windows: ${_ctl_post}uV"

  # _ctl_pre was measured before the cycles began; if it is missing fall back to the post value alone.
  if [ -n "${_ctl_pre:-}" ]; then
    _ctl_drop=$(( ( _ctl_pre + _ctl_post ) / 2 ))
    note "control mean of pre (${_ctl_pre}uV) and post (${_ctl_post}uV): ${_ctl_drop}uV"
  else
    _ctl_drop=$_ctl_post
    note "no pre-cycle control available; using the post value alone"
  fi

  _excess=$(( _cyc_drop - _ctl_drop ))
  note "excess attributable to cap cycling: ${_excess}uV"
  # 200mV of headroom: below that the two windows are not distinguishable on a supply that moves this
  # much on its own.
  if [ "${_excess:-0}" -gt 200000 ] 2>/dev/null; then
    no "cap cycling costs ${_excess}uV MORE than an equivalent idle window - the contract is being eroded by ACC, not the charger"
  elif [ "${_ctl_drop:-0}" -gt 200000 ] 2>/dev/null; then
    ok "the contract declines (${_cyc_drop}uV cycling) but the control drops ${_ctl_drop}uV with ACC idle - this charger sags on its own, ACC is not the cause"
  else
    ok "the contract is stable under cycling (${_cyc_drop}uV over ${_cyc_n} cycles, control ${_ctl_drop}uV)"
  fi
else
  skip "the erosion trend (fewer than 3 cycles recorded)"
fi

[ "${_apsd1:-0}" -eq "${_apsd0:-0}" ]   && ok "no apsd_rerun fired across ${CYCLES} cycles"   || no "$(( _apsd1 - _apsd0 )) apsd_rerun(s) during the soak - each one costs the contract until a replug"

# ---- resume creep ------------------------------------------------------------------------------------
set -- $_lat
if [ $# -ge 3 ]; then
  _first=$1; eval "_last=\${$#}"
  note "resume latencies: ${_lat}"
  if [ "${_last:-0}" -gt $(( ${_first:-1} * 2 )) ] 2>/dev/null; then
    no "resume latency grew from ${_first}s to ${_last}s across the soak - something is being re-entered per cycle instead of cached"
  else
    ok "resume latency stayed flat (${_first}s first, ${_last}s last) - no per-cycle work accumulating"
  fi
fi

# ---- write growth ------------------------------------------------------------------------------------
set -- $_wr
if [ $# -ge 3 ]; then
  _wf=$1; eval "_wl=\${$#}"
  note "writes per cycle: ${_wr}"
  if [ "${_wl:-0}" -gt $(( ${_wf:-1} + 3 )) ] 2>/dev/null; then
    no "writes per cycle climbed ${_wf} -> ${_wl} - idempotency is decaying under repetition"
  else
    ok "writes per cycle stable (${_wf} -> ${_wl}) - idempotency holds under repetition"
  fi
fi

# ---- latch lifecycle ---------------------------------------------------------------------------------
# The latch must exist while a high-voltage contract is present and must not survive its plug.
if [ "${_v1:-0}" -ge 6000000 ] 2>/dev/null; then
  [ -f $TD/.hvcontract ] \
    && ok "the contract latch is set while a high-voltage supply is attached" \
    || no "no contract latch despite a ${_v1}uV supply - a load sag would permit a re-kick"
else
  skip "latch presence (no high-voltage contract on this charger)"
fi

# ---- final state -------------------------------------------------------------------------------------
sw_released \
  && ok "charging permitted after the soak ($(sw_state_desc))" \
  || no "charging BLOCKED after the soak ($(sw_state_desc))"
[ "$(grep -m1 '^capacity=' $CFG 2>/dev/null)" = "$_orig_cap" ] \
  && ok "capacity settings restored after the soak" || no "capacity NOT restored after the soak"
[ "${_fails:-0}" -eq 0 ] \
  && ok "all ${CYCLES} cycles completed enforcement" \
  || no "${_fails} of ${CYCLES} cycles failed to complete enforcement"
note "end: level $(lvl)%  temp $(tempc)C  status $(kstat)  ledger grew $(( $(ledger_lines) - ${_led0:-0} )) lines"
