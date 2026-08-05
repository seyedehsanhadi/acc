#!/system/bin/sh
# tiebreak.sh - does ACC know it is charging when the cached polarity is WRONG?
#
# Both test phones currently hold an inverted _DPOL with .dpol_unstable armed, so nothing will
# re-latch it. That is the exact condition the rc21 sign-vs-kernel tie-break exists for, and the
# condition it has never been tested under. If it fails, is_charging goes false while the pack
# fills and ALL FOUR limits stop being evaluated - the sweet report.
#
# Waits for the cable, then samples every observable and says which arbiter ruled each time.
# Read-only. Changes no setting, writes no node.

B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
G=$B
[ -f /sys/class/power_supply/maxfg/capacity ] && G=/sys/class/power_supply/maxfg
TD=/dev/.vr25/acc
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }

DPOL=$(sed -n 's/^_DPOL=//p' $TD/.batt-interface.sh 2>/dev/null)
UNST=$([ -f $TD/.dpol_unstable ] && echo armed || echo no)
echo "device=$(getprop ro.product.device) dpol=$DPOL unstable=$UNST build=$(sed -n 's/^label=//p' /data/adb/vr25/acc/.build-id 2>/dev/null)"

echo "waiting for the cable (up to 180s)..."
i=0
while [ $i -lt 180 ]; do
  [ "$(rd $U/online)" = 1 ] && break
  i=$((i + 5)); sleep 5
done
if [ "$(rd $U/online)" != 1 ]; then echo "no cable after 180s - nothing to test"; exit 0; fi
echo "cable detected after ${i}s. settling 20s..."
sleep 20

# What the SIGN alone would say, so we can see whether it needed rescuing.
sign_says(){
  _c=$1
  case "$DPOL" in
    +) case "$_c" in -*) echo Charging;; *) echo Discharging;; esac;;
    -) case "$_c" in -*) echo Discharging;; *) echo Charging;; esac;;
    *) echo unknown;;
  esac
}

P=0; F=0
echo
echo "sample  online kernel     sign-alone    acc         current      cc-delta"
prev_cc=$(rd $G/charge_counter)
n=0
while [ $n -lt 10 ]; do
  on=$(rd $U/online); ks=$(rd $B/status); cu=$(rd $B/current_now)
  cc=$(rd $G/charge_counter)
  as=$(acc -i 2>/dev/null | sed -n 's/^status //p' | head -1)
  sa=$(sign_says "$cu")
  d=
  case "${cc:-x}${prev_cc:-x}" in *[!0-9-]*) : ;; *) d=$(( cc - prev_cc ));; esac
  printf '%-7s %-6s %-10s %-13s %-11s %-12s %s\n' "$((n+1))" "$on" "$ks" "$sa" "$as" "$cu" "${d:-?}"
  if [ "$on" = 1 ] && [ "$ks" = Charging ]; then
    if [ "$as" = Charging ]; then P=$((P + 1)); else F=$((F + 1)); fi
  fi
  prev_cc=$cc
  n=$((n + 1)); sleep 8
done

echo
echo "verdict: $P correct, $F wrong (of the samples where the kernel said Charging)"
if [ "$F" -gt 0 ]; then
  echo "FAIL - ACC believed it was NOT charging while the pack was filling."
  echo "       is_charging is false in those windows, so max_temp, pause_capacity, and the"
  echo "       current and voltage caps are all skipped. This is the sweet report."
elif [ "$P" -gt 0 ]; then
  echo "PASS - the tie-break held with an inverted cached polarity ($DPOL, unstable=$UNST)."
  echo "       Every limit stays reachable."
else
  echo "INCONCLUSIVE - the kernel never reported Charging during the run."
fi
echo
echo "vbus=$(_v=$(rd $U/voltage_now); case ${_v:-x} in *[!0-9]*) echo ?;; *) echo $((_v / 1000));; esac)mV real_type=$(rd $U/real_type) pd_active=$(rd $U/pd_active) icl=$(rd $U/current_max)"
echo "flips=$(cat $TD/.dpol_flips 2>/dev/null) dpol_lines=$(grep -c '^_DPOL=' $TD/.batt-interface.sh 2>/dev/null)"
