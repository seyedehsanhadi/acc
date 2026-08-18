#!/system/bin/sh
# suites/fakeps/mkfake.sh - a writable stand-in for /sys/class/power_supply.
# Exists because the node a defect lives on is not always present on the test phones:
# usb/input_current_max is absent on BOTH laurus and bluejay, so native_verify_backstop
# returns at its second line and the defect cannot be observed on real hardware here.
mkfake() {
  _d=$1
  rm -rf "$_d" 2>/dev/null; mkdir -p "$_d/usb" "$_d/main" "$_d/battery" 2>/dev/null
  for _n in online present current_max input_current_max input_current_limit voltage_now; do
    echo 0 > "$_d/usb/$_n"
  done
  echo 0 > "$_d/main/current_max"
  for _n in capacity temp current_now charge_counter input_suspend; do echo 0 > "$_d/battery/$_n"; done
  echo Discharging > "$_d/battery/status"
  chmod -R 0666 "$_d" 2>/dev/null || :
  return 0
}
