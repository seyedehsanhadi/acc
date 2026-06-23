#!/system/bin/sh
# $id uninstaller
# id is set/corrected by build.sh
# Copyright 2019-2024, VR25
# License: GPLv3+

set -u
id=acc
domain=vr25
export TMPDIR=/dev/.$domain/$id

# set up busybox
#BB#
bin_dir=/data/adb/vr25/bin
busybox_dir=/dev/.vr25/busybox
magisk_busybox="$(ls /data/adb/*/bin/busybox /data/adb/magisk/busybox 2>/dev/null || :)"
[ -x $busybox_dir/ls ] || {
  mkdir -p $busybox_dir
  chmod 0755 $busybox_dir $bin_dir/busybox 2>/dev/null || :
  for f in $bin_dir/busybox $magisk_busybox /system/*bin/busybox*; do
    [ -x $f ] && eval $f --install -s $busybox_dir/ && break || :
  done
  [ -x $busybox_dir/ls ] || {
    echo "Install busybox or simply place it in $bin_dir/"
    echo
    exit 3
  }
}
case $PATH in
  $bin_dir:*) ;;
  *) export PATH="$bin_dir:$busybox_dir:$PATH";;
esac
unset f bin_dir busybox_dir magisk_busybox
#/BB#

exec 2>/dev/null

# terminate/kill $id processes
mkdir -p $TMPDIR
(flock -n 0 || {
  read pid
  kill $pid
  timeout 10 flock 0
  kill -KILL $pid >/dev/null 2>&1
  flock 0
}) <>$TMPDIR/${id}.lock

# uninstall
# D2: clean ACC's own tmp files but PRESERVE the acc-compat tester artifact -- acc-compat-verified
# is the tester->AccA handoff (a separate tool), not ACC's; the broad acc[-_]* glob used to wipe it.
for f in /data/local/tmp/${id}[-_]*; do
  [ -e "$f" ] || continue
  case "$f" in *compat*) continue;; esac
  rm -rf "$f"
done
rm -rf \
  /data/adb/service.d/${id}-*.sh \
  /data/data/mattecarra.accapp/files/$id \
  /data/data/com.termux/files/home/.termux/boot/${id}-init.sh

[ "${1:-}" = install ] || {
  # restore normal charging before removal -- ENABLE direction only, can never overcharge.
  # (a) re-enable cut/suspend/drain switches
  if cd /sys/class/power_supply 2>/dev/null; then
    for f in */charging_enabled */battery_charging_enabled */charge_enabled */charging_enable */enable_charging */enable_charger; do
      [ -w "$f" ] && echo 1 > "$f" 2>/dev/null || :
    done
    for f in */input_suspend */batt_slate_mode */op_disable_charge */night_charging */charge_disable */disable_charging */smart_charging_interruption */store_mode; do
      [ -w "$f" ] && echo 0 > "$f" 2>/dev/null || :
    done
    for f in */charge_control_limit; do
      [ -w "$f" ] && echo 0 > "$f" 2>/dev/null || :
    done
    # (a3) D5: un-cap charge voltage -- a voltage-cap switch lowers */voltage_max to stop charge;
    #      restore each to its design max so charging is never left voltage-limited.
    for f in */voltage_max; do
      [ -w "$f" ] || continue
      d="${f%voltage_max}voltage_max_design"
      [ -r "$d" ] && cat "$d" > "$f" 2>/dev/null || :
    done
    # (a4) D5/D8: re-run USB source detection / input-current arbitration so a charger left
    #      input-cut (online=0, */current_max=0 by an input_suspend-type switch) re-negotiates.
    #      Harmless when already online. Qualcomm: usb/apsd_rerun, battery/rerun_aicl.
    for f in */apsd_rerun */rerun_aicl; do
      [ -w "$f" ] && echo 1 > "$f" 2>/dev/null || :
    done
    # (a5) rc6 (B4): un-cap CURRENT-limit switches the daemon may have locked. The enable sweep
    # above writes "1" to on/off nodes, but the current-cap class is OFF=0 and is NOT un-capped by
    # that -- a device locked on */current_max, constant_charge_current[_max] or */input_current
    # would be left charging at 0 mA. Restore each to a high value (kernel clamps to its own max);
    # prefer the kernel's own _max for constant_charge_current. siop_level: 100 = full.
    for f in */constant_charge_current; do
      [ -w "$f" ] || continue
      d="${f}_max"
      [ -r "$d" ] && cat "$d" > "$f" 2>/dev/null || echo 5000000 > "$f" 2>/dev/null || :
    done
    for f in */current_max */input_current_limit */input_current */constant_charge_current_max; do
      [ -w "$f" ] && echo 5000000 > "$f" 2>/dev/null || :
    done
    for f in */siop_level; do
      [ -w "$f" ] && echo 100 > "$f" 2>/dev/null || :
    done
    cd / 2>/dev/null || :
  fi
  # (b) clear any NATIVE %-limit so the battery is not left capped (Pixel/Tensor charge_stop_level,
  #     Samsung batt_full_capacity, generic charge_control_*_threshold) -- 100 = charge fully, 0 = no floor
  for f in /sys/devices/platform/google,charger/charge_stop_level \
           /sys/devices/platform/soc/soc:google,charger/charge_stop_level \
           /sys/class/power_supply/*/charge_stop_level \
           /sys/class/power_supply/*/batt_full_capacity \
           /sys/class/power_supply/*/charge_control_end_threshold; do
    [ -w "$f" ] && echo 100 > "$f" 2>/dev/null || :
  done
  for f in /sys/devices/platform/google,charger/charge_start_level \
           /sys/devices/platform/soc/soc:google,charger/charge_start_level \
           /sys/class/power_supply/*/charge_start_level \
           /sys/class/power_supply/*/charge_control_start_threshold; do
    [ -w "$f" ] && echo 0 > "$f" 2>/dev/null || :
  done
  # (c) MediaTek pair
  [ -w /proc/mtk_battery_cmd/current_cmd ] && echo "0 0" > /proc/mtk_battery_cmd/current_cmd 2>/dev/null || :
  [ -w /proc/mtk_battery_cmd/en_power_path ] && echo 1 > /proc/mtk_battery_cmd/en_power_path 2>/dev/null || :

  # remove EVERY ACC path: the module dir (resolved + explicit), KSU staging, the systemless tree,
  # the data dir, ACC's busybox bin, then the parent and the KSU/APatch PATH symlinks (rc3).
  rm -rf $(readlink -f /data/adb/$domain/$id) \
    "/data/adb/modules/$id" \
    "/data/adb/modules_update/$id" \
    "/data/adb/$domain/$id" \
    "/data/adb/$domain/${id}-data" \
    "/data/adb/$domain/bin"
  rmdir "/data/adb/$domain" 2>/dev/null || :
  for b in /data/adb/ksu/bin /data/adb/ap/bin; do
    rm -f $b/$id $b/${id}a $b/${id}d 2>/dev/null
  done
  # rc9: also remove the tmpfs work dir (TMPDIR=/dev/.$domain/$id). The block above only
  # cleared /data/adb/$domain/*, leaving /dev/.vr25/acc (stale .config/.cfg/locks) on a
  # no-reboot uninstall. Leave /dev/.$domain/busybox (shared) intact.
  rm -rf "$TMPDIR" 2>/dev/null || :
}

exit 0
