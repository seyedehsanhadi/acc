#!/system/bin/sh
# fieldregress.sh - one check per REPORTED field bug. Runs on any build, so rc21 and rc22 can be
# compared directly. A fix is only proven when the same check fails on rc21 and passes on rc22.
#
# THE REPORTS
#   R1 curtana (Redmi Note 9S)  "fast charge gone". ACC's init restore overwrote live negotiated
#                               input-current nodes with values captured in an earlier session
#                               (usb/current_max 2450000 -> 2600000, main 1600000 -> 3000000), and
#                               the phone then sat on USB_DCP at 4.59V/1.5A.
#   R2 sweet (Redmi Note 10 Pro) "charging is not stopped when the max temperature is reached".
#                               battery/status said Charging, current read -2410000, and `acc -i`
#                               reported Discharging at 41C against max_temp=40, so every limit was
#                               skipped. Two halves: the verdict (R2a) and the pause itself (R2b).
#   R3 "disabled the current limit but it still sticks" -- the cap would not clear.
#   R4 ACC reporting Charging with no cable attached.
#   R5 the daemon alive but not looping, so nothing enforced and every health check said fine.
#
# Read-mostly. R1/R3 write ACC settings and restore them; nothing else changes state.

TD=/dev/.vr25/acc
DD=/data/adb/vr25/acc-data
B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
P=0; F=0; SK=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ SK=$((SK+1)); echo "  skip  $*"; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
accst(){ acc -i 2>/dev/null | sed -n 's/^status //p' | head -1; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }

S_MCC=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
S_T=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')')
restore(){
  acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
  acc -s cooldown_temp=$(echo $S_T|cut -d' ' -f1) max_temp=$(echo $S_T|cut -d' ' -f2) \
         resume_temp=$(echo $S_T|cut -d' ' -f3) >/dev/null 2>&1
}
trap 'restore; echo; echo "=== $P passed, $F failed, $SK skipped ==="; exit 0' EXIT INT TERM HUP

echo "=== field-report regression $(date) ==="
echo "build   : $(sed -n 's/^commit=//p' /data/adb/vr25/acc/.build-id 2>/dev/null) label=$(sed -n 's/^label=//p' /data/adb/vr25/acc/.build-id 2>/dev/null)"
echo "device  : $(getprop ro.product.device)  level=$(rd $B/capacity)%  temp=$(( $(rd $B/temp) / 10 ))C"
echo "charging: kernel=$(rd $B/status) acc=$(accst) online=$(rd $U/online) icl=$(rd $U/current_max)"
echo

CHARGING=no
[ "$(rd $B/status)" = Charging ] && CHARGING=yes

# ---- R1: curtana. A live negotiated input node must survive ACC's restore -------------------------
echo "--- R1 (curtana): does ACC overwrite a live negotiated input current? ---"
_n=$U/current_max
_live=$(rd $_n)
if ! isnum "$_live" || [ "$_live" -lt 500000 ]; then
  sk "R1 -- usb/current_max reads ${_live:-unreadable}, no live negotiation to protect"
else
  # Ask ACC to restore (clear the cap). A live value well above any plausible cut must be left alone.
  acc -s max_charging_current= >/dev/null 2>&1
  sleep 12
  _after=$(rd $_n)
  if [ "$_after" = "$_live" ]; then
    ok "R1 a live ${_live} was left alone across a restore"
  elif isnum "$_after" && [ "$_after" -ge "$_live" ]; then
    ok "R1 the node was raised ${_live} -> ${_after}, never lowered"
  else
    no "R1 ACC LOWERED a live negotiated node: ${_live} -> ${_after} (the curtana report)"
  fi
fi

# ---- R2a: sweet. The charge-direction verdict must survive a wrong cached polarity ---------------
echo "--- R2a (sweet): is the charging verdict right when the cached polarity is wrong? ---"
if [ "$CHARGING" != yes ]; then
  sk "R2a -- not charging, so a wrong sign cannot be exercised"
else
  _dp=$(sed -n 's/^_DPOL=//p' $TD/.batt-interface.sh 2>/dev/null | tail -1)
  _st=$(accst)
  echo "      cached polarity=${_dp:-none}  kernel=$(rd $B/status)  acc=$_st  current=$(rd $B/current_now)"
  if [ "$_st" = Discharging ]; then
    no "R2a ACC reports Discharging while the kernel says Charging -- every limit is skipped (the sweet report)"
  else
    ok "R2a ACC agrees the phone is charging ($_st), so the limits are reachable"
  fi
fi

# ---- R2b: sweet. max_temp must actually stop charging --------------------------------------------
echo "--- R2b (sweet): does max_temp actually stop the charge? ---"
if [ "$CHARGING" != yes ]; then
  sk "R2b -- not charging, nothing to stop"
else
  _t=$(( $(rd $B/temp) / 10 ))
  _mt=$(( _t - 2 )); _ct=$(( _mt - 2 )); _rt=$(( _mt - 6 ))
  if [ "$_rt" -lt 15 ]; then
    sk "R2b -- pack at ${_t}C is too cool to set a limit under it safely"
  else
    acc -s cooldown_temp=$_ct max_temp=$_mt resume_temp=$_rt >/dev/null 2>&1
    sleep 55
    _sw=$(rd $B/input_suspend); _ks=$(rd $B/status)
    echo "      max_temp=${_mt}C pack=$(( $(rd $B/temp) / 10 ))C switch=$_sw kernel=$_ks"
    if [ "$_ks" != Charging ] || [ "$_sw" = 1 ]; then
      ok "R2b charging stopped above max_temp (switch=$_sw kernel=$_ks)"
    else
      no "R2b STILL CHARGING above max_temp -- the sweet report reproduces"
    fi
    restore; sleep 20
  fi
fi

# ---- R3: the current cap must clear -----------------------------------------------------------------
echo "--- R3: does a current limit actually clear? ---"
# The node value alone cannot answer this on a weak supply: AICL moves it continuously, so a
# before/after comparison is noise. ACC's own write ledger can -- a clear must produce a RELEASE
# write, and nothing may re-apply the cap after it. That re-apply is the actual field bug: the CLI
# clears the config, the daemon re-applies from the copy it read a moment earlier, and because the
# clear already removed the marker every later restore no-ops and the phone stays capped for good.
_L=$TD/.write-ledger
_n0=$(wc -l < $_L 2>/dev/null); isnum "$_n0" || _n0=0
acc -s max_charging_current=1000 >/dev/null 2>&1
sleep 25
acc -s max_charging_current= >/dev/null 2>&1
sleep 35
_n1=$(wc -l < $_L 2>/dev/null); isnum "$_n1" || _n1=$_n0
_win=$(sed -n "$(( _n0 + 1 )),${_n1}p" $_L 2>/dev/null)
_rel=$(printf '%s\n' "$_win" | grep -n 'current_max <- 5000000' | tail -1 | cut -d: -f1)
_recap=$(printf '%s\n' "$_win" | grep -n 'current_max <- 1000000' | tail -1 | cut -d: -f1)
echo "      ledger lines this window=$(( _n1 - _n0 ))  last release at #${_rel:-none}  last re-cap at #${_recap:-none}"
if [ -z "$_rel" ]; then
  no "R3 the clear produced no release write at all"
elif [ -n "$_recap" ] && [ "$_recap" -gt "$_rel" ]; then
  no "R3 the cap was RE-APPLIED after the release ('disabled it but it still sticks')"
else
  ok "R3 the clear released the nodes and nothing re-applied the cap"
fi

# ---- R4: no cable, no charging ----------------------------------------------------------------------
echo "--- R4: is the verdict honest with no cable? ---"
if [ "$(rd $U/online)" = 1 ] || [ "$(rd $U/present)" = 1 ]; then
  sk "R4 -- a cable is attached, cannot test the unplugged verdict here"
else
  _st=$(accst)
  [ "$_st" = Charging ] && no "R4 ACC reports Charging with no cable attached" \
                        || ok "R4 no cable -> $_st"
fi

# ---- R5: the daemon must be LOOPING, not merely alive -----------------------------------------------
echo "--- R5: is the daemon actually looping? ---"
_p=$(rd $TD/acc.lock)
if [ -z "$_p" ] || [ ! -d "/proc/$_p" ]; then
  no "R5 daemon is not running at all"
else
  _a=$(wc -l < $DD/logs/flight.log 2>/dev/null); sleep 30
  _b=$(wc -l < $DD/logs/flight.log 2>/dev/null)
  if [ "${_b:-0}" -gt "${_a:-0}" ]; then
    ok "R5 daemon alive AND looping (flight.log grew $(( _b - _a )) lines)"
  else
    no "R5 daemon alive but NOT looping -- nothing is being enforced and every health check says fine"
  fi
fi

# ---- R6: the polarity cache must not accumulate contradictions --------------------------------------
echo "--- R6: polarity cache ---"
_l=$(grep -c '^_DPOL=' $TD/.batt-interface.sh 2>/dev/null)
case "${_l:-x}" in
  ''|*[!0-9]*) sk "R6 no interface cache to inspect";;
  0) sk "R6 no polarity latched yet";;
  1) ok "R6 exactly one cached polarity";;
  *) no "R6 $_l contradictory _DPOL lines -- whichever was written last silently wins";;
esac
