#!/system/bin/sh
# acca: acc for front-ends (faster and more efficient than acc)
# Copyright 2020-2024, VR25
# License: GPLv3+


at() { :; }

online() { :; }


# Same tmpfs bootstrap acc.sh does: $TMPDIR/accd is a symlink created by accd.sh's own init, so
# losing $TMPDIR leaves both front-ends unable to launch the daemon that would rebuild it. The
# start-stop-daemon branch below already calls $execDir/accd.sh directly and is unaffected; the
# setsid and nohup branches go through the symlink. execDir is persistent. Idempotent.
ensure_tmpdir_links() {
  _eti="${id:-acc}"
  [ -e "$TMPDIR/${_eti}d" ] && [ -e "$TMPDIR/$_eti" ] \
    && [ -e "$TMPDIR/${_eti}a" ] && return 0
  mkdir -p "$TMPDIR" 2>/dev/null || :
  ln -fs "$execDir/service.sh" "$TMPDIR/${_eti}d" 2>/dev/null || :
  ln -fs "$execDir/${_eti}.sh" "$TMPDIR/$_eti" 2>/dev/null || :
  ln -fs "$execDir/${_eti}a.sh" "$TMPDIR/${_eti}a" 2>/dev/null || :
}

daemon_ctrl() {
  case "${1-}" in
    start|restart)
      ensure_tmpdir_links
      # `start` MUST NOT TEAR DOWN A LIVE DAEMON. $TMPDIR/accd is service.sh, and service.sh runs
      # `. release-lock.sh` before it launches - which is what makes `restart` work here at all,
      # but it also made `start` a restart. Measured on a Pixel 6a: a healthy daemon at PID 23059
      # was killed and replaced on a bare `acca -D start`, leaving a gap in charge control that
      # nothing asked for. acc.sh has always refused this case (print_already_running, return 8);
      # acca is the front-end AccA drives, and it did not. Exit 0 rather than 8: the caller asked
      # for a running daemon and there is one, so this is success, not an error to surface.
      #
      # Confirm the PID by its exact daemon-script command line. Do not probe the flock here:
      # persistent root shells can inherit an fd for the same lock and make `flock -n` report it
      # available while the named daemon is healthy. That race made `start` kill and replace a
      # live daemon on laurus. A stale/reused PID cannot pass the exact command-line check.
      if [ "${1-}" = start ]; then
        _dcp=$(cat $TMPDIR/acc.lock 2>/dev/null || echo)
        case "${_dcp:-x}" in
          ''|*[!0-9]*) : ;;
          *)
            if [ -r /proc/$_dcp/cmdline ] \
              && tr '\0' ' ' < /proc/$_dcp/cmdline 2>/dev/null | grep -Fq "$execDir/${id:-acc}d.sh"; then
              exit 0
            fi
          ;;
        esac
      fi
      # Detach so the daemon survives a transient caller. A bare `exec accd` leaves
      # accd in the caller's session/process-group; when that caller is a one-shot
      # script (e.g. the switch scanner run from a front-end), accd dies the moment
      # the script exits -- leaving charging UNCAPPED. Launch it in its own session.
      # RELEASE HERE, not only inside service.sh. Two of the three launches below reach the daemon
      # through $TMPDIR/accd, which is service.sh, and service.sh sources release-lock.sh before it
      # starts anything - that is what makes a restart a restart. The start-stop-daemon branch does
      # NOT: it runs $execDir/accd.sh directly, so nothing releases the lock, the new daemon dies on
      # `flock -n 0 || exit 13` in acquire-lock, and the old one carries on. On that branch, and
      # only on that branch, `restart` really was the silent no-op this was once reported to be.
      #
      # Doing it here covers all three branches and does not depend on which one a phone takes.
      # Harmless where service.sh releases again: release-lock is a pkill plus an unlink, both
      # idempotent. Guarded on `restart` because `start` above has already established there is no
      # live daemon to release.
      [ "${1-}" = restart ] && . $execDir/release-lock.sh || :
      if command -v setsid >/dev/null 2>&1; then
        setsid $TMPDIR/accd $config </dev/null >/dev/null 2>&1 &
      elif command -v start-stop-daemon >/dev/null 2>&1; then
        start-stop-daemon -bx $execDir/accd.sh -S -- $config >/dev/null 2>&1
      else
        nohup $TMPDIR/accd $config </dev/null >/dev/null 2>&1 &
      fi
      # DO NOT REPORT SUCCESS BEFORE THERE IS A DAEMON. acca backgrounds service.sh and exited at
      # once, so AccA was told "started" while the lock was still unheld - the UI then shows "not
      # running" for a moment and recovers on its own, which reads as a failed restart. Wait for the
      # lock to be taken, briefly. Returns as soon as it is (measured under 2s on both phones), and
      # gives up rather than hanging: the launch has already happened either way, and a front-end
      # that blocks is worse than one that answers a little early.
      #
      # OBSERVE the lock, never TAKE it. `flock -n 0 <>acc.lock` - the form the status branch below
      # uses - acquires the lock for as long as flock runs. Polling with it here would put this
      # front-end in a race with the daemon it just launched, and the loser of that race is accd,
      # which exits 13 in acquire-lock and leaves the phone with no daemon at all. Read the PID the
      # daemon writes into the lock file instead: no contention, and it is the same evidence.
      _dcw=0
      while [ $_dcw -lt 10 ]; do
        _dcp=$(cat $TMPDIR/acc.lock 2>/dev/null || echo)
        case "${_dcp:-x}" in
          ''|*[!0-9]*) : ;;
          *) [ -d /proc/$_dcp ] && exit 0 || : ;;
        esac
        sleep 1
        _dcw=$((_dcw + 1))
      done
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
# Same fix as misc-functions.sh: the pattern must be eval'd, the value must not.
# Interpolating $1 into the eval'd string meant `acca '$(cmd)'` ran cmd as root.
eq() {
  _eqv=$1
  eval "case \"\$_eqv\" in
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
# The parse test, the safe source and the value check that acc.sh gets from misc-functions.sh and
# set-prop.sh. acca is the front-end AccA drives, so it needs them more than acc.sh does, and it
# had none of them: three bare `. $config` under set -eu, and an -s branch that reaches
# write-config.sh without ever passing a value through set_prop's guards.
# Degrade rather than die if the file is missing. acca runs under `set -eu`, so a bare `.` of an
# absent file kills the process -- and an upgrade that did not fully refresh the module directory
# would then break every AccA call, with `acca -s` exiting 127 on an undefined cfg_check_kv. The
# fallbacks reproduce the pre-guard behaviour exactly: no parse test, a plain source, no value
# check. Worse than having the guards, far better than a front-end that cannot run.
if [ -f $execDir/cfg-guard.sh ]; then
  . $execDir/cfg-guard.sh
else
  cfg_parses() {
    [ -f "$1" ] || return 1
    for _cfpsh in /system/bin/sh /system/xbin/sh /bin/sh; do
      [ -x "$_cfpsh" ] || continue
      "$_cfpsh" -n "$1" 2>/dev/null || return 1
      return 0
    done
    return 0
  }
  cfg_srcsafe() {
    case $- in
      *e*) set +e; . "$1" 2>/dev/null; set -e;;
      *) . "$1" 2>/dev/null || :;;
    esac
  }
  cfg_check_kv() { return 0; }
fi

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
    cfg_parses "$config" && cfg_srcsafe "$config" || :
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
    # Parse-safe. A truncated config is a PARSE error in mksh: it aborts the process before any
    # `||` can act, so `acca -s` died on exactly the file a user runs it to repair. The defaults
    # are already loaded, so a malformed file leaves those in place and the write below repairs it.
    if cfg_parses "$config"; then
      cfg_srcsafe "$config"
    elif [ -f "$config" ]; then
      # THE CONFIG EXISTS AND WILL NOT PARSE. Overlaying nothing leaves the DEFAULTS loaded from
      # the line above, and the write at the end of this branch then puts them ON DISK -- so one
      # AccA toggle silently reset every unrelated setting the user had.
      #
      # Device-proven on a Pixel 6a: a single `acca -s language=en` against a truncated config
      # turned temperature=(29 34 24 55) into (45 50 40 55), uiRefresh=42 into 60, and put the
      # charge limit back to the shipped default. Nothing was logged and AccA reported success.
      #
      # REFUSE, rather than guess. .config-good is a snapshot and can predate the very edit being
      # repaired, so restoring it still changes settings the user did not touch -- right for the
      # daemon, which must keep enforcing something, wrong for an interactive write that can just
      # report the problem. A file we cannot read is not a file we may replace. A genuinely
      # MISSING config still falls through with the defaults loaded, which is the first-run
      # repair this branch was written for.
      echo "config.txt is unreadable; refusing to overwrite it. Fix or remove it, then retry." >&2
      exit 1
    fi

    # rc24: assign without export, so a value is taken literally - no re-expansion, no word
    # splitting - and only a real config key can be written.
    # Validate EVERY pair before assigning any of them, with the same rule set-prop.sh applies to
    # `acc -s`. Without it write-config silently clamped an out-of-range capacity to 80 and dropped
    # a non-numeric one, and this branch exits 0, so AccA showed a success tick over a value the
    # user never asked for. Checked in a first pass so a rejected pair cannot leave a half-applied
    # write behind.
    for _as; do
      cfg_check_kv "$_as" || exit $?
    done

    # KEYS THAT DRIVE HARDWARE NODES MUST GO THROUGH THE SETTERS, and this branch has none.
    #
    # Everything below writes the CONFIG and nothing else: assign, write-config.sh, exit 0. That is
    # correct for a value the daemon reads back on its next loop, and wrong for the three keys whose
    # effect lives in sysfs. acc -s routes those through set-prop.sh, which calls set_ch_curr,
    # set_ch_volt and set_temp_level; acca -s never did, so the two front-ends disagreed on what
    # "set" means -- and AccA drives acca.
    #
    # Device-proven on a Mi A3. `acca -s mcv=` left the config reading maxChargingVoltage=() while
    # battery/voltage_max and main/voltage_max stayed pinned at 4150000 against a 4400000 default.
    # A 4.15V ceiling holds that pack near 70%, it survived a clear, an unplug and a reboot, and
    # NOTHING in the config or the UI said so -- the release path was simply never reached. Under
    # `sh -x` the trace showed the array being cleared and the branch returning with set_ch_volt
    # never called at all.
    #
    # Delegating to acc.sh rather than sourcing the setters here keeps ONE implementation of the
    # apply/release rules instead of a second copy to drift. It costs a heavier front-end only for
    # these three keys; every other key keeps the fast path below.
    for _as; do
      case "${_as%%=*}" in
        mcv|max_charging_voltage|maxChargingVoltage|\
        mcc|max_charging_current|maxChargingCurrent|\
        tl|temp_level|tempLevel)
          ensure_tmpdir_links
          # ${id:-acc}, not ${id}: acca.sh never sets id (ensure_tmpdir_links uses ${id:-acc} for the
          # same reason), and under set -eu a bare ${id} aborts the whole front-end before write-config
          # runs - which looked like the delegation doing nothing at all.
          exec $TMPDIR/${id:-acc} $config -s "$@"
        ;;
      esac
    done
    for _as; do
      case "$_as" in
        *=*) _ak=${_as%%=*}; _av=${_as#*=}
          case "$_ak" in *[!a-zA-Z0-9_]*) continue;; esac
          eval "$_ak=\$_av" ;;
      esac
    done
    unset _as _ak _av

    . $execDir/write-config.sh
    exit 0
  ;;


  # print default config
  -s\ d*|-s\ --print-default*|--set\ d*|--set\ --print-default*|-sd*)
    # The glob accepts a glued filter (-sdcapacity), so the shift must handle one. It used to test
    # for exactly -sd and otherwise `shift 2`, which under set -eu aborts on a single argument:
    # "acca.sh: shift: nothing to shift". Measured exit 1 for -sdcapacity, 0 for '-sd capacity'.
    case "$1" in
      -sd)   shift;;
      -sd?*) set -- "${1#-sd}";;
      *)     [ $# -ge 2 ] && shift 2 || shift;;
    esac
    . $defaultConfig
    one="${1-}"; one="${one//,/|}"   # rc7 (F7): guard unset $1 -- after the shift, `acca -s p` / `-s d` with no filter left $1 unset, and `${1//,/|}` aborts under set -u (the app's "show config" refresh hard-fails)
    . $execDir/print-config.sh ns | grep -E "${one:-.}" | sed 's/^$//' || :
    exit 0
  ;;

  # print current config
  -s\ p*|-s\ --print|-s\ --print\ *|--set\ p|--set\ --print|--set\ --print\ *|-sp*)
    # Same defect as the -sd branch above; see the note there.
    case "$1" in
      -sp)   shift;;
      -sp?*) set -- "${1#-sp}";;
      *)     [ $# -ge 2 ] && shift 2 || shift;;
    esac
    cfg_parses "$config" && cfg_srcsafe "$config" || :
    one="${1-}"; one="${one//,/|}"   # rc7 (F7): guard unset $1 -- after the shift, `acca -s p` / `-s d` with no filter left $1 unset, and `${1//,/|}` aborts under set -u (the app's "show config" refresh hard-fails)
    . $execDir/print-config.sh | grep -E "${one:-.}" | sed 's/^$//' || :
    exit 0
  ;;

esac


# other acc commands
set +eu
ensure_tmpdir_links
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
