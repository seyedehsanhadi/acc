#!/system/bin/sh
# $id Installer/Upgrader
# Copyright 2019-2024, VR25
# License: GPLv3+
#
# devs: triple hashtags (###) mark non-generic code


# override the official Magisk module installer
SKIPUNZIP=1
SKIPMOUNT=false


echo
id=acc
domain=vr25
data_dir=/data/adb/$domain/${id}-data


# log
[ -z "${LINENO-}" ] || export PS4='$LINENO: '
mkdir -p $data_dir/logs
exec 2>$data_dir/logs/install.log
set -x


exxit() {
  local e=$?
  set +eu
  rm -rf /dev/.$domain.${id}-install
  # rc6 (B3): a FAILED install (abort under set -eu) used to leave charging cut -- the upgrade
  # path runs `uninstall.sh install`, which kills the daemon and deliberately SKIPS charging-
  # restore (mid-upgrade). If a later copy/perm step then aborts there is no daemon AND no
  # restore = battery stuck not charging until reboot. On any nonzero exit re-enable charging
  # (ENABLE direction only -- can never overcharge), mirroring the uninstaller's restore sweep.
  [ $e -eq 0 ] || {
    if cd /sys/class/power_supply 2>/dev/null; then
      for _f in */charging_enabled */battery_charging_enabled */charge_enabled */charging_enable */enable_charging */enable_charger; do
        [ -w "$_f" ] && echo 1 > "$_f" 2>/dev/null || :
      done
      for _f in */input_suspend */batt_slate_mode */op_disable_charge */charge_disable */disable_charging; do
        [ -w "$_f" ] && echo 0 > "$_f" 2>/dev/null || :
      done
      for _f in */apsd_rerun */rerun_aicl; do
        [ -w "$_f" ] && echo 1 > "$_f" 2>/dev/null || :
      done
      cd / 2>/dev/null || :
    fi
  }
  $KSU || {
    rm -rf /data/adb/modules_update/$id
    (abort) > /dev/null
  }
  echo
  exit $e
} 2>/dev/null

trap exxit EXIT


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
case ":$PATH:" in
  *":$busybox_dir:"*) ;;
  *) export PATH="$bin_dir:$busybox_dir:$PATH";;
esac
unset f bin_dir busybox_dir magisk_busybox
#/BB#


# root check
[ $(id -u) -ne 0 ] && {
  echo "$0 must run as root (su)"
  exit 4
}


get_prop() { sed -n "s|^$1=||p" ${2:-$srcDir/module.prop}; }

set_perms() {
  local owner=${2:-0}
  local perms=0644
  local target=
  target=$(readlink -f $1)
  if echo $target | grep -q '.*\.sh$' || [ -d $target ]; then perms=0755; fi
  chmod $perms $target
  chown $owner:$owner $target
  chcon u:object_r:system_file:s0 $target 2>/dev/null || :
}

set_perms_recursive() {
  local owner=${2-0}
  local target=
  find $1 2>/dev/null | while read target; do set_perms $target $owner; done
}

set -eu


# set source code directory
srcDir="$(cd "${0%/*}" 2>/dev/null || :; echo "$PWD")"

# extract flashable zip if source code is unavailable
[ -d $srcDir/install ] || {
  srcDir=/dev/.$domain.${id}-install
  rm -rf $srcDir 2>/dev/null || :
  mkdir $srcDir
  unzip "${APK:-${ZIPFILE:-$3}}" -d $srcDir/ >&2
}


name=$(get_prop name)
author=$(get_prop author)
version=$(get_prop version)
magiskModDir=/data/adb/modules
versionCode=$(get_prop versionCode)
accaFiles=/data/data/mattecarra.accapp/files ###
: ${installDir:=$accaFiles} ###
config=$data_dir/config.txt


# install in front-end's internal path by default
if [ "$installDir" != "$accaFiles" ]; then
  case "$installDir" in
    /data/data/*|/data/user/*)
      accaFiles="$installDir"
    ;;
  esac
fi


[ -d $magiskModDir ] && magisk=true || magisk=false
ls -d ${accaFiles%/*}* > /dev/null 2>&1 && acca=true || acca=false ###


# ensure AccA's files/ exists - to prevent unwanted downgrades ###
if $acca && [ ! -d $accaFiles ]; then
  if mkdir $accaFiles 2>/dev/null; then
    chown $(stat -c %u:%g ${accaFiles%/*}) $accaFiles
    chmod $(stat -c %a ${accaFiles%/*}) $accaFiles
    /system/bin/restorecon $accaFiles
  fi
fi


# check/change parent installation directory
! $magisk || installDir=$magiskModDir
[ $installDir != /data/adb/$domain ] || mkdir -p $installDir
[ -d $installDir ] || {
  installDir=/data/adb/$domain
  mkdir -p $installDir
}


###
echo "$name $version ($versionCode)
Copyright 2017-2024, $author
GPLv3+

Installing in $installDir/$id/..."


# backup
rm -rf $data_dir/backup 2>/dev/null || :
mkdir -p $data_dir/backup
cp -aH /data/adb/$domain/$id/* $config $data_dir/backup/ 2>/dev/null || :


export KSU=${KSU:-false}
$KSU || { [ -d /data/adb/ksu ] || [ -d /data/adb/ap ] || [ -f /data/adb/ksu/bin/busybox ] || [ -f /data/adb/ap/bin/busybox ]; } && KSU=true || :   # rc6 (B2): match KSU/APatch bin ONLY, not the wildcard /data/adb/*/bin/busybox that also hit ACC's own vr25/bin (mis-flagged KSU on Magisk + 2+-match `[ -f a b ]` breakage)

# rc17: HOW does this root manager mount a module's system/ dir? It decides whether shipping one
# is harmless or bricks the phone -- $magisk above only means "/data/adb/modules exists", which is
# equally true on KernelSU and APatch, so it must NOT be used for this.
#   Magisk            magic mount, per FILE. /system/bin/acc is added and every other file in
#                     /system/bin keeps its own label. Safe.
#   KernelSU (incl. Next / SukiSU / ReSukiSU), APatch, Magisk + magisk_overlayfs
#                     OverlayFS, per DIRECTORY. A module system/ relabels the WHOLE merged
#                     /system/bin: /system/bin/sh stops being shell_exec and every app and system
#                     process that shells out dies with "Exec '/system/bin/sh' failed: Permission
#                     denied" -- the root manager itself will not open and only recovery can undo
#                     it (GitHub #197).
# FAIL SAFE: treat anything not positively confirmed as Magisk magic mount as OverlayFS. A phone
# that merely lacks the `acc` PATH shortcut still boots; a phone with a poisoned /system/bin does
# not. This also makes a recovery flash safe, where no root manager exports its env at all.
overlayMount=true
# rc21: POSITIVE OverlayFS detection -- the physical cause of #197, immune to root-manager env AND to
# Magisk residue. The heuristic below can be defeated: /data/adb/magisk survives switching to KSU/
# APatch, and MAGISK_VER_CODE is exported (fixed values) by KSU and APatch too, so "just switched root
# manager, ran the installer by hand before the ksu/ap dir exists" could wrongly enable the overlay and
# brick. So first ask the kernel directly: is /system (or /system/bin) an `overlay` mount? On any
# OverlayFS root (KSU/KSU-Next/SukiSU/APatch/magisk_overlayfs) it is; Magisk magic-mount shows tmpfs
# (fstype `magisk`) there, never `overlay` (calibrated on a live Magisk device), so real Magisk is never
# mis-flagged. If /proc/mounts is unreadable this simply falls through to the heuristic -- strictly
# additive, never less safe. A false-positive only costs the `acc` PATH shortcut (phone still boots).
# A system-as-root device (and some APatch setups) mounts the overlay at "/" rather than at
# /system, so anchoring only on /system misses it and the detection silently degrades to the
# rc20 heuristic. Match "/" as well. Read with the shell rather than awk: this runs before the
# busybox PATH prepend is guaranteed, and a missing awk here would turn the probe into a silent
# "not an overlay" on exactly the phones it was added to protect.
systemIsOverlay=false
while read -r _mdev _mpt _mfs _mrest; do
  [ "$_mfs" = overlay ] || continue
  case "$_mpt" in /system|/system/*|/) systemIsOverlay=true; break;; esac
done < /proc/mounts 2>/dev/null
if $systemIsOverlay; then
  overlayMount=true
elif ! $KSU \
  && [ -z "${APATCH:-}" ] \
  && [ ! -d /data/adb/ap ] \
  && [ ! -d /data/adb/ksu ] \
  && [ ! -d $magiskModDir/magisk_overlayfs ] \
  && { [ -d /data/adb/magisk ] || [ -n "${MAGISK_VER_CODE:-}" ]; }
then
  overlayMount=false
fi
$overlayMount && echo "Root: OverlayFS-mounted (KernelSU/APatch/overlayfs). system/ overlay disabled - prevents the #197 /system/bin brick." \
             || echo "Root: Magisk magic mount. system/ overlay enabled (acc on PATH)."
/system/bin/sh $srcDir/install/uninstall.sh install
mkdir -p $installDir/$id
cp -R $srcDir/install/* $installDir/$id/
installDir=$(readlink -f $installDir/$id)
cp $srcDir/module.prop $installDir/
# rc17: the AMPS engine (acc-compat.sh / amps.sh -- the same engine under two names) lives at the
# package ROOT, not under install/, so the `cp -R $srcDir/install/*` above never shipped it. A phone
# flashing a NEW ACC therefore kept executing whatever engine it already had (an A3 running rc17 was
# still on the v7.1.3 engine, three versions stale), and a clean flash got none at all -- only the
# tarball path ever carried it. Copy the current engine on every install.
for _e in acc-compat.sh amps.sh; do
  [ -f "$srcDir/$_e" ] && cp -f "$srcDir/$_e" "$installDir/$_e" || :
done

# The test suite, for exactly the same reason and with exactly the same consequence.
#
# suites/ also lives at the package ROOT, so `cp -R $srcDir/install/*` never shipped it either. Every
# suite defaults to $execDir/suites, which meant a flashed module could not test itself: the copies
# on the two development phones had only ever arrived by hand, and a fresh install got none. That
# hides regressions in the most direct way possible - the checks that would catch them are absent -
# and it made a stale on-device t64 pass with wording from a version that had already been fixed.
#
# Removed first, so a suite deleted upstream does not linger on a phone and fail forever.
# A test run that died mid-arm leaves /data/local/tmp/.mega2-arm-installed behind, and P0 refuses to
# run while it exists. Installing the module is precisely the act that makes that marker stale, so
# clear it here rather than leaving a dead file to block the next run - it cost one full test cycle.
rm -f /data/local/tmp/.mega2-arm-installed 2>/dev/null || :

[ -d "$srcDir/suites" ] && {
  rm -rf "$installDir/suites" 2>/dev/null
  cp -R "$srcDir/suites" "$installDir/" 2>/dev/null
  chmod -R 755 "$installDir/suites" 2>/dev/null
} || :
cp -f $srcDir/README.* $data_dir/


# one-time migration for EXISTING configs, so no manual command is needed (runs once,
# marker-guarded; never clobbers a deliberate later choice):
#  - ensure allow_idle_above_pcap is on (hold/charge in range, not forced discharge);
#  - upgrade a locked "charge_stop_level pcap pcap" (froze the battery -- writing the
#    limit value never re-arms the charger) or "... pcap 5" (drained to ~70) to
#    "... 100 pcap" (ON=100 resumes, OFF=limit stops), so a locked config charges again.
[ -f $data_dir/.stable-defaults3 ] || {
  [ ! -f $config ] || {
    sed -i 's/^allowIdleAbovePcap=false$/allowIdleAbovePcap=true/' $config 2>/dev/null || :
    sed -i 's/charge_stop_level pcap pcap/charge_stop_level 100 pcap/g; s/charge_stop_level pcap 5/charge_stop_level 100 pcap/g' $config 2>/dev/null || :
  }
  touch $data_dir/.stable-defaults3 2>/dev/null || :
}

# one-time (stable.5): repair a temperature band left degenerate by stable.4. That release
# lowered max_temp 50 -> 45, which collapsed it onto cooldown_temp (both 45). cooldown_temp is
# where the gentle cooldown cycle STARTS and max_temp is the hard pause; when they are equal the
# cooldown loop enters and instantly breaks at max_temp, so it never throttles. Restore the
# proven upstream max_temp of 50 (band: cooldown 45 < max 50). Only the exact collapsed
# signature "(45 45 " is touched; a band you set yourself is left alone. Runs once.
[ -f $data_dir/.stable-defaults5 ] || {
  [ ! -f $config ] || sed -i 's/^\(temperature=(45 \)45 /\150 /' $config 2>/dev/null || :
  touch $data_dir/.stable-defaults5 2>/dev/null || :
}

# Pixel/Tensor (e.g. Android 16) cannot truly bypass: idle-above-pcap "succeeds" in status
# while charging continues, so the limit was overshot. Hard-pause instead, so the current-
# verified auto-lock can lock the working current-limit switch (e.g. usb/current_max ... 0).
# Only on devices exposing google,charger; runs once.
[ -f $data_dir/.stable-defaults6 ] || {
  { [ -e /sys/devices/platform/google,charger/charge_stop_level ] && [ -f $config ]; } && \
    sed -i 's/^allowIdleAbovePcap=true$/allowIdleAbovePcap=false/; s/^prioritizeBattIdleMode=true$/prioritizeBattIdleMode=no/' $config 2>/dev/null || :
  touch $data_dir/.stable-defaults6 2>/dev/null || :
}

# Re-run of the Tensor hard-pause migration under a FRESH marker. On-device (Pixel 9a,
# Android 16) the .stable-defaults6 pass did not stick -- some configs still carried
# allowIdleAbovePcap=true / prioritizeBattIdleMode=true, so the daemon kept trying
# idle/bypass at the limit (faking "stopped" while current still flowed) and never
# hard-paused. Forcing both off here lets the current-verified auto-lock fall through to
# the all-paths current-cut group, which actually stops charging on these multi-charge-path
# SoCs. New marker so it applies even on installs that already ran the stale .6 block. Only
# on devices exposing google,charger; runs once; fully guarded.
[ -f $data_dir/.stable-defaults7 ] || {
  { [ -e /sys/devices/platform/google,charger/charge_stop_level ] && [ -f $config ]; } && \
    sed -i 's/^allowIdleAbovePcap=true$/allowIdleAbovePcap=false/; s/^prioritizeBattIdleMode=true$/prioritizeBattIdleMode=no/' $config 2>/dev/null || :
  touch $data_dir/.stable-defaults7 2>/dev/null || :
}


# rc(6.3.3): undo a bad 6.3.2 lock. 6.3.2 could auto-migrate an MTK device onto current_cmd,
# which on some kernels (e.g. klee/HyperOS) PASSES the quick scan check but does NOT actually
# hold the limit -> OVERCHARGE. current_cmd is no longer promoted (input_suspend, which holds,
# is preferred again), so clear any switch 6.3.2 LOCKED onto current_cmd; the daemon then
# re-scans and re-locks input_suspend. One-shot, MTK-only, idempotent; never leaves it uncapped
# (an empty switch re-scans on the next charge). Non-MTK / non-current_cmd locks untouched.
[ -f $data_dir/.mtk-currentcmd-revert ] || {
  { [ -e /proc/mtk_battery_cmd/current_cmd ] && [ -f $config ]; } && \
    sed -i 's|^chargingSwitch=(.*mtk_battery_cmd/current_cmd.*--.*)$|chargingSwitch=()|' $config 2>/dev/null || :
  touch $data_dir/.mtk-currentcmd-revert 2>/dev/null || :
}


# KaiOS patches
[ ! -d /data/usbmsc_mnt/ ] || {
  for i in $installDir/$id/*.sh; do
    sed -Ei 's#/sdcard(/|/Download/)#/data/usbmsc_mnt/#g' $i
  done
}


tmpd=/dev/.$domain/$id
mkdir -p $tmpd


###
# rc17: only a magic-mount root gets the system/ overlay. On OverlayFS roots it is never created
# in the first place (acc/acca/accd reach PATH via /data/adb/{ksu,ap}/bin instead, below).
! $magisk || $overlayMount || {

  # create executable wrappers to avoid rebooting unnecessarily
  mkdir -p $installDir/system/bin

  for i in ${id}.sh:$id ${id}.sh:${id}d, ${id}.sh:${id}d. ${id}a.sh:${id}a service.sh:${id}d; do
    j=$installDir/system/bin/${i#*:}
    [ ! -h $j ] || rm $j
    echo "#!/system/bin/sh
#exec_wrapper
if [ -f $tmpd/.updated ]; then
  exec /dev/${i#*:} \"\$@\"
else
  exec . /data/adb/$domain/$id/${i%:*} \"\$@\"
fi" > $j
  done
}


###
if $acca; then

  ! $magisk || {

    ln -fs $installDir $accaFiles/

    # ACC is a STANDALONE module -- do NOT tie its lifecycle to the AccA app. Older
    # builds dropped a service.d cleanup script that DELETED ACC (and the daemon) when
    # AccA was uninstalled. Remove any leftover so uninstalling the AccA app never
    # removes ACC: the daemon and your limits keep working without the front-end.
    rm -f /data/adb/service.d/${id}-cleanup.sh 2>/dev/null || :
  }
fi


[ $installDir = /data/adb/$domain/$id ] || {
  mkdir -p /data/adb/$domain
  # rc21: /data/adb/$domain/$id is the canonical path everything else resolves through --
  # the root manager's bin symlinks, service.d, AccA and the user's own `acc` command. When
  # /data/adb/modules did NOT exist at first install (common on KernelSU, where the dir only
  # appears once a module is present) ACC installed straight into /data/adb/$domain/$id as a
  # REAL directory. Every later upgrade then installs into /data/adb/modules/$id and tries to
  # redirect -- but `ln -sf` cannot replace a real directory with a symlink. It prints
  # "Is a directory", exits 0, and the phone silently keeps running the FIRST version ever
  # installed. Device-proven: two rc21 installs on a KernelSU Pixel 6a, `acc -v` still rc20.
  # Move the stale directory aside, link, verify the link actually resolves to this install,
  # and on failure roll back and say so instead of exiting 0 on a broken upgrade.
  if [ -e /data/adb/$domain/$id ] && [ ! -L /data/adb/$domain/$id ]; then
    rm -rf /data/adb/$domain/$id.stale 2>/dev/null || :
    mv -f /data/adb/$domain/$id /data/adb/$domain/$id.stale 2>/dev/null || :
  fi
  rm -f /data/adb/$domain/$id 2>/dev/null || :
  ln -sf $installDir /data/adb/$domain/$id 2>/dev/null || :
  # `-d $link/` follows the symlink, so a DANGLING link fails it. readlink -f alone does not:
  # it happily resolves a link whose target does not exist, so on its own it would report
  # success, delete the rollback copy and leave the phone with a broken path and no install.
  if [ -L /data/adb/$domain/$id ] && [ -d /data/adb/$domain/$id/ ] \
    && [ "$(readlink -f /data/adb/$domain/$id 2>/dev/null)" = "$(readlink -f $installDir 2>/dev/null)" ]; then
    rm -rf /data/adb/$domain/$id.stale 2>/dev/null || :
  else
    [ ! -d /data/adb/$domain/$id.stale ] || {
      rm -rf /data/adb/$domain/$id 2>/dev/null || :
      mv -f /data/adb/$domain/$id.stale /data/adb/$domain/$id 2>/dev/null || :
    }
    echo "! Could not point /data/adb/$domain/$id at this install ($installDir)."
    echo "! The previous version is still in place. Uninstall ACC, reboot, then install again."
  fi
}


# install binaries
cp -f $srcDir/bin/${id}_flashable_uninstaller.zip $data_dir/


# Termux, fix shebang
termux=false
case "$installDir" in
  */com.termux*)
    termux=true
    for f in $installDir/*.sh; do
      ! grep -q '^#\!/.*/sh' $f \
        || sed -i 's|^#!/.*/sh|#!/data/data/com.termux/files/usr/bin/bash|' $f
    done
  ;;
esac


# set perms
case $installDir in
  /data/data/*|/data/user/*)
    set_perms_recursive $installDir $(stat -c %u ${installDir%/$id})

    # Termux:Boot
    ! $termux || {
      mkdir -p ${installDir%/*}/.termux/boot
      ln -sf $installDir/service.sh ${installDir%/*}/.termux/boot/${id}-init.sh
      chown -R $(stat -c %u:%g /data/data/com.termux) ${installDir%/*}/.termux
      /system/bin/restorecon -R ${installDir%/*}/.termux > /dev/null 2>&1 || :
    }
  ;;
  *)
    set_perms_recursive $installDir
    chmod 0755 $installDir/system/bin/* 2>/dev/null || :
  ;;
esac


# rc17: PREVENTION + RESCUE. On every OverlayFS root, guarantee the module carries no system/
# tree -- neither a fresh one nor a poisonous one left behind by an older install. This is what
# makes flashing this build enough to UN-BRICK a phone that is already stuck: from recovery it
# strips the overlay in place, so the next boot has a clean /system/bin and no uninstall is
# needed. skip_mount is the belt to that braces: even if a stale system/ somehow survives, the
# root manager is told never to mount it. Runs BEFORE the module is staged, so no copy can carry
# the overlay back. Covers the live dir and MODPATH (the staged dir the manager applies on boot).
! $overlayMount || {
  for d in $installDir ${MODPATH:-}; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    rm -rf "$d"/system 2>/dev/null || :
    : > "$d"/skip_mount 2>/dev/null || :
  done
}

# Magisk magic mount WANTS the overlay: clear a skip_mount left by a previous KernelSU/APatch
# install so `acc` on PATH is not silently lost after switching root manager.
$overlayMount || {
  rm -f $installDir/skip_mount 2>/dev/null || :
  [ -z "${MODPATH:-}" ] || rm -f "$MODPATH"/skip_mount 2>/dev/null || :
}

! $KSU || {
  upModDir=${magiskModDir}_update
  rm -rf $upModDir/$id 2>/dev/null || :
  # $installDir/update tells the root manager "a staged copy is ready in modules_update". It was
  # written unconditionally, so when the copy failed -- no modules_update dir, no space, read-only
  # -- the marker still claimed a staged update existed and the next boot went looking for one
  # that was never written. Mark only what actually landed. Deliberately no mkdir of $upModDir:
  # if the root manager did not create it, there is nothing to stage into.
  # $upModDir must already exist. toybox `cp -a src missing/` does NOT fail: it silently creates
  # `missing` AS the copy, so on a device with no modules_update this built a bogus tree whose
  # contents sat directly in modules_update/ instead of modules_update/$id, exited 0, and got
  # marked as a staged update the root manager would then fail to find.
  [ -d $upModDir ] && cp -a $installDir $upModDir/ 2>/dev/null && touch $installDir/update || :
}


# KernelSU/APatch: expose acc on a bin that's already on PATH, pointing at the stable
# install path so the plain `acc` command works immediately -- no reboot/overlay wait (B7).
! $KSU || {
  for kbin in /data/adb/ksu/bin /data/adb/ap/bin; do
    [ -d $kbin ] || continue
    ln -sf /data/adb/$domain/$id/${id}.sh $kbin/$id 2>/dev/null || :
    ln -sf /data/adb/$domain/$id/${id}a.sh $kbin/${id}a 2>/dev/null || :
    ln -sf /data/adb/$domain/$id/service.sh $kbin/${id}d 2>/dev/null || :
  done
}


set +eu
printf "Done\n\n\n"


# print links and changelog
sed -En "\|^## LINKS|,\$p" $srcDir/README.md \
  | grep -v '^---' | sed 's/^## //'

printf "\n\nCHANGELOG\n\n"
cat $srcDir/changelog.md


_echo() {
  echo "$@" | tee -a $tmpd/.install-notes
}


printf "\n\n"
printf "$version ($versionCode) installed!\n\nRollback with acc -b if not satisfied.\n\n" | tee $tmpd/.install-notes
if [ -x /sbin/${id}d ] || grep -q '#exec_wrapper' /system/bin/${id}d 2>/dev/null; then
  _echo "Rebooting is unnecessary."
elif $KSU; then
  _echo "KernelSU/APatch: the 'acc' command works now via /data/adb/ksu/bin (or /data/adb/ap/bin). If your build lacks that dir, use the absolute path /data/adb/$domain/$id/acc.sh, or reboot once. AccA works either way."
else
  _echo "Note: If you're not rebooting now, prefix all acc executables with /dev/ (as in /dev/acc -i, /dev/accd). Reasoning: Magisk, KernelSU and similar, don't [re]mount/update modules without a reboot."
fi


case $installDir in
  /data/adb/modules*) ;;
  *) $KSU || echo "
Non-Magisk users can enable $id auto-start by running /data/adb/$domain/$id/service.sh, a copy of, or a link to it - with init.d or an app that emulates it.";;
esac


# initialize $id
rm $data_dir/disable 2>/dev/null

# Start the daemon. service.sh's last line is `exec start-stop-daemon ... || exit 12`,
# so on roots/ROMs lacking start-stop-daemon (a common cause of install reports) the
# daemon would simply never come up. We are running under `set +eu` here, so a failure
# cannot abort the install -- but a non-running daemon defeats the install, so guard it:
# run the normal init when start-stop-daemon exists, otherwise reproduce the same setup
# and launch accd.sh detached via setsid/nohup (the exact fallback acca.sh already uses).
if command -v start-stop-daemon >/dev/null 2>&1; then
  /data/adb/$domain/$id/service.sh --init || \
    echo "Note: service.sh --init returned nonzero; see $data_dir/logs/install.log"
else
  echo "Note: start-stop-daemon not found; starting $id daemon via setsid/nohup fallback."
  (
    set +eu
    id=$id
    domain=$domain
    execDir=/data/adb/$domain/$id
    dataDir=$data_dir
    TMPDIR=/dev/.$domain/$id
    mkdir -p $TMPDIR $dataDir 2>/dev/null || :
    export dataDir domain execDir id TMPDIR
    [ ! -f $execDir/setup-busybox.sh ] || . $execDir/setup-busybox.sh 2>/dev/null || :
    [ ! -f $execDir/release-lock.sh ] || . $execDir/release-lock.sh 2>/dev/null || :
    if command -v setsid >/dev/null 2>&1; then
      setsid $execDir/${id}d.sh --init </dev/null >/dev/null 2>&1 &
    else
      nohup $execDir/${id}d.sh --init </dev/null >/dev/null 2>&1 &
    fi
  ) || echo "Note: daemon fallback launch failed; see $data_dir/logs/install.log"
fi

# ...and then CHECK, because neither branch above can fail the install.
#
# service.sh exits 12 when the daemon never comes up, and that was caught by an `echo` into the
# install log -- which nobody reads -- followed by an unconditional `exit 0`. Magisk printed a
# clean success over a module that was enforcing nothing, which is the "install looked fine and it
# charged to 100% overnight" report this check exists to end.
#
# Deliberately NOT exit 1: Magisk treats a nonzero installer as a failed install and drops the
# module, taking the user's config with it, and late_start normally brings the daemon up on the
# next boot anyway. Losing the module is the worse outcome. So say so, loudly, where the user is
# actually looking.
_acc_up=false
for _i in 1 2 3 4 5 6 7 8 9 10; do
  if [ -f /dev/.$domain/$id/acc.lock ] || pgrep -f "$id"d.sh >/dev/null 2>&1; then _acc_up=true; break; fi
  sleep 1
done
if $_acc_up; then
  ui_print "- Daemon is running"
else
  ui_print ""
  ui_print "  ****************************************"
  ui_print "  * WARNING: the $id daemon did NOT start *"
  ui_print "  ****************************************"
  ui_print "  Your charging limit is NOT being enforced yet."
  ui_print "  REBOOT NOW - it normally starts on boot."
  ui_print "  If it still does not, send $data_dir/logs/install.log"
  ui_print ""
  echo "install: daemon not running after install; warned the user" >> $data_dir/logs/install.log 2>/dev/null || :
fi


# magic_overlayfs support

OVERLAY_IMAGE_EXTRA=0     # number of kb need to be added to overlay.img
OVERLAY_IMAGE_SHRINK=true # shrink overlay.img or not?

# only use OverlayFS if Magisk_OverlayFS is installed
if [ -f "/data/adb/modules/magisk_overlayfs/util_functions.sh" ] && \
    /data/adb/modules/magisk_overlayfs/overlayfs_system --test; then
  ui_print ""
  ui_print "- Add support for overlayfs"
  . /data/adb/modules/magisk_overlayfs/util_functions.sh
  support_overlayfs && [ -n "${MODPATH:-}" ] && rm -rf "$MODPATH"/system   # rc6 (B1): guard MODPATH -- it is only set when Magisk sources customize.sh; a standalone `sh install.sh` left it unset, so this was `rm -rf /system`
fi

exit 0
