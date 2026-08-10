#!/system/bin/sh
# P4 - plugged behaviour. The enforcement paths, exercised on a live cable.
#
# Every test here restores what it changed before moving on, and the phase trap restores again on any
# exit. shutdown_temp is never written: a low value powers the phone off at room temperature, and the
# standing instruction is to leave it alone.

hdr "P4 PLUGGED BEHAVIOUR"

plugged || { no "cable NOT attached - P4 requires it in"; return 0 2>/dev/null || exit 0; }

_L0=$(lvl)
note "start: level ${_L0}%  temp $(tempc)C  vbus $(vbus)  status $(kstat)"

# ---- 1: it is actually charging to begin with ---------------------------------------------------------
_c=$(cur_raw)
note "current_now=${_c}  (sign convention differs per phone; magnitude is what matters)"
case "$(kstat)" in
  Charging|Full) ok "kernel reports charging with the cable in" ;;
  *) no "kernel reports '$(kstat)' with a cable attached - not charging before we changed anything" ;;
esac

# ---- 2: the capacity pause fires --------------------------------------------------------------------------
# Set pause one point above the present level so the limit is reached within a few percent, and resume
# well below so the phone does not immediately restart. Restored straight after.
_orig_cap=$(grep -m1 '^capacity=' $CFG 2>/dev/null)
_p=$(( ${_L0:-50} + 1 )); _r=$(( ${_L0:-50} - 3 ))
[ "$_r" -lt 5 ] 2>/dev/null && _r=5
acc -s resume_capacity=$_r pause_capacity=$_p >/dev/null 2>&1
sleep 4
_landed=$(grep -m1 '^capacity=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//' | cut -d' ' -f4)
if [ "${_landed:-}" = "$_p" ]; then
  ok "pause_capacity=${_p} landed in config"
  _i=0; _paused=no
  while [ $_i -lt 240 ]; do
    sleep 15; _i=$(( _i + 15 ))
    case "$(kstat)" in
      Discharging|Not?charging|Idle) _paused=yes; break ;;
    esac
    [ "$(lvl)" -gt "$_p" ] 2>/dev/null && break
  done
  if [ "$_paused" = yes ]; then
    ok "charging paused at the limit after ${_i}s (level $(lvl)%, limit ${_p}%)"
    grep -qE 'write|native charge_stop' $LEDGER 2>/dev/null \
      && ok "and the enforcing write is in the ledger" \
      || no "the phone paused but NO write was ledgered - enforcement is invisible"
  else
    no "charging did NOT pause within ${_i}s of reaching the ${_p}% limit (level now $(lvl)%)"
  fi
else
  no "pause_capacity did not land (config says ${_landed}, asked for ${_p})"
fi

# ---- 3: and it resumes ---------------------------------------------------------------------------------------
# Raising the pause limit alone does NOT re-arm charging on every phone: on Tensor only
# charge_start_level re-arms, and pulsing stop=100 was measured not to work. Move BOTH.
acc -s resume_capacity=$(( ${_L0:-50} + 5 )) pause_capacity=$(( ${_L0:-50} + 8 )) >/dev/null 2>&1
_i=0; _res=no
while [ $_i -lt 180 ]; do
  sleep 15; _i=$(( _i + 15 ))
  case "$(kstat)" in Charging|Full) _res=yes; break;; esac
done
[ "$_res" = yes ] \
  && ok "charging resumed after the limit was raised (${_i}s)" \
  || no "charging did NOT resume within ${_i}s of raising the limit - the phone is stranded"

# restore capacity
cp -f $RECOVER.config $CFG 2>/dev/null
daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1; sleep 5
[ "$(grep -m1 '^capacity=' $CFG 2>/dev/null)" = "$_orig_cap" ] \
  && ok "capacity settings restored" || no "capacity NOT restored"

# ---- 4: the fast-charge contract survives a pause/resume cycle ---------------------------------------------------
# apsd_rerun renegotiates QC/PD down to a 5V floor and only a physical replug recovers it. A cap cycle
# must never trigger one. Ledger-proven failure: a 7.7V QC3 contract ended at 4675mV after two leaked
# re-kicks during a cap cycle.
_v0=$(vbus)
_apsd0=$(cnt -F 'apsd_rerun' $LEDGER)
sleep 30
_v1=$(vbus)
_apsd1=$(cnt -F 'apsd_rerun' $LEDGER)
note "vbus ${_v0} -> ${_v1}   apsd_rerun entries ${_apsd0} -> ${_apsd1}"
if [ "${_v0:-0}" -ge 6000000 ] 2>/dev/null; then
  [ "${_v1:-0}" -ge 6000000 ] 2>/dev/null \
    && ok "a high-voltage contract survived the cycle (${_v1}uV)" \
    || no "the contract collapsed from ${_v0} to ${_v1} - it will not recover without a replug"
  [ "${_apsd1:-0}" -eq "${_apsd0:-0}" ] \
    && ok "no apsd_rerun was fired on a healthy contract" \
    || no "$(( _apsd1 - _apsd0 )) apsd_rerun(s) fired on a live contract - this is what destroys it"
else
  note "supply is on the 5V floor (${_v1}uV); contract-preservation cannot be judged on this charger"
  skip "high-voltage contract preservation (no HV contract to preserve)"
fi

# ---- 5: the thermal limit fires and is recorded ------------------------------------------------------------------
# max_temp is set just under the present pack temperature so the limit is crossed immediately.
# cooldown/resume follow it down; shutdown_temp is left exactly as it was.
_orig_t=$(grep -m1 '^temperature=' $CFG 2>/dev/null)
_tc=$(tempc)
_mt=$(( _tc - 1 )); [ "$_mt" -lt 20 ] 2>/dev/null && _mt=20
acc -s cooldown_temp=$(( _mt - 1 )) max_temp=$_mt resume_temp=$(( _mt - 2 )) >/dev/null 2>&1
sleep 5
_landed=$(grep -m1 '^temperature=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//' | cut -d' ' -f2)
if [ "${_landed:-}" = "$_mt" ]; then
  ok "max_temp=${_mt} landed (pack is at ${_tc}C, so the limit is already exceeded)"
  _i=0; _tp=no
  while [ $_i -lt 120 ]; do
    sleep 15; _i=$(( _i + 15 ))
    case "$(kstat)" in Discharging|Not?charging|Idle) _tp=yes; break;; esac
  done
  if [ "$_tp" = yes ]; then
    ok "thermal limit paused charging after ${_i}s"
  else
    no "pack at $(tempc)C against a ${_mt}C limit and charging did NOT stop within ${_i}s"
  fi
  if is_native; then
    _ss=$(cat /sys/devices/platform/google,charger/charge_stop_level 2>/dev/null)
    _sa=$(cat /sys/devices/platform/google,charger/charge_start_level 2>/dev/null)
    note "native pair during thermal hold: stop=${_ss} start=${_sa} level=$(lvl)%"
    [ "${_ss:-101}" -le "$(lvl)" ] 2>/dev/null \
      && ok "native hold is AT or BELOW the present level, so it actually holds" \
      || no "native stop=${_ss} is ABOVE the level $(lvl) - the thermal limit is silently absent"
    grep -q 'native charge_stop_level' $LEDGER 2>/dev/null \
      && ok "and the native write is ledgered" \
      || no "native thermal hold happened but was not ledgered"
  fi
else
  no "max_temp did not land (config says ${_landed}, asked for ${_mt})"
fi

# restore temperature and confirm charging comes back
cp -f $RECOVER.config $CFG 2>/dev/null
daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1; sleep 6
_i=0; _back=no
while [ $_i -lt 150 ]; do
  sleep 15; _i=$(( _i + 15 ))
  case "$(kstat)" in Charging|Full) _back=yes; break;; esac
done
[ "$_back" = yes ] \
  && ok "charging resumed after the thermal limit was restored (${_i}s)" \
  || no "charging did NOT resume after restoring temperature - phone left held"
[ "$(grep -m1 '^temperature=' $CFG 2>/dev/null)" = "$_orig_t" ] \
  && ok "temperature settings restored" || no "temperature NOT restored"

# ---- 6: nothing was left cut ------------------------------------------------------------------------------------------
# By switch CLASS, via sw_released. The binary comparison that used to live here reported a healthy
# Pixel as "switch left CUT at 74" while the phone was visibly charging at 52%: on a level switch, 74
# is pause_capacity and resting there IS the limit working. Same defect as the one fixed in P0 and P2
# and missed here, which is exactly how a false alarm survives a fix.
note "$(sw_state_desc)"
sw_released \
  && ok "charging is permitted by the switch after P4 - nothing left cut" \
  || no "the switch is BLOCKING charge after P4 ($(sw_state_desc))"
note "end: level $(lvl)%  temp $(tempc)C  status $(kstat)"
