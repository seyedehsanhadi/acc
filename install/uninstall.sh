#!/system/bin/sh
# $id uninstaller
# id is set/corrected by build.sh
# Copyright 2019-2024, VR25
# License: GPLv3+

set -u
id=acc
domain=vr25
#SQ#
# Motorola's MMI MediaTek driver exposes CURRENT_MAX as a write-only disable flag.
# Other MediaTek drivers expose a numeric current limit at the same supply names.
# Require both the vendor and the unreadable ABI before using boolean semantics.
mtk_current_flag() {
  case "/$1" in
    */mtk-master-charger/current_max|*/mtk-slave-charger/current_max|*/mtk-mst-div-chg/current_max|*/mtk-slv-div-chg/current_max) ;;
    *) return 1;;
  esac
  [ -f "$1" ] || return 1
  case "$(getprop ro.product.manufacturer 2>/dev/null)" in
    [Mm][Oo][Tt][Oo][Rr][Oo][Ll][Aa]*) ;;
    *) return 1;;
  esac
  ! cat "$1" >/dev/null 2>&1
}

mtk_current_flags() {
  local _mtk_name
  for _mtk_name in mtk-master-charger mtk-slave-charger mtk-mst-div-chg mtk-slv-div-chg; do
    mtk_current_flag "${1:-/sys/class/power_supply}/$_mtk_name/current_max" \
      && printf '%s\n' "${1:-/sys/class/power_supply}/$_mtk_name/current_max"
  done
  return 0
}

# Command nodes are not restoreable settings. Only re-detect a proven dead,
# low-voltage USB supply; an unknown reading must not destroy a working contract.
charge_redetect_safe() {
  local _p=${1:-/sys/class/power_supply} _f _v _i=
  [ ! -f /dev/.vr25/acc/.hvcontract ] || return 1
  [ ! -f /data/adb/vr25/acc-data/.rekick-off ] || return 1
  [ "$(cat "$_p/usb/present" 2>/dev/null)" = 1 ] ||
    [ "$(cat "$_p/usb/online" 2>/dev/null)" = 1 ] || return 1
  for _f in real_type usb_type type; do
    _v=$(cat "$_p/usb/$_f" 2>/dev/null)
    case $_v in *\[*\]*) _v=${_v#*\[}; _v=${_v%%\]*};; esac
    case $_v in *HVDCP*|*PD*|*QC*|*PPS*|*VOOC*|*WARP*|*DASH*|*SCP*|*hvdcp*|*pd*) return 1;; esac
  done
  _v=$(cat "$_p/usb/voltage_now" 2>/dev/null)
  case $_v in ''|*[!0-9]*) return 1;; esac
  [ "$_v" -gt 100000 ] && _v=$((_v / 1000))
  [ "$_v" -gt 0 ] && [ "$_v" -lt 5500 ] || return 1
  for _f in input_current_now current_now; do
    _i=$(cat "$_p/usb/$_f" 2>/dev/null); _i=${_i#-}
    case $_i in ''|*[!0-9]*) continue;; esac
    # power_supply current is in uA. Refuse ambiguous/missing sensors.
    [ "$_i" -le 50000 ] && return 0
    return 1
  done
  return 1
}
#/SQ#
export TMPDIR=/dev/.$domain/$id

# rc21: the uninstaller is the recovery backstop -- it must run even where busybox cannot be set up
# (bare recovery, no-busybox ROM, FBE). Its real work (rm -rf, echo>node, cat, grep, sed) uses only
# /system/bin builtins that exist on every Android, so a missing busybox must NOT abort it. This flag
# tells the shared busybox block below to warn-and-continue instead of `exit 3`. flock/timeout usage
# further down is guarded for the same reason.
BB_OPTIONAL=true

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
  # Self-healing fallbacks (kept in sync with install.sh): on roots/ROMs that stash
  # busybox elsewhere (KernelSU, APatch, MIUI, old Android) or where `--install -s`
  # symlinks into /dev are not honoured, cast a wider net before giving up. Additive:
  # only runs when the quick path above produced no usable applet.
  [ -x $busybox_dir/ls ] || {
    # `--install -s` (symlinks) -> `--install` (hardlinks/copies) -> manual applet
    # symlinks from `--list` (covers busybox AND toybox multicall binaries).
    _bb_try() {
      [ -x "$1" ] || return 1
      eval "$1" --install -s $busybox_dir/ 2>/dev/null || :
      [ -x $busybox_dir/ls ] && return 0
      eval "$1" --install $busybox_dir/ 2>/dev/null || :
      [ -x $busybox_dir/ls ] && return 0
      for _ap in $("$1" --list 2>/dev/null); do
        ln -sf "$1" "$busybox_dir/$_ap" 2>/dev/null || :
      done
      unset _ap
      [ -x $busybox_dir/ls ] && return 0
      return 1
    }
    for f in \
      $bin_dir/busybox \
      /data/adb/magisk/busybox \
      /data/adb/ksu/bin/busybox \
      /data/adb/ap/bin/busybox \
      /data/adb/*/bin/busybox \
      /data/adb/*/busybox \
      "$(command -v busybox 2>/dev/null || :)" \
      /system/xbin/busybox \
      /system/bin/busybox \
      /system/*bin/busybox* \
      /vendor/*bin/busybox* \
      "$(command -v toybox 2>/dev/null || :)" \
      /system/xbin/toybox \
      /system/bin/toybox \
      /system/*bin/toybox* \
    ; do
      _bb_try "$f" && break || :
    done
    # -f: _bb_try is a FUNCTION. Plain `unset` clears a VARIABLE of that name, which never
    # existed, so the helper stayed defined for everything that ran afterwards. This block is
    # the canonical copy: build.sh syncs it into install.sh, customize.sh, uninstall.sh and
    # both online installers, so it has to be fixed here, not in the generated copies.
    unset -f _bb_try 2>/dev/null || unset _bb_try 2>/dev/null || :
  }
  [ -x $busybox_dir/ls ] || {
    echo "ERROR: a usable busybox/toybox could not be found or installed."
    echo "Tried $bin_dir/, Magisk/KernelSU/APatch, and /system. Install busybox"
    echo "(or place a static busybox binary at $bin_dir/busybox)."
    echo
    # BB_OPTIONAL: callers that only need /system builtins (the uninstaller: rm/echo/cat exist
    # everywhere, even in a bare recovery with no busybox) set BB_OPTIONAL=true and continue instead
    # of aborting. The daemon/installer leave it unset, so busybox stays mandatory for them.
    ${BB_OPTIONAL:-false} && echo "-> BB_OPTIONAL set: continuing with /system tools (some steps limited)" || exit 3
  }
}
# rc23b: this tested the WRONG DIRECTORY, and it cost the switch scanner its daemon.
#
# $bin_dir is where a user MAY drop a static busybox; it is empty on both test phones. $busybox_dir
# is where the applets actually are, installed above. The guard existed to avoid prepending twice,
# but it asked "does $bin_dir already lead PATH?" -- so any caller that had prepended $bin_dir
# itself made this a no-op and $busybox_dir was never added at all.
#
# acc-switch-scan.sh does exactly that (`PATH=/data/adb/$domain/bin:$PATH`), to pick up a
# user-supplied busybox. The consequence was three lines away and invisible: the daemon is started
# by service.sh with `exec start-stop-daemon -bx $execDir/accd.sh -S`, start-stop-daemon is a
# BUSYBOX applet, and with $busybox_dir off PATH it is not found. service.sh exits 127 and the
# phone is left with no daemon and charging uncapped.
#
# Measured on a Mi A3, three interleaved rounds, no other difference: plain PATH restarts the
# daemon in 1 s, PATH with $bin_dir prepended never restarts it, and running service.sh by hand
# under that PATH prints
#   /dev/.vr25/acc/accd[48]: start-stop-daemon: inaccessible or not found
#
# Test $busybox_dir, which is the thing that has to be reachable, and anchor with colons so a
# directory whose name merely CONTAINS another cannot satisfy it.
case ":$PATH:" in
  *":$busybox_dir:"*) ;;
  *) export PATH="$bin_dir:$busybox_dir:$PATH";;
esac
unset f bin_dir busybox_dir magisk_busybox
#/BB#

exec 2>/dev/null

# terminate/kill $id processes
accd_pid() {
  case "${1:-}" in ''|0|1|*[!0-9]*) return 1;; esac
  local _script
  _script=$(readlink -f /data/adb/$domain/$id/${id}d.sh 2>/dev/null)
  [ -n "$_script" ] || _script=/data/adb/$domain/$id/${id}d.sh
  tr '\000' '\n' < "/proc/$1/cmdline" 2>/dev/null | grep -qxF \
    -e "/data/adb/$domain/$id/${id}d.sh" \
    -e "$_script" \
    -e "$TMPDIR/${id}d"
}
mkdir -p $TMPDIR 2>/dev/null || :
if command -v flock >/dev/null 2>&1; then
  (flock -n 0 || {
    pid=; read pid || :
    accd_pid "$pid" || pid=
    [ -z "$pid" ] || kill "$pid"
    timeout 10 flock 0
    [ -z "$pid" ] || { accd_pid "$pid" && kill -KILL "$pid" >/dev/null 2>&1; }
    timeout 10 flock 0
  }) <>$TMPDIR/${id}.lock
else
  # rc21: no flock (bare recovery / no-busybox env, see the non-fatal busybox block above) -- just
  # kill the daemon directly if it is running. In a cold recovery session there is no daemon at all,
  # so this is usually a no-op. The final flock above is now timeout-bounded so it can never hang.
  for _p in $(pgrep -f 'accd\.sh' 2>/dev/null); do accd_pid "$_p" && kill "$_p" 2>/dev/null; done
fi
# rc21: belt-and-suspenders. A boot-started daemon (via start-stop-daemon) can leave a SECOND accd
# process that the single-pid flock-kill above misses, so a no-reboot uninstall would leave it running
# (harmless -- its data dir is about to be removed, so it fail-safes to charging -- but not clean).
# Sweep any lingering accd: TERM first (lets its exit trap restore charging), brief grace, then KILL.
if command -v pgrep >/dev/null 2>&1; then
  for _p in $(pgrep -f 'accd\.sh' 2>/dev/null); do accd_pid "$_p" && kill "$_p" 2>/dev/null; done
  sleep 1
  for _p in $(pgrep -f 'accd\.sh' 2>/dev/null); do accd_pid "$_p" && kill -KILL "$_p" 2>/dev/null; done
fi

# uninstall
# D2: clean ACC's own tmp files but PRESERVE the acc-compat tester artifact -- acc-compat-verified
# is the tester->AccA handoff (a separate tool), not ACC's; the broad acc[-_]* glob used to wipe it.
for f in /data/local/tmp/${id}[-_]*; do
  [ -e "$f" ] || continue
  case "$f" in *compat*) continue;; esac
  # rc21: never delete an INSTALLER. The glob acc[-_]* matches the release archives
  # (acc_v2025.5.18-6.5.1-rc21_202505301.zip / .tgz) that people download and leave in
  # /data/local/tmp, so uninstalling ACC also deleted the file needed to install it again.
  # That hurts most in the one case it matters: a tester uninstalls to recover a phone,
  # then finds the zip gone. Caught by the clean-install reboot suite, which wiped its own
  # installer this way. Ours are only ever scripts and logs, so archives are never ours.
  case "$f" in *.zip|*.tgz|*.tar.gz|*.tar.bz2|*.apk) continue;; esac
  rm -rf "$f"
done
rm -rf \
  /data/adb/service.d/${id}-*.sh \
  /data/data/mattecarra.accapp/files/$id \
  /data/data/com.termux/files/home/.termux/boot/${id}-init.sh

[ "${1:-}" = install ] || {
  # restore normal charging before removal -- ENABLE direction only, can never overcharge.

  # rc20: hand Android's battery state back FIRST. The Capacity Mask works by writing that state
  # (`dumpsys battery set`), which also STOPS Android's own battery updates until a reset. Nothing
  # in the removal path undid it, so uninstalling while the mask was on left the phone showing a
  # frozen, made-up percentage (and "charging" after unplug) until the next reboot -- ACC gone,
  # symptom still there. Unconditional and harmless when no mask was ever set.
  /system/bin/dumpsys battery reset >/dev/null 2>&1 || :

  # Drop ACC's independent Google MSC_FCC ballot. This is deliberately NOT a force-value reset:
  # disabling only DEBUGFS leaves Android's thermal and charger votes untouched. A reboot clears
  # the ballot too, but no-reboot uninstall must restore full current immediately.
  _mfd=$TMPDIR/.debugfs/gvotables/MSC_FCC
  _mfm=$TMPDIR/.debugfs
  if [ -f /data/adb/$domain/${id}-data/.msc-fcc-debugfs-vote ]; then
    if [ ! -w "$_mfd/disable_vote" ]; then
      mkdir -p "$_mfm" 2>/dev/null || :
      chmod 0700 "$_mfm" 2>/dev/null || :
      mount -t debugfs debugfs "$_mfm" 2>/dev/null || :
    fi
    [ -w "$_mfd/disable_vote" ] && printf DEBUGFS > "$_mfd/disable_vote" 2>/dev/null || :
    rm -f /data/adb/$domain/${id}-data/.msc-fcc-debugfs-vote 2>/dev/null || :
  fi
  # Clearing the vote removes its marker but does not unmount debugfs. Also
  # detach nested mounts (e.g. tracing) before removing ACC's private mount.
  # Best-effort: this runs BEFORE the charge-node restore and the daemon is already dead,
  # so aborting here would leave the phone capped with nothing left to un-cap it.
  for _mount in $(awk -v p="$_mfm" '$2 == p || index($2, p "/") == 1 {print $2}' /proc/mounts | sort -r); do
    umount "$_mount" 2>/dev/null || umount -l "$_mount" 2>/dev/null       || echo "WARNING: cannot unmount $_mount; it stays mounted until the next reboot. Removal continues."
  done
  unset _mfd _mfm

  # (a0) rc13: CONFIG-DRIVEN restore FIRST -- replay ACC's own recorded stock values. The generic
  # sweeps below un-cap by hardcoded node names + a */voltage_max_design sibling, but that misses
  # (i) voltage_max nodes with NO _design sibling (battery/bms/main on curtana were left capped at
  # the user's mcv=4300mV -> "charging did not recover after uninstall", field report), (ii) nodes
  # OUTSIDE /sys/class/power_supply (e.g. /sys/class/qcom-battery/restrict_cur), and (iii) names not
  # in the list (input_current_settled). maxChargingCurrent/Voltage store each node as
  # node::ON::DEFAULT -- writing the DEFAULT restores the exact stock value ACC recorded when it
  # first capped, for EVERY node it touched, wherever it lives. Numeric defaults only (a "3600mV"
  # shorthand is skipped); done before the config is removed.
  _cfg=/data/adb/$domain/${id}-data/config.txt
  [ -f "$_cfg" ] || _cfg=$(readlink -f /data/adb/$domain/$id 2>/dev/null)/../${id}-data/config.txt
  if [ -f "$_cfg" ]; then
    for _key in maxChargingCurrent maxChargingVoltage; do
      _line=$(grep "^$_key=" "$_cfg" 2>/dev/null | head -1)
      [ -n "$_line" ] || continue
      # strip the key=( ... ) wrapper via sed: a bare '(' inside ${..#..} derails mksh's parser
      # (the device /system/bin/sh), though bash tolerates it.
      _line=$(printf '%s' "$_line" | sed -e 's/^[^(]*(//' -e 's/).*$//')
      for _tok in $_line; do
        case "$_tok" in *::*::*) ;; *) continue;; esac
        _node=${_tok%%::*}; _def=${_tok##*::}
        case "$_def" in ''|*[!0-9]*) continue;; esac
        case "$_node" in /*) ;; *) _node=/sys/class/power_supply/$_node;; esac
        mtk_current_flag "$_node" && _def=0
        [ -w "$_node" ] && echo "$_def" > "$_node" 2>/dev/null || :
      done
    done
    # rc21: also replay the recorded chargingSwitch's ON value to whatever node the daemon locked.
    # The ~20-name generic sweep below misses many vendor nodes (LG, Huawei, OPPO/OnePlus/Realme,
    # Xiaomi qcom-battery, Motorola force_charger_suspend, ...); the config records the EXACT node
    # ACC touched, so writing field-2 (ON) re-enables charging for it regardless of vendor. Works for
    # every class: cut ON=0, level ON=100, current ON=high. Numeric ON only; every triplet replayed.
    _sw=$(grep "^chargingSwitch=" "$_cfg" 2>/dev/null | head -1 | sed -e 's/^[^(]*(//' -e 's/).*$//')
    ( set -- $_sw
      while [ $# -ge 3 ] && [ -n "$1" ]; do
        _n=$1; _on=$2
        case "$_on" in ''|*[!0-9]*) shift 3; continue;; esac
        case "$_n" in /*) ;; *) _n=/sys/class/power_supply/$_n;; esac
        [ -w "$_n" ] && echo "$_on" > "$_n" 2>/dev/null || :
        shift 3
      done ) 2>/dev/null || :
    unset _key _line _tok _node _def _sw
  fi

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
    #      Only a proven dead 5V source may be re-detected; a live contract must survive removal.
    if charge_redetect_safe; then
      for f in */apsd_rerun */rerun_aicl; do
        [ -w "$f" ] && echo 1 > "$f" 2>/dev/null || :
      done
    fi
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
      # rc24: never the negotiation supplies. Writing usb/current_max renegotiates the port down to
      # ~100mA until the value is written back, so an uninstall left the phone trickle-charging.
      case "$f" in usb/*|dc/*|pc_port/*|tcpm*) continue;; esac
      if mtk_current_flag "$f"; then
        [ -w "$f" ] && echo 0 > "$f" 2>/dev/null || :
      else
        [ -w "$f" ] && echo 5000000 > "$f" 2>/dev/null || :
      fi
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

  # (c2) rc13: Qualcomm qcom-battery restrict family lives OUTSIDE /sys/class/power_supply, so the
  # sweeps above never reached it. restrict_chg=1 + a low restrict_cur throttles/stops charging
  # (curtana). Config-driven restore (a0) fixes the exact value; this is the generic fallback for a
  # corrupt/absent config: lift the restriction (chg off, current high -- kernel clamps).
  [ -w /sys/class/qcom-battery/restrict_chg ] && echo 0 > /sys/class/qcom-battery/restrict_chg 2>/dev/null || :
  [ -w /sys/class/qcom-battery/restrict_cur ] && echo 5000000 > /sys/class/qcom-battery/restrict_cur 2>/dev/null || :

  # remove EVERY ACC path: the module dir (resolved + explicit), KSU staging, the systemless tree,
  # the data dir, then the parent and the root-manager PATH symlinks (rc3).
  _resolved=$(readlink -f /data/adb/$domain/$id 2>/dev/null)
  # Custom installs also end in /acc. A damaged link must not delete its parent
  # or an unrelated directory.
  case "$_resolved" in /*/$id) rm -rf "$_resolved";; esac
  rm -rf \
    "/data/adb/modules/$id" \
    "/data/adb/modules_update/$id" \
    "/data/adb/$domain/$id" \
    "/data/adb/$domain/${id}-data"
  # ACC created this bin dir; it goes with ACC, unless another module of the
  # same domain is still installed and using it.
  case "$(ls -A "/data/adb/$domain" 2>/dev/null | grep -vxE 'bin|busybox')" in
    '') rm -rf "/data/adb/$domain/bin" "/data/adb/$domain/busybox";;
  esac
  rmdir "/data/adb/$domain" 2>/dev/null || :
  for b in /data/adb/ksu/bin /data/adb/ap/bin /su/bin /su/xbin /sbin; do
    for f in "$b/$id" "$b/${id}a" "$b/${id}d"; do
      case "$(readlink "$f" 2>/dev/null)" in /data/adb/$domain/$id/*|/dev/.$domain/$id/*) rm -f "$f";; esac
    done
  done
  # rc9: also remove the tmpfs work dir (TMPDIR=/dev/.$domain/$id). The block above only
  # cleared /data/adb/$domain/*, leaving /dev/.vr25/acc (stale .config/.cfg/locks) on a
  # no-reboot uninstall. Leave /dev/.$domain/busybox (shared) intact.
  rm -rf "$TMPDIR" 2>/dev/null || :

  # rc21: post-condition -- confirm the module is actually gone. On FBE/undecrypted /data (a recovery
  # flash before the PIN/pattern is entered) /data/adb is unreachable, so every rm above silently
  # no-ops and the script would otherwise exit 0 = "recovered" while the phone re-bricks on next boot.
  # Fail loudly with the actionable cause instead of a false success.
  if [ -e "/data/adb/modules/$id" ] || [ -e "/data/adb/$domain/$id" ] || [ -e "$(readlink -f /data/adb/$domain/$id 2>/dev/null)" ] 2>/dev/null; then
    echo
    echo "WARNING: ACC files are STILL PRESENT after removal -- nothing was actually removed."
    echo "  /data is most likely not decrypted (FBE) in this recovery session."
    echo "  Fix: in recovery, DECRYPT /data (enter your PIN/pattern), then re-flash this uninstaller;"
    echo "  or run it from a booted system:  su -c 'sh /data/adb/$domain/$id/uninstall.sh'"
    echo
    exit 1
  fi
}

exit 0
