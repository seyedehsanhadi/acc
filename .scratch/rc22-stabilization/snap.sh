#!/system/bin/sh
# snap.sh - one-shot snapshot of everything that decides whether ACC works on this phone.
#
# Stable key=value output so an rc21 run and an rc22 run can be diffed line by line. Read-only:
# it changes no setting and writes no charge node.

PS=/sys/class/power_supply
TD=/dev/.vr25/acc
CFG=/data/adb/vr25/acc-data/config.txt
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
isnum(){ case "${1:-x}" in ''|*[!0-9]*) return 1;; esac; }

echo "ts=$(date +%s)"
echo "device=$(getprop ro.product.device)"
echo "android=$(getprop ro.build.version.release)"
echo "acc_prop=$(sed -n 's/^versionCode=//p' /data/adb/vr25/acc/module.prop 2>/dev/null)"
echo "build_label=$(sed -n 's/^label=//p' /data/adb/vr25/acc/.build-id 2>/dev/null)"
echo "build_commit=$(sed -n 's/^commit=//p' /data/adb/vr25/acc/.build-id 2>/dev/null)"

# --- the fact chain, resolved exactly as ACC resolves it ---
N_CAP=; N_ST=; N_CUR=; N_TEMP=; N_VOLT=; AMPF=; DPOL=
if [ -f $TD/.batt-interface.sh ]; then
  . $TD/.batt-interface.sh 2>/dev/null || :
  N_CAP=$battCapacity; N_ST=$battStatus; N_CUR=$currFile; N_TEMP=$temp; N_VOLT=$voltNow
  AMPF=$ampFactor_; DPOL=${_DPOL-}
fi
abspath(){ case "${1:-}" in ''|/*) echo "${1:-}";; *) echo "$PS/$1";; esac; }
N_CAP=$(abspath "$N_CAP"); N_ST=$(abspath "$N_ST"); N_CUR=$(abspath "$N_CUR")
N_TEMP=$(abspath "$N_TEMP"); N_VOLT=$(abspath "$N_VOLT")
N_CC=${N_CAP%capacity}charge_counter

echo "node_level=$N_CAP"
echo "node_status=$N_ST"
echo "node_current=$N_CUR"
echo "node_temp=$N_TEMP"
echo "node_volt=$N_VOLT"
echo "ampfactor=$AMPF"
echo "dpol=$DPOL"
echo "dpol_lines=$(grep -c '^_DPOL=' $TD/.batt-interface.sh 2>/dev/null)"
echo "dpol_flips=$(cat $TD/.dpol_flips 2>/dev/null)"
echo "dpol_unstable=$([ -f $TD/.dpol_unstable ] && echo yes || echo no)"

# --- live readings ---
_t=$(rd "$N_TEMP"); isnum "$_t" && _t=$((_t / 10)) || _t=
echo "level=$(rd "$N_CAP")"
echo "temp_c=$_t"
echo "volt_mv=$(_v=$(rd "$N_VOLT"); isnum "$_v" && echo $((_v / 1000)) || echo)"
echo "cur_raw=$(rd "$N_CUR")"
echo "cc=$(rd "$N_CC")"
echo "kernel_status=$(rd "$N_ST")"
echo "acc_status=$(acc -i 2>/dev/null | sed -n 's/^status //p' | head -1)"

# --- charger ---
echo "vbus_mv=$(_v=$(rd $PS/usb/voltage_now); isnum "$_v" && echo $((_v / 1000)) || echo)"
echo "real_type=$(rd $PS/usb/real_type)"
echo "pd_active=$(rd $PS/usb/pd_active)"
echo "icl=$(rd $PS/usb/current_max)"
echo "usb_online=$(rd $PS/usb/online)"
echo "charge_type=$(rd $PS/battery/charge_type)"

# --- switch + enforcement state ---
SWSPEC=$(sed -n 's/^chargingSwitch=(//p' "$CFG" 2>/dev/null | tr -d ')' | sed 's/ --$//')
SWN=$(echo "$SWSPEC" | cut -d' ' -f1)
case "$SWN" in ''|/*) : ;; *) SWN=$PS/$SWN ;; esac
echo "switch_node=$SWN"
echo "switch_off_value=$(echo "$SWSPEC" | cut -d' ' -f3)"
echo "switch_value=$(rd "$SWN")"
echo "cfg_capacity=$(sed -n 's/^capacity=//p' "$CFG" 2>/dev/null)"
echo "cfg_temperature=$(sed -n 's/^temperature=//p' "$CFG" 2>/dev/null)"
echo "cfg_current=$(sed -n 's/^maxChargingCurrent=//p' "$CFG" 2>/dev/null)"
echo "cfg_voltage=$(sed -n 's/^maxChargingVoltage=//p' "$CFG" 2>/dev/null)"

# --- native limit, when present ---
for _g in /sys/devices/platform/google,charger /sys/devices/platform/soc/soc:google,charger; do
  [ -f "$_g/charge_stop_level" ] || continue
  echo "native_stop=$(rd $_g/charge_stop_level)"
  echo "native_start=$(rd $_g/charge_start_level)"
  break
done

# --- daemon ---
D=$(rd $TD/acc.lock)
echo "daemon_pid=$D"
echo "daemon_alive=$([ -n "$D" ] && [ -d "/proc/$D" ] && echo yes || echo no)"
echo "testingsw=$([ -f $TD/.testingsw ] && echo yes || echo no)"
echo "ledger_lines=$(wc -l < $TD/.write-ledger 2>/dev/null)"
