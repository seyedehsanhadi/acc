#!/system/bin/sh
# What controls high-voltage negotiation on this phone?
echo "=== charger identity ==="
U=/sys/class/power_supply/usb
for n in real_type type usb_type voltage_now voltage_max voltage_max_design current_max online \
         pd_active pd_allowed hvdcp_opti_allowed quick_charge_type; do
  [ -r "$U/$n" ] && echo "  usb/$n = $(cat $U/$n 2>/dev/null)"
done
echo "=== candidate HVDCP / voltage-request nodes ==="
for p in /sys/class/power_supply/*/ /sys/class/qcom-battery/ /sys/module/qpnp_smb5/parameters/ /sys/module/battery/parameters/; do
  [ -d "$p" ] || continue
  for n in force_hvdcp_9v hvdcp_enable hvdcp3_type pd_voltage_max pd_voltage_min voltage_max \
           dp_dm force_9v force_5v adapter_cc_mode hvdcp_opti_allowed apsd_rerun restrict_chg; do
    f="$p$n"
    [ -e "$f" ] || continue
    echo "  $f = $(cat "$f" 2>/dev/null)  writable=$([ -w "$f" ] && echo yes || echo no)"
  done
done
echo "=== dp_dm (the Qualcomm voltage-request interface) ==="
ls -l /sys/class/power_supply/battery/dp_dm 2>/dev/null || echo "  (no dp_dm)"
echo "=== dmesg: recent hvdcp / voltage lines ==="
dmesg 2>/dev/null | grep -iE "hvdcp|qc3|dp_dm|pulse|9v|vbus" | tail -12
