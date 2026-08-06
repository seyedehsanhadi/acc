#!/system/bin/sh
# qc9v-prep.sh - get a Qualcomm phone onto the highest QuickCharge voltage it will take, and say
# plainly what is stopping it when it will not.
#
#   sh qc9v-prep.sh
#
# WHY
#   The curtana report is a QC contract collapsing to 5V. Reproducing it needs a contract ABOVE 5V
#   to begin with, and a Mi A3 will not always give one: it has no PD sink, so the voltage comes from
#   QuickCharge over the D+/D- pins, and QC3 only steps up when the charger IC actually asks for more
#   power. A phone that is nearly full, cool, and current-limited never asks.
#
# WHAT IT NEEDS
#   USB-A to USB-C, on a QuickCharge charger. A USB-C to USB-C cable cannot carry the QC handshake -
#   the phone sits at the Type-C 5V default no matter how many watts the charger is rated for. That
#   is measured on this hardware, not assumed: the same A3 on a 90W PD brick reported USB_DCP at 5V.
#
# WHAT IT DOES
#   Reads the state, clears anything ACC is imposing, lifts the vendor's restricted-charging mode if
#   it is engaged, then watches the negotiated voltage climb. Everything it changes is restored.

DD=/data/adb/vr25/acc-data; TD=/dev/.vr25/acc; M=/data/adb/vr25/acc
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }
U=/sys/class/power_supply/usb
Q=/sys/class/qcom-battery
G=/sys/class/power_supply/battery
for _c in /sys/class/power_supply/*/capacity; do _d=${_c%/capacity}
  [ -n "$(rd "$_c")" ] && [ -n "$(rd "$_d/status")" ] && { G=$_d; break; }; done

R0=$(rd $Q/restrict_chg); C0=$(rd $Q/restrict_cur)
S_MCC=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt | tr -d '()' | cut -d' ' -f1)
cleanup(){ trap - EXIT INT TERM HUP
  [ -n "$R0" ] && echo "$R0" > $Q/restrict_chg 2>/dev/null
  [ -n "$C0" ] && echo "$C0" > $Q/restrict_cur 2>/dev/null
  acc -s max_charging_current="$S_MCC" >/dev/null 2>&1
  echo ""; echo "--- restored: restrict_chg=$R0 restrict_cur=$C0 mcc=$(sed -n 's/^maxChargingCurrent=//p' $DD/config.txt) ---"
  exit 0; }
trap cleanup EXIT INT TERM HUP

echo "=== QC 9V readiness ==="
echo "build   : $(sed -n 's/^versionCode=//p' $M/module.prop)   device: $(getprop ro.product.device)"
echo "level   : $(rd $G/capacity)%   temp $(( $(rd $G/temp) / 10 ))C"
echo "screen  : $(dumpsys display 2>/dev/null | grep -o 'mScreenState=[A-Z_]*' | head -1 | cut -d= -f2)"
echo "supply  : type=$(rd $U/real_type)  vbus=$(rd $U/voltage_now)  icl=$(rd $U/current_max)  vmax=$(rd $U/voltage_max)"
echo "battery : I=$(rd $G/current_now)  status=$(rd $G/status)"
echo ""

_on=$(rd $U/online)
[ "$_on" = 1 ] || { echo "NOT PLUGGED. Use the QuickCharge charger's USB-A port with a USB-A to USB-C cable."; exit 0; }

# The cable is the single most common reason this fails, and the type node says which one is in use.
case "$(rd $U/real_type)" in
  *HVDCP*|*QC*)
    echo "cable   : OK - QuickCharge negotiated ($(rd $U/real_type)). This can go above 5V." ;;
  *)
    echo "cable   : WRONG for 9V. This phone reports $(rd $U/real_type)."
    echo "          A Mi A3 has no PD sink, so USB-C to USB-C gives the Type-C 5V default whatever"
    echo "          the charger is rated for. Use the QC charger's USB-A port with an A-to-C cable."
    echo "          Measured on this phone: 90W PD brick over C-to-C reported USB_DCP at 5V."
    exit 0 ;;
esac
echo ""

echo "clearing anything that suppresses demand (a phone that cannot draw does not ask for 9V):"
acc -s max_charging_current= >/dev/null 2>&1
if [ "$(rd $Q/restrict_chg)" = 1 ]; then
  echo "  the vendor's restricted-charging mode was ENGAGED (restrict_cur=$(rd $Q/restrict_cur)) - lifting"
  echo 0 > $Q/restrict_chg 2>/dev/null
  echo 5000000 > $Q/restrict_cur 2>/dev/null
else
  echo "  restricted-charging mode already off"
fi
sleep 20
echo ""

echo "watching the negotiation (QC3 steps up on demand, so this takes a minute or two):"
BEST=0; _n=0
while [ $_n -lt 15 ]; do
  _n=$((_n + 1)); sleep 20
  _v=$(rd $U/voltage_now); isnum "$_v" || continue
  [ "$_v" -gt "$BEST" ] && BEST=$_v
  printf '  t=%3ds  vbus %5s mV   icl %5s mA   batt %8s uA   level %s%%\n' \
    $((_n * 20)) "$(( _v / 1000 ))" "$(( $(rd $U/current_max) / 1000 ))" "$(rd $G/current_now)" "$(rd $G/capacity)"
  [ "$_v" -ge 8500000 ] && { echo "  >>> 9V reached"; break; }
done

echo ""
echo "highest seen: $(( BEST / 1000 )) mV"
if [ "$BEST" -ge 8500000 ]; then
  echo "VERDICT: 9V contract available. Ready for contract-stress.sh."
elif [ "$BEST" -ge 5500000 ]; then
  echo "VERDICT: above 5V at $(( BEST / 1000 )) mV but not 9V. That is still a real contract to"
  echo "         collapse, so contract-stress.sh is valid - it only needs >5.5V."
  echo "         QC3 steps on demand; a lower battery and the screen ON will ask for more."
else
  echo "VERDICT: stuck at 5V. Nothing here can collapse, so the stress test would prove nothing."
  echo "         Try: lower battery level, screen ON, and confirm the A-to-C cable is on a QC port."
fi
