#!/system/bin/sh
# acca: acc for front-ends (faster and more efficient than acc)
# Copyright 2020-2024, VR25
# License: GPLv3+


at() { :; }

online() { :; }


daemon_ctrl() {
  case "${1-}" in
    start|restart)
      # Detach so the daemon survives a transient caller. A bare `exec accd` leaves
      # accd in the caller's session/process-group; when that caller is a one-shot
      # script (e.g. the switch scanner run from a front-end), accd dies the moment
      # the script exits -- leaving charging UNCAPPED. Launch it in its own session.
      if command -v setsid >/dev/null 2>&1; then
        setsid $TMPDIR/accd $config </dev/null >/dev/null 2>&1 &
      elif command -v start-stop-daemon >/dev/null 2>&1; then
        start-stop-daemon -bx $execDir/accd.sh -S -- $config >/dev/null 2>&1
      else
        nohup $TMPDIR/accd $config </dev/null >/dev/null 2>&1 &
      fi
      exit 0
    ;;
    stop)
      . $execDir/release-lock.sh
      exit 0
    ;;
    *)
      flock -n 0 <>$TMPDIR/acc.lock && exit 9 || exit 0
    ;;
  esac
}


# condensed "case...esac"
eq() {
  eval "case \"$1\" in
    $2) return 0;;
  esac"
  return 1
}


set -eu

execDir=/data/adb/vr25/acc
dataDir=/data/adb/vr25/acc-data
: ${config:=$dataDir/config.txt}
defaultConfig=$execDir/default-config.txt

export TMPDIR=/dev/.vr25/acc
export verbose=false

cd /sys/class/power_supply/
. $execDir/setup-busybox.sh

mkdir -p $dataDir

# custom config path
! eq "${1-}" "*/*" || {
  [ -f $1 ] || cp $config $1
  config=$1
  shift
}

# wait for accd initialization
[ -f $TMPDIR/.batt-interface.sh ] || {
  for i in $(seq 35); do
    [ -f $TMPDIR/.batt-interface.sh ] && break || sleep 2
  done
  unset i
}


case "$@" in

  # check daemon status
  -D*|--daemon*)
    daemon_ctrl ${2-}
  ;;

  # print charging info
  -i*|--info*)
    . $config
    . $execDir/android.sh
    . $execDir/batt-interface.sh
    . $execDir/batt-info.sh
    batt_info "${2-}" | grep -v '^$' 2>/dev/null || :
    exit 0
  ;;


  # set multiple properties
  -s\ *=*|--set\ *=*)

    # Apply synchronously. accd re-reads config.txt on every loop, so the writer
    # does not need to be detached. The old `setsid $0 ...` re-exec silently
    # no-opped the write whenever setsid was missing (common on minimal busybox
    # -- the write returned 127 before write-config ran), and `exec 4<>$0`
    # failed on read-only module dirs. Writing here directly is robust and gives
    # front-ends (AccA) a real exit code.
    shift

    # Best-effort serialization of concurrent writers; never fatal. Locks a
    # tmpfs file (always writable, never $0), and is skipped cleanly when flock
    # is unavailable.
    if command -v flock >/dev/null 2>&1; then
      exec 9>"$TMPDIR/.acca-set.lock" && flock -w 5 9 2>/dev/null || :
    fi

    . $defaultConfig
    . $config

    export "$@"

    . $execDir/write-config.sh
    exit 0
  ;;


  # print default config
  -s\ d*|-s\ --print-default*|--set\ d*|--set\ --print-default*|-sd*)
    [ $1 = -sd ] && shift || shift 2
    . $defaultConfig
    one="${1//,/|}"
    . $execDir/print-config.sh ns | grep -E "${one:-.}" | sed 's/^$//' || :
    exit 0
  ;;

  # print current config
  -s\ p*|-s\ --print|-s\ --print\ *|--set\ p|--set\ --print|--set\ --print\ *|-sp*)
    [ $1 = -sp ] && shift || shift 2
    . $config
    one="${1//,/|}"
    . $execDir/print-config.sh | grep -E "${one:-.}" | sed 's/^$//' || :
    exit 0
  ;;

esac


# other acc commands
set +eu
[ "${2:-x}" != q ] && exec $TMPDIR/acc $config "$@" \
  || {
    export logF=$TMPDIR/.logf
    $TMPDIR/acc $config "$@" >/dev/null
    case $? in
      0) echo Ok;;
      15) echo Idle;;
      *) echo Fail;;
    esac
    return $?
  }
