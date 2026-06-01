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

# one-time: adopt the gentler default max_temp (50 -> 45 C; heat above ~45 ages the
# cell noticeably faster). Only changes a config still on the old default of 50, so a
# value you deliberately set is left untouched. Runs once.
[ -f $data_dir/.stable-defaults4 ] || {
  [ ! -f $config ] || sed -i 's/^\(temperature=([0-9]* \)50 /\145 /' $config 2>/dev/null || :
  touch $data_dir/.stable-defaults4 2>/dev/null || :
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
/data/adb/$domain/$id/service.sh --init


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
