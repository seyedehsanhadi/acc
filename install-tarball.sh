#!/system/bin/sh
# ${1:-$id} Tarball Installer
# Copyright 2019-2022, VR25
# License: GPLv3+
#
# this file must be in the same directory as the tarball
# $1: module id
# $2: parent install dir, optional
# example: sh install-tarball.sh acc /data/data/github.vr25.acc/files

id=acc
domain=vr25
data_dir=/data/adb/$domain/${1:-$id}-data

# log
[ -z "${LINENO-}" ] || export PS4='$LINENO: '
mkdir -p $data_dir/logs
exec 2>$data_dir/logs/install-tarball.sh.log
set -x

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
    unset _bb_try
  }
  [ -x $busybox_dir/ls ] || {
    echo "ERROR: a usable busybox/toybox could not be found or installed."
    echo "Tried $bin_dir/, Magisk/KernelSU/APatch, and /system. Install busybox"
    echo "(or place a static busybox binary at $bin_dir/busybox)."
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

set -e

# get into the target directory
[ -f $PWD/${0##*/} ] || cd $(readlink -f ${0%/*})

# this runs on exit if the installer is launched by a front-end app
copy_log() {
  rm -rf ${1-$id}[-_]*/ 2>/dev/null
  case "$PWD" in
    /data/data/*|/data/user/*)
      mkdir -p logs
      cp -af $data_dir/logs/install.log logs/${1:-$id}-install.log 2>/dev/null || return 0
      chown -R $(stat -c %u:%g .) logs
      /system/bin/restorecon -R logs
    ;;
  esac
}
trap copy_log EXIT

# extract tarball
rm -rf ${1:-$id}[-_]*/ 2>/dev/null
test -f ${1:-$id}[-_]*.tar.gz && ext=tar.gz || ext=tgz
tar -xf ${1:-$id}[-_]*.$ext
unset ext

# prevent frontends from downgrading/reinstalling modules
case "$PWD" in
  /data/data/*|/data/user/*)
    get_ver() { sed -n '/^versionCode=/s/.*=//p' ${1}module.prop 2>/dev/null || echo 0; }
    bundled_ver=$(get_ver ${1:-$id}[-_]*/)
    regular_ver=$(get_ver /data/adb/$domain/${1:-$id}/)
    if [ $bundled_ver -le $regular_ver ] && [ $regular_ver -ne 0 ]; then
      ln -s $(readlink -f /data/adb/$domain/${1:-$id}) .
      exit 0
    fi 2>/dev/null || :
  ;;
esac

# install ${1:-$id}
export installDir="$2"
/system/bin/sh ${1:-$id}[-_]*/install.sh

exit 0
