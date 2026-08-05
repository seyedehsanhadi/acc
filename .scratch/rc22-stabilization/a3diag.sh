#!/system/bin/sh
# What is actually wrong with this A3's charging? Read-only.
U=/sys/class/power_supply/usb
B=/sys/class/power_supply/battery
M=/sys/class/power_supply/main
echo "=== identity ==="
echo "acc build=$(sed -n 's/^commit=//p' /data/adb/vr25/acc/.build-id 2>/dev/null)"
echo "uptime=$(cut -d' ' -f1 /proc/uptime)s"
echo
echo "=== charger right now ==="
for n in online present real_type type voltage_now voltage_max current_max input_current_settled \
         hw_current_max pd_active hvdcp_opti_allowed adapter_cc_mode typec_mode typec_cc_orientation; do
  [ -r "$U/$n" ] && printf '  usb/%-24s %s\n' "$n" "$(cat $U/$n 2>/dev/null)"
done
echo "  battery/status           $(cat $B/status)"
echo "  battery/current_now      $(cat $B/current_now)"
echo "  battery/charge_type      $(cat $B/charge_type 2>/dev/null)"
echo "  battery/health           $(cat $B/health 2>/dev/null)"
echo "  battery/temp             $(cat $B/temp)"
echo "  battery/capacity         $(cat $B/capacity)"
echo "  battery/cycle_count      $(cat $B/cycle_count 2>/dev/null)"
echo "  main/current_max         $(cat $M/current_max 2>/dev/null)"
echo "  main/input_current_settled $(cat $M/input_current_settled 2>/dev/null)"
echo
echo "=== who is voting the input current down? (last 40 votes) ==="
dmesg 2>/dev/null | grep -E "USB_ICL|SW_QC3|AICL|THERMAL|hvdcp|apsd|typec|cc-|OTG" | tail -40
echo
echo "=== ACC writes in the last stretch ==="
tail -12 /dev/.vr25/acc/.write-ledger 2>/dev/null
echo
echo "=== is ACC even the one holding it? switch state ==="
echo "  input_suspend=$(cat $B/input_suspend 2>/dev/null)"
echo "  cfg switch=$(sed -n 's/^chargingSwitch=//p' /data/adb/vr25/acc-data/config.txt)"
echo "  cfg capacity=$(sed -n 's/^capacity=//p' /data/adb/vr25/acc-data/config.txt)"
echo "  cfg current=$(sed -n 's/^maxChargingCurrent=//p' /data/adb/vr25/acc-data/config.txt)"
