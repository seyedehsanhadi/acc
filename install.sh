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

  # Self-healing fallbacks: many install failures (e.g. issues #215 #216 #222 #223
  # #228 #247) are just "busybox not found" on roots/ROMs that stash it elsewhere
  # (KernelSU, APatch, MIUI, old Android) or whose `--install -s` symlinks are not
  # honoured under /dev. Only if the quick path above produced no usable applet do
  # we cast a much wider net before giving up. Everything here is additive: it never
  # runs when the original loop already succeeded.
  [ -x $busybox_dir/ls ] || {

    # try `--install -s` (symlinks), then `--install` (hardlinks/copies, for setups
    # where symlinks into /dev fail), then -- last resort -- manually symlink the
    # applets the binary reports, for multicall binaries lacking a working --install.
    _bb_try() {
      [ -x "$1" ] || return 1
      eval "$1" --install -s $busybox_dir/ 2>/dev/null || :
      [ -x $busybox_dir/ls ] && return 0
      eval "$1" --install $busybox_dir/ 2>/dev/null || :
      [ -x $busybox_dir/ls ] && return 0
      # manual applet linking (works for busybox AND toybox multicall binaries)
      for _ap in $("$1" --list 2>/dev/null); do
        ln -sf "$1" "$busybox_dir/$_ap" 2>/dev/null || :
      done
      unset _ap
      [ -x $busybox_dir/ls ] && return 0
      return 1
    }

    # Widest candidate set, most-trusted first. Globs that match nothing simply
    # expand to a non-existent path and are skipped by the -x test in _bb_try.
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
    unset _bb_try
  }

  [ -x $busybox_dir/ls ] || {
    echo "ERROR: a usable busybox/toybox could not be found or installed."
    echo "Tried $bin_dir/, Magisk/KernelSU/APatch, and /system. Install busybox"
    echo "(or place a static busybox binary at $bin_dir/busybox) and retry."
    echo "Details: $data_dir/logs/install.log"
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
$KSU || { [ ! -f /data/adb/*/bin/busybox ] || KSU=true; }
/system/bin/sh $srcDir/install/uninstall.sh install
mkdir -p $installDir/$id
cp -R $srcDir/install/* $installDir/$id/
installDir=$(readlink -f $installDir/$id)
cp $srcDir/module.prop $installDir/
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
! $magisk || {

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
  ln -sf $installDir /data/adb/$domain/
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


! $KSU || {
  upModDir=${magiskModDir}_update
  rm -rf $upModDir/$id 2>/dev/null || :
  cp -a $installDir $upModDir/
  touch $installDir/update
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
printf "$version ($versionCode) installed and running!\n\nRollback with acc -b if not satisfied.\n\n" | tee $tmpd/.install-notes
if [ -x /sbin/${id}d ] || grep -q '#exec_wrapper' /system/bin/${id}d 2>/dev/null; then
  _echo "Rebooting is unnecessary."
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


# magic_overlayfs support

OVERLAY_IMAGE_EXTRA=0     # number of kb need to be added to overlay.img
OVERLAY_IMAGE_SHRINK=true # shrink overlay.img or not?

# only use OverlayFS if Magisk_OverlayFS is installed
if [ -f "/data/adb/modules/magisk_overlayfs/util_functions.sh" ] && \
    /data/adb/modules/magisk_overlayfs/overlayfs_system --test; then
  ui_print ""
  ui_print "- Add support for overlayfs"
  . /data/adb/modules/magisk_overlayfs/util_functions.sh
  support_overlayfs && rm -rf "$MODPATH"/system
fi

exit 0
