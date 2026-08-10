#!/system/bin/sh
# P7 - is the supply voltage falling because of the KERNEL/charger, or because of ACC?
#
# THE QUESTION THIS SETTLES
#   A Mi A3 was seen dropping 7.90 -> 7.06V across five cap cycles, monotonically, one step per cycle.
#   That is exactly what contract erosion by ACC looks like. A first control with the daemon RUNNING but
#   idle fell even faster (6.29 -> 5.93V), which suggested the charger - but it did not prove it, because
#   ACC was still alive in that window and still touching nodes.
#
#   Only one arm answers it cleanly: the daemon STOPPED. With no ACC process at all, any remaining
#   decline belongs to the kernel, the charger or the cable. That is the arm this phase adds.
#
#   THREE ARMS, same duration, same charger, screen off throughout:
#     A  daemon STOPPED          no ACC whatsoever -> pure kernel/charger behaviour
#     B  daemon running, idle    ACC alive, arbitrating, but never pausing (pack far below the limit)
#     C  daemon running, cycling ACC actively pausing and resuming
#
#   Attribution:
#     A falls  ->  the supply sags on its own. Nothing in ACC can be blamed for that much.
#     B - A    ->  the cost of ACC merely being alive.
#     C - B    ->  the cost of cap cycling, which is the only part ACC controls.
#
# Screen is forced off and a wakelock held, because a screen coming on mid-arm changes the load and
# therefore the sag - that would be measuring the display, not the charger.

hdr "P7 VOLTAGE DROP ATTRIBUTION"

plugged || { no "cable NOT attached - P7 needs it in"; return 0 2>/dev/null || exit 0; }

WIN=${VWIN:-150}
_orig_cap=$(grep -m1 '^capacity=' $CFG 2>/dev/null)

# THE PACK MUST BE CHARGING IN ALL THREE ARMS, or this measures the wrong thing.
#
# Arm A stops the daemon, so enforcement stops with it. If the pack is sitting AT the pause limit, arm A
# starts charging while arms B and C stay paused - and the comparison then reflects a load difference,
# not a build difference. Caught on a Pixel at exactly 74% against a 74% limit.
#
# Raise the pause well clear for the duration and put it back at the end. The recovery copy is updated
# too, because reset_config between arms would otherwise reinstate the low limit and re-pause the pack.
_lv=$(lvl)
_pc=$(grep -m1 '^capacity=' $CFG 2>/dev/null | sed 's/.*(//;s/).*//' | cut -d' ' -f4)
_raised=no
if [ -n "${_lv:-}" ] && [ -n "${_pc:-}" ] && [ "${_lv:-0}" -ge $(( ${_pc:-100} - 1 )) ] 2>/dev/null; then
  _np=$(( _lv + 12 )); [ "$_np" -gt 100 ] 2>/dev/null && _np=100
  _nr=$(( _lv + 8 ));  [ "$_nr" -gt 99 ]  2>/dev/null && _nr=99
  note "pack at ${_lv}% against a ${_pc}% limit - raising to ${_nr}/${_np} so every arm charges"
  acc -s resume_capacity=$_nr pause_capacity=$_np >/dev/null 2>&1
  sleep 5
  cp -f $CFG $RECOVER.config 2>/dev/null
  _raised=yes
  case "$(kstat)" in
    Charging|Full) ok "pack is charging again, all three arms will see the same load" ;;
    *) no "pack still not charging after raising the limit - arm comparison would be invalid"; ;;
  esac
fi

input keyevent 26 >/dev/null 2>&1 || :
echo mega2v > /sys/power/wake_lock 2>/dev/null || :
sleep 10

# NOTE LINES GO TO STDERR HERE, DELIBERATELY.
#
# This function's stdout is consumed by `set -- $(vsample ...)`, so anything it prints becomes a
# positional parameter. The first version called note() (which writes to stdout) for the sample
# sequence, so $1/$2/$3 were words out of the LABEL rather than voltages, and every drop figure the
# phase produced was nonsense. Only the final three numbers may reach stdout; commentary goes to
# stderr, which the run still captures into the log.
vsample() {  # $1 label -> prints "first last drop swing" on stdout, samples across WIN seconds
  _f=$(vbus); _i=0; _seq="$_f "
  _lo=$_f; _hi=$_f
  while [ $_i -lt "$WIN" ]; do
    sleep 30; _i=$(( _i + 30 ))
    _c=$(vbus); _seq="${_seq}${_c} "
    [ "${_c:-0}" -lt "${_lo:-0}" ] 2>/dev/null && _lo=$_c
    [ "${_c:-0}" -gt "${_hi:-0}" ] 2>/dev/null && _hi=$_c
  done
  _lst=$_c
  _swing=$(( ${_hi:-0} - ${_lo:-0} ))
  note "$1: ${_seq}" >&2
  note "$1: batt $(awk -v a=$(cur_raw) 'BEGIN{x=a/1000000; if(x<0)x=-x; printf "%.2fA", x}') x $(awk -v v=$(cat $G/voltage_now) 'BEGIN{printf "%.2fV", v/1000000}')  lvl $(lvl)%  temp $(tempc)C" >&2
  echo "$_f $_lst $(( ${_f:-0} - ${_lst:-0} )) ${_swing}"
}

# ---- ARM A: no ACC at all ----------------------------------------------------------------------------
daemon_stop >/dev/null 2>&1
if daemon_alive; then
  no "could not stop the daemon - the kernel-only arm cannot be measured"
  DA=
else
  ok "daemon stopped - this arm is pure kernel/charger with no ACC process"
  set -- $(vsample "ARM A kernel-only"); AF=$1; AL=$2; DA=$3; SA=$4
fi

# ---- ARM B: ACC alive, never pausing -----------------------------------------------------------------
cp -f $RECOVER.config $CFG 2>/dev/null
daemon_start >/dev/null 2>&1
if daemon_alive; then
  ok "daemon running, pack below the limit so it cannot pause"
  set -- $(vsample "ARM B acc-idle"); BF=$1; BL=$2; DB=$3; SB=$4
else
  no "daemon would not start for the idle arm"
  DB=
fi

# ---- ARM C: ACC cycling ------------------------------------------------------------------------------
_l=$(lvl)
case "${_l:-x}" in
  ''|*[!0-9]*) skip "the cycling arm (battery level unreadable)"; DC= ;;
  *)
    _cf=$(vbus); _ci=0
    while [ $_ci -lt "$WIN" ]; do
      _n=$(lvl); _p=$(( _n + 1 )); _r=$(( _n - 3 )); [ "$_r" -lt 5 ] 2>/dev/null && _r=5
      acc -s resume_capacity=$_r pause_capacity=$_p >/dev/null 2>&1
      sleep 45
      acc -s resume_capacity=$(( _n + 5 )) pause_capacity=$(( _n + 8 )) >/dev/null 2>&1
      sleep 30
      _ci=$(( _ci + 75 ))
    done
    _cl=$(vbus); DC=$(( ${_cf:-0} - ${_cl:-0} ))
    note "ARM C acc-cycling: ${_cf} -> ${_cl}"
    ok "cycling arm completed"
    ;;
esac

cp -f $RECOVER.config $CFG 2>/dev/null
daemon_stop >/dev/null 2>&1; daemon_start >/dev/null 2>&1; sleep 6
echo mega2v > /sys/power/wake_unlock 2>/dev/null || :

# ---- attribution -------------------------------------------------------------------------------------
echo ""
note "vbus drop over ${WIN}s per arm (positive = falling)"
note "  A kernel-only : ${DA:-n/a}uV"
note "  B acc-idle    : ${DB:-n/a}uV"
note "  C acc-cycling : ${DC:-n/a}uV"

# THE TOLERANCE IS MEASURED, NOT ASSUMED.
#
# A fixed 200mV was used first. On a Mi A3 arm A - with no ACC process running at all - swung 6.09 to
# 7.18V inside one 150s window, roughly 1.1V, five times the threshold meant to judge it. That margin
# could never have separated ACC from the charger on QC3, and it duly reported a 370mV "erosion" that
# was pure supply movement. A Pixel on PD held 8.800-8.850V over the same window, so one constant
# cannot serve both protocols.
#
# Arm A measures how much this supply moves on its own; that swing IS the noise floor for this phone,
# this charger, today. Anything smaller is unattributable by construction.
_tol=${SA:-0}
[ "${SB:-0}" -gt "${_tol:-0}" ] 2>/dev/null && _tol=$SB
[ "${_tol:-0}" -lt 100000 ] 2>/dev/null && _tol=100000
note "tolerance derived from the supply's own swing with ACC stopped: ${_tol}uV"

if [ -n "${DA:-}" ]; then
  if [ "${DA:-0}" -gt "${_tol:-200000}" ] 2>/dev/null; then
    ok "the supply moves ${DA}uV (swing ${SA}uV) with NO ACC RUNNING - the sag is the kernel, charger or cable, and cannot be attributed to ACC"
  else
    ok "the supply is steady with no ACC running (${DA}uV) - a fair reference for the other arms"
  fi
fi
if [ -n "${DA:-}" ] && [ -n "${DB:-}" ]; then
  _costAlive=$(( DB - DA ))
  note "cost of ACC merely being alive: ${_costAlive}uV"
  [ "${_costAlive:-0}" -le "${_tol:-200000}" ] 2>/dev/null \
    && ok "ACC being alive costs no measurable supply voltage (${_costAlive}uV)" \
    || no "the supply falls ${_costAlive}uV MORE with the daemon alive than without it"
fi
if [ -n "${DB:-}" ] && [ -n "${DC:-}" ]; then
  _costCycle=$(( DC - DB ))
  note "cost of cap cycling: ${_costCycle}uV"
  [ "${_costCycle:-0}" -le "${_tol:-200000}" ] 2>/dev/null \
    && ok "cap cycling costs no measurable supply voltage (${_costCycle}uV) - the enforcement path does not erode the contract" \
    || no "cap cycling costs ${_costCycle}uV of supply voltage beyond an idle daemon - the enforcement path IS eroding the contract"
fi

[ "$(grep -m1 '^capacity=' $CFG 2>/dev/null)" = "$_orig_cap" ] \
  && ok "capacity settings restored after P7" || no "capacity NOT restored after P7"
sw_released && ok "charging permitted after P7" || no "charging BLOCKED after P7 ($(sw_state_desc))"
