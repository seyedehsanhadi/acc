# Config guards shared by every front-end and by the daemon.
#
# These three rules were each implemented in one place and missing from another, and in every case
# the path that missed them is the one AccA actually drives:
#
#   cfg_parses    accd's _srccfg and oem-custom.sh judged a config by SOURCING it and reading the
#                 exit status. srccfg_try had already been fixed to parse instead, for reasons
#                 measured on a Mi A3 and a Pixel 6a; the daemon kept the old form, where a false
#                 negative DELETES .config-good or overwrites the user's config with the defaults.
#   cfg_srcsafe   mksh does not honour `|| :` for a failure inside a dot-sourced file, so under
#                 set -e an ordinary config ending in a failing rule killed the caller outright.
#   cfg_check_kv  set-prop.sh refuses an out-of-range capacity and an array key. acca.sh's -s
#                 branch has its own assignment loop that reaches write-config.sh directly, so a
#                 value AccA sends was clamped by write-config and reported back as a success.
#
# Kept in its own file, not in misc-functions.sh, because acca.sh is the minimal front-end -- it is
# what AccA and the daemon call, many times a minute -- and must not parse 1700 lines to get three
# functions.

# Does this file PARSE? Parse-only; the file is never executed.
#
# The interpreter MUST be an absolute path: acc.sh runs with a PATH that does not always resolve a
# bare `sh` (early-cap.log records "sh: sh: No such file or directory"), and a bare `sh -n` that
# fails to EXEC is indistinguishable from a parse error, which would condemn every config. With no
# interpreter at all, say yes: wrongly rejecting a good config is worse than not catching a bad
# one, and every caller already tolerates a failed source.
cfg_parses() {
  [ -f "$1" ] || return 1
  for _cfpsh in /system/bin/sh /system/xbin/sh /bin/sh; do
    [ -x "$_cfpsh" ] || continue
    "$_cfpsh" -n "$1" 2>/dev/null || return 1
    return 0
  done
  return 0
}

# Source a file without letting its exit status abort the caller. Restores errexit exactly as it
# was, so a caller that never enabled it is left unchanged.
cfg_srcsafe() {
  case $- in
    *e*) set +e; . "$1" 2>/dev/null; set -e;;
    *) . "$1" 2>/dev/null || :;;
  esac
}

# Parse-and-validate one key=value before it can reach write-config.sh. Returns 2 and explains on
# stderr when the value must not be written; 0 when it may.
#
# write-config clamps anything outside the documented ranges to 80 and drops a non-numeric value
# entirely, so without this the number on screen is not the number in force and nothing says so.
# Measured on a Mi A3 running rc22, with the front-end reporting success every time:
#
#     acc -s pause_capacity=999  ->  exit 0, prints the tick, stores 80
#     acc -s pause_capacity=101  ->  exit 0, prints the tick, stores 80
#     acc -s pause_capacity=abc  ->  exit 0, prints the tick, stores 75
#
# A non-numeric pause capacity also moved shutdown_capacity to 0, so garbage in one field disabled
# protection in another.
# This is the more important of the two front-end paths: `-s key=value` is what AccA sends for
# every setting the app writes, and what the daemon uses internally. write-config's own clamp
# stays exactly as it is -- it is the backstop for a corrupt config FILE, not for a user command.
#
# Ranges are the documented ones and match acc.sh exactly: percent, or millivolts. An EMPTY value
# is allowed through untouched: clearing a key is a legitimate operation and the daemon relies on
# it.
cfg_check_kv() {
  case "$1" in
    # ARRAYS in the config. Assigning one as a scalar leaves write-config reading ${capacity[0]} as
    # the whole string and every other field falling back to its default, so the command reports
    # success and changes nothing. charging_switch is NOT listed: it is a scalar setter, and the
    # daemon itself uses it.
    capacity=*|temperature=*|cooldownRatio=*|cooldown_ratio=*|loopDelay=*|loop_delay=*)
      echo "Cannot set ${1%%=*} directly: it is an array in the config." >&2
      echo "Use the individual settings, for example:" >&2
      echo "  acc -s shutdown_capacity=5 cooldown_capacity=60 resume_capacity=70 pause_capacity=75 capacity_mask=false" >&2
      echo "  acc -s cooldown_temp=45 max_temp=50 resume_temp=40 shutdown_temp=55" >&2
      echo "  acc 75 70    (shortcut for pause and resume capacity)" >&2
      return 2
    ;;
    # REFUSE an out-of-range capacity, the way the shorthand `acc 999` already does. rc21 added
    # that check to the shorthand only, so the -s form stayed the "success tick over a value you
    # did not ask for" that the shorthand fix exists to stop.
    #
    # cooldown_capacity is deliberately absent: it uses 101 to mean "disabled", a different domain
    # that this rule would wrongly reject.
    pause_capacity=*|resume_capacity=*|shutdown_capacity=*)
      _cgv=${1#*=}
      [ -n "${_cgv:-}" ] || return 0
      case "$_cgv" in
        *[!0-9]*)
          echo "Invalid ${1%%=*}: $_cgv" >&2
          echo "Expected a number: 0-100 (percent) or 3001-5000 (mV)" >&2
          return 2
        ;;
      esac
      if [ "$_cgv" -le 100 ] 2>/dev/null; then return 0; fi
      if [ "$_cgv" -ge 3001 ] 2>/dev/null && [ "$_cgv" -le 5000 ] 2>/dev/null; then return 0; fi
      echo "Capacity out of range: $_cgv" >&2
      echo "Expected 0-100 (percent) or 3001-5000 (mV)" >&2
      return 2
    ;;
  esac
  return 0
}
