#!/system/bin/sh
# $id initializer
# Copyright 2017-2021, VR25
# License: GPLv3+

id=acc
domain=vr25
TMPDIR=/dev/.$domain/$id
execDir=/data/adb/$domain/$id
dataDir=/data/adb/$domain/${id}-data

[ -f $execDir/disable -o -f $dataDir/disable ] && exit 14

# wait til the lock screen is ready and give some bootloop grace period
slept=false
_bootwait=0
# rc6 (S2): also exit the wait when the framework reports boot complete. On ROMs where
# init.svc.bootanim never reads "stopped" the old loop burned the full 30x10s=5min before starting,
# leaving charging uncontrolled for minutes after every reboot. Cap lowered to 18x10s=3min too.
until [ .$(getprop init.svc.bootanim 2>/dev/null) = .stopped ] \
   || [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] \
   || [ $_bootwait -ge 18 ]; do
  [ -f $execDir/disable -o -f $dataDir/disable ] && exit 14
  sleep 10 && slept=true
  _bootwait=$((_bootwait + 1))
done
unset _bootwait
$slept && sleep 60
unset slept

mkdir -p $TMPDIR $dataDir
export dataDir domain execDir id TMPDIR
. $execDir/setup-busybox.sh
. $execDir/release-lock.sh
[ ".$1" = .-x ] && touch $dataDir/disable
exec start-stop-daemon -bx $execDir/${id}d.sh -S -- "$@" || exit 12
