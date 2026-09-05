#!/system/bin/sh
#
# $id Online Installer
# https://raw.githubusercontent.com/seyedehsanhadi/$id/$commit/install-online.sh
#
# Copyright 2019-2024, VR25
# License: GPLv3+
#
# Usage: sh install-online.sh [-c|--changelog] [-f|--force] [-n|--non-interactive]
#                            [-k|--insecure] [%parent install dir%] [commit]
#
# -k/--insecure disables TLS certificate verification. It is OFF by default. This script
# downloads a tarball and runs its installer AS ROOT, with no checksum and no signature, so an
# unverified transport hands a network attacker root on the device. It used to be unconditional:
# curl always got --insecure and wget always got --no-check-certificate. The opt-out remains for
# the case it was presumably there for, a device whose clock or CA store makes verification fail,
# but it now has to be asked for.


set +x
echo
id=acc
domain=vr25
data_dir=/data/adb/$domain/${id}-data

# log
[ -z "${LINENO-}" ] || export PS4='$LINENO: '
mkdir -p $data_dir/logs
set -x &>$data_dir/logs/install-online.sh.log

trap 'e=$?; echo; exit $e' EXIT


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


# root check
[ $(id -u) -ne 0 ] && {
  echo "$0 must run as root (su)"
  exit 4
}


set -eu
get_ver() { sed -n 's/^versionCode=//p' ${1:-}; }


! test -f /data/adb/vr25/bin/curl || {
  test -x /data/adb/vr25/bin/curl \
    || chmod -R 0755 /data/adb/vr25/bin
}


case " $* " in *" -k "*|*" --insecure "*) insecure=true;; *) insecure=false;; esac

if $insecure; then
  _k_curl=--insecure; _k_wget=--no-check-certificate
  echo "WARNING: TLS certificate verification is DISABLED for this download." >&2
else
  _k_curl=; _k_wget=
fi

set_dl() {
  if [ ".${1-}" != .wget ] && i=$(which curl) && [ ".$(head -n 1 ${i:-//} 2>/dev/null || :)" != ".#!/system/bin/sh" ]; then
    curl --help | grep '\-\-dns\-servers' >/dev/null && dns="--dns-servers 9.9.9.9,1.1.1.1" || dns=
    _curl() {
      curl $dns --progress-bar ${_k_curl} -L "$@" || { set_dl wget; _curl "$@"; }
    }
  else
    _curl() {
      shift $(($# - 1))
      PATH=${PATH#*/busybox:} /dev/.vr25/busybox/wget -O - ${_k_wget} $1
    }
  fi
}

set_dl

# -k/--insecure was missing from this strip list, so passing it made it the BRANCH NAME.
commit=$(echo "$*" | sed -E 's/%.*%|-c|--changelog|-f|--force|-n|--non-interactive|-k|--insecure| //g')
# The default was "master". This repository has main and dev; it has never had a master, local
# or remote, so every no-argument install requested a tarball URL that does not exist.
: ${commit:=main}

tarball=https://github.com/seyedehsanhadi/$id/archive/${commit}.tar.gz

installedVersion=$(get_ver /data/adb/$domain/$id/module.prop 2>/dev/null || :)

onlineVersion=$(_curl https://raw.githubusercontent.com/seyedehsanhadi/$id/${commit}/module.prop | get_ver)


[ -f $PWD/${0##*/} ] || cd $(readlink -f ${0%/*})
[ -z "${reference-}" ] || cd /dev/.$domain/$id
rm -rf "./${id}-*/" 2>/dev/null || :


if [ ${installedVersion:-0} -lt ${onlineVersion:-0} ] \
  || case "$*" in *-f*|*--force*) true;; *) false;; esac
then

  ! echo "$@" | grep -Eq '\-\-changelog|\-c' || {
    if echo "$@" | grep -Eq '\-\-non-interactive|\-n'; then
      echo $onlineVersion
      echo "https://github.com/seyedehsanhadi/$id/blob/${commit}/changelog.md"
      exit 5 # no update available
    else
      echo
      print_available $id $onlineVersion 2>/dev/null \
        || echo "$id $onlineVersion is available"
      print_install_prompt 2>/dev/null \
        || echo -n "- Download and install? ([enter]: yes, CTRL-C: no) "
      read REPLY
    fi
  }

  # download and install tarball
  : ${installDir:=$(echo "$@" | sed -E "s/-c|--changelog|-f|--force|-n|--non-interactive|%|$commit| //g")}
  export installDir
  set +eu
  trap - EXIT
  echo
  # A failed download, a truncated archive and a failed installer all used to reach the `exit 0` at
  # the end of this script, so `acc -u -f` could report success having installed nothing. The
  # pipeline status was tar's, not curl's, so stage the tarball to a file and check each step.
  _tb=$data_dir/.update.$$.tgz
  if ! _curl $tarball > $_tb || [ ! -s $_tb ]; then
    rm -f $_tb 2>/dev/null
    echo "UPDATE FAILED: could not download $tarball" >&2
    exit 7
  fi
  if ! tar -xzf $_tb; then
    rm -f $_tb 2>/dev/null
    echo "UPDATE FAILED: the downloaded archive did not extract" >&2
    exit 7
  fi
  rm -f $_tb 2>/dev/null
  _src=$(ls -d ${id}-*/ 2>/dev/null | head -1)
  if [ -z "$_src" ] || [ ! -f "$_src/install.sh" ]; then
    echo "UPDATE FAILED: the archive contained no installer" >&2
    exit 7
  fi
  if ! ash "$_src/install.sh"; then
    echo "UPDATE FAILED: the installer exited non-zero; the existing install was left alone" >&2
    exit 8
  fi

else
  echo
  print_no_update 2>/dev/null || echo "No update available"
  exit 6
fi


set -eu
rm -rf "./${id}-*/" 2>/dev/null
exit 0
