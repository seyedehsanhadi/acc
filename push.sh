#!/usr/bin/env sh
# Push and Install Zip
# Copyright 2022-2024, VR25
# License: GPLv3+
#
# usage: $0 [k] [adb device]
# k is for KaiOS

id=$(sed -n "s/^id=//p" module.prop)
# Read module.prop, not the first line of changelog.md. That line is the document TITLE
# ("# ACC - Advanced Charging Controller"), not a release entry, so this derived version="#" and
# versionCode="ACC - Advanced Charging Controller" and then looked for a build that cannot exist.
# module.prop is what build.sh names the artifact from, so it is the only correct source.
version=$(sed -n "s/^version=//p" module.prop)
versionCode=$(sed -n "s/^versionCode=//p" module.prop)
zip=${id}_${version}_$versionCode
zip=$(echo _builds/$zip/$zip*zip)
dest=/sdcard/Download/acc.zip

[ ".${1-}" != .k ] || {
  dest=/data/usbmsc_mnt/acc.zip
  shift
}

one=${1-}

_adb() {
  if [ -n "${one-}" ]; then
    adb -s $one "$@"
  else
    adb "$@"
  fi
}

if _adb shell su -c "which apd >/dev/null"; then
  install="apd module install $dest"
elif _adb shell su -c "which ksud >/dev/null"; then
  install="ksud module install $dest"
elif _adb shell su -c "which magisk >/dev/null"; then
  install="magisk --install-module $dest"
else
  install=
fi

[ -z "$install" ] || _adb push $zip $dest && _adb shell su -c "$install" || :
