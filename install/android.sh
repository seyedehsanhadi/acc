is_android() {
  [ ! -d /data/usbmsc_mnt/ ] && [ -x /system/bin/dumpsys ] \
    && [[ "$(readlink -f $execDir)" != *com.termux* ]] \
    && pgrep -f zygote >/dev/null
}


# dumpsys wrappers

if is_android; then

  dumpsys() { /system/bin/dumpsys "$@" || :; }

  dsys_batt() {
    # rc21: guard $1. Called bare (logf's `dsys_batt > dumpsys-battery.txt`, which wants the
    # plain battery dump) this tripped set -u with "1: parameter not set" and aborted the whole
    # export, so `acc -le` reported failure and produced no log tarball at all. The bare call is
    # meant to fall through to the else branch: the case below has no catch-all, so no override
    # marker is touched and no battery state is frozen, and `dumpsys battery "$@"` with no
    # arguments is exactly the dump that was wanted. Every other caller passes get/set/reset/
    # unplug and is unaffected.
    if [ "${1-}" = get ]; then
      dumpsys battery | sed -n "s/^  $2: //p"
    else
      # rc20 CRITICAL: track whether Android's battery state is currently OVERRIDDEN by us.
      # Any set/unplug stops Android's own battery updates (UPDATES STOPPED) until a reset,
      # which freezes the reported level, plug state and temperature. The daemon's cleanup
      # (loop + exit trap) gates on THIS marker, so every caller is covered - the capacity
      # mask, the cooldown cycle, the charge-once helper, and anything added later.
      # rc19 gated that cleanup on the mask marker alone, so the cooldown cycle's own
      # `set ac 1` was never undone: Android stayed frozen, the level stopped advancing, and
      # because batt_cap prefers Android's level the charging limit could never fire -> the
      # battery ran to 100% (field report on a OnePlus, rc19). Marker-in-the-wrapper makes
      # "who froze it" impossible to get wrong.
      case ${1-} in
        set|unplug) [ -z "${TMPDIR-}" ] || touch $TMPDIR/.dsys-override 2>/dev/null || :;;
        reset) [ -z "${TMPDIR-}" ] || rm -f $TMPDIR/.dsys-override 2>/dev/null || :;;
      esac
      dumpsys battery "$@"
    fi
  }

else

  dsys_batt() { :; }

  dumpsys() { :; }
  ! ${isAccd:-false} || {
    chgStatusCode=0
    dischgStatusCode=0
  }

fi
