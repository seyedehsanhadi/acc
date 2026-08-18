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

# rc14: reaching late_start_service means boot got far enough to NOT be a bootloop, so clear the
# post-fs-data early-cap's strike counter. This is what keeps the 3-strike self-heal from ever
# tripping in normal use -- it only accumulates across boots that never make it here.
rm -f $dataDir/.early-boot-count 2>/dev/null || :

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
# rc21: archive the PREVIOUS boot's reboot evidence (pstore/bootreason) to a persistent rolling log, so
# a reboot stays debuggable whenever the user later collects diagnostics -- pstore/last_kmsg are single-
# slot and wiped each boot, logcat too. Backgrounded + timeboxed so it can never delay the daemon start.
# rc22: -k, or the box is not a box. The payload is a shell sitting in a child, and mksh DEFERS
# SIGTERM until that child returns -- on toybox 0.8.0 (Mi A3) the 8s limit measured 30s and the
# archiver outlived the boot. An undeferrable SIGKILL 3s later closes it on every device.
[ -f $execDir/reboot-archive.sh ] && ( timeout -k 3 8 sh $execDir/reboot-archive.sh >/dev/null 2>&1 & ) 2>/dev/null || :
[ ".$1" = .-x ] && touch $dataDir/disable
# VERIFY, do not assume. start-stop-daemon FORKS and only then execs, so its exit code reports the
# fork, not the daemon. A field report from a SuperSU tarball install showed service.sh exiting 0
# with no daemon and nothing logged; reproduced here as accd.sh at mode 0644, where the exec fails
# inside a child nobody is watching. Measured: 3/3 starts at 0755, 0/3 at 0644, exit 0 in both.
# This was `exec ... || exit 12`, and the exec is precisely what made the failure unobservable -
# it replaced the shell, so no check could run afterwards. Dropping it costs one short-lived
# process and turns a silent no-charge-limit into a self-repair.
start-stop-daemon -bx $execDir/${id}d.sh -S -- "$@" 2>/dev/null || :

_svcw=0
while [ $_svcw -lt 10 ]; do
  pgrep -f "$execDir/${id}d.sh" >/dev/null 2>&1 && exit 0
  sleep 1
  _svcw=$((_svcw + 1))
done

# Nothing came up. Repair the one cause seen in the field, then launch without the applet at all:
# `/system/bin/sh <script>` does not need the executable bit, so it works even if the chmod is
# refused. The interpreter is spelled out: setup-busybox.sh has put busybox ahead of /system/bin on
# PATH by this point, and busybox ash cannot parse accd.sh (mksh arrays, line 518) - measured as
# "syntax error: unexpected (" and no daemon, on both phones.
chmod 0755 $execDir/${id}d.sh 2>/dev/null || :
if command -v setsid >/dev/null 2>&1; then
  setsid /system/bin/sh $execDir/${id}d.sh "$@" </dev/null >/dev/null 2>&1 &
else
  nohup /system/bin/sh $execDir/${id}d.sh "$@" </dev/null >/dev/null 2>&1 &
fi

_svcw=0
while [ $_svcw -lt 15 ]; do
  pgrep -f "$execDir/${id}d.sh" >/dev/null 2>&1 && exit 0
  sleep 1
  _svcw=$((_svcw + 1))
done
exit 12
