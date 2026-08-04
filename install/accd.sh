#!/system/bin/sh
# Advanced Charging Controller Daemon (accd)
# Copyright 2017-2024, VR25
# License: GPLv3+


. $execDir/acquire-lock.sh


# rc21: the daemon runs under `set -u`, so touching an unset variable is fatal -- and these come
# from $TMPDIR/.batt-interface.sh, a tmpfs cache that is absent on every boot and can also go
# missing on its own. When it is, the daemon aborted at init with
# `accd.sh: currFile: parameter not set` and exited through exxit. That is the worst possible
# moment to die: any charge switch left cut STAYS cut, the charger reads offline, and a dead
# daemon cannot release it -- the phone then discharges on a live cable and survives reboots.
# Reproduced on a Mi A3 while chasing the "drains rather than charges" field report.
# acc-switch-scan.sh already predeclares these for the same reason; the daemon did not.
# Empty is the correct default: every consumer already treats an empty currFile/battStatus as
# "unknown" and falls back to a direct read.
: ${currFile:=}
: ${battStatus:=}
: ${ampFactor_:=}


_INIT=false

case "$*" in
  *-i*) _INIT=true;;
  # rc22: rebuild when the cache is UNUSABLE, not merely when it is absent. The old test was -f,
  # which an empty file passes -- so a truncated cache left _INIT false, the daemon sourced nothing,
  # and it ran blind on fail-safe defaults with no way back short of deleting the file or rebooting.
  # There is a real path to that state: the cache is written with a truncating redirect, so a crash
  # or a kill between the truncate and the write leaves it zero-length for good.
  # The consequence is not subtle. With battCapacity unset, batt_cap coerces to 100, _ge_pause_cap
  # is then always true, and a daemon started in that state pauses charging permanently.
  # Found on both test phones at once: acc -i returned nothing on either, because every CLI call
  # sources this same file, while the already-running daemons kept working from memory and looked
  # perfectly healthy.
  # battCapacity is the right sentinel: the init block below exits rather than write the cache
  # without one, so its presence means the file was written completely.
  *) { [ -s $TMPDIR/.batt-interface.sh ] \
       && grep -q '^battCapacity=' $TMPDIR/.batt-interface.sh 2>/dev/null; } || _INIT=true;;
esac


if ! $_INIT; then


  _ge_cooldown_cap() {
    case ${capacity[1]-} in ''|*[!0-9]*) return 1;; esac
    if [ ${capacity[1]} -gt 3000 ]; then
      [ $(volt_now) -ge ${capacity[1]} ]
    else
      [ $(batt_cap) -ge ${capacity[1]} ]
    fi
  }


  # rc(6.4): a capacity value is valid ONLY as 0-100 (percent) or 3001-5000 (mV). A
  # numeric-but-out-of-range value (a hand-edited 99999999, or 150) passes the non-numeric
  # guard, is then read as mV, and makes the daemon NEVER pause / ALWAYS resume = overcharge.
  # write-config clamps on write, but the daemon re-sources the raw config every loop, so each
  # comparator below range-guards INLINE (kept self-contained -- no shared helper to extract).

  _ge_pause_cap() {
    # fail safe: an empty/unset OR non-numeric pause_capacity must read as "at or
    # above the limit" so charging is paused, never left running above an unknown
    # or garbage limit -- a malformed value would otherwise make the numeric test
    # below error out and silently skip the pause (overcharge).
    case ${capacity[3]-} in ''|*[!0-9]*) return 0;; esac
    { [ ${capacity[3]} -le 100 ] || { [ ${capacity[3]} -gt 3000 ] && [ ${capacity[3]} -le 5000 ]; }; } || return 0
    if [ ${capacity[3]} -gt 3000 ]; then
      [ $(volt_now) -ge ${capacity[3]} ]
    else
      [ $(batt_cap) -ge ${capacity[3]} ]
    fi
  }


  temp_now() {  # D10: coerce an empty/garbage temp read to a benign 250 (25.0C) so a transient sensor
    local _t=; { read -r _t < "$temp"; } 2>/dev/null || :; case "$_t" in ''|*[!0-9-]*) _t=250;; esac; echo "$_t"   # blip can't make a [ $(temp_now) -lt N ] test a syntax error -> set -eu abort -> exxit. Mirrors volt_now/batt_cap. rc19: builtin read, no cat spawn.
  }


  _temp_hold() {
    # rc22: true only when the pack is PROVABLY at or above max_temp, i.e. a thermal pause is in
    # force and charging must NOT be turned back on.
    #
    # Three paths re-enable charging on a capacity test alone: the EXIT trap, the init release of a
    # left-cut switch, and generic_rearm. Their shared reasoning -- "the level is below the pause
    # level, so a release can never overcharge" -- is correct for a CAPACITY pause and blind to
    # every other kind. With the pack over max_temp and the level anywhere under pause_capacity
    # (the ordinary case), each of them turns charging back on while the thermal pause is still
    # meant to be holding. Field report on a sweet: repeated re-enables at 40.4-41.4C against
    # max_temp 40, one of them logged as `init release ... (left cut, level 64 < pause 75)` -- a
    # decision made on capacity with no temperature term in it at all.
    #
    # Deliberately one-sided: any doubt returns FALSE (no hold). Blocking a release on a sensor we
    # cannot read would resurrect the bug the init block at the bottom of this file exists to fix
    # -- switch left cut, charger reading offline, phone discharging on a live cable across
    # reboots. Refusing to release is the dangerous direction; only a positive over-temperature
    # reading is allowed to block one. So this reads the node itself rather than going through
    # temp_now(), whose 250 fallback would fabricate a hold out of a dead sensor.
    #
    # Safe at all three sites because a live main loop still owns the eventual release: it resumes
    # as soon as the pack cools. The one case where no daemon remains -- `acc -D stop` while hot --
    # already behaves this way for capacity (see the EXIT trap), where leaving the switch held and
    # letting a replug clear it is the documented, safer trade-off.
    local _th=
    case ${temperature[1]-} in ''|*[!0-9]*) return 1;; esac
    { read -r _th < "${temp:-/nonexistent}"; } 2>/dev/null || return 1
    case ${_th:-x} in ''|*[!0-9-]*) return 1;; esac
    [ "$_th" -ge $(( ${temperature[1]} * 10 )) ] 2>/dev/null
  }


  _le_pause_cap() {
    case ${capacity[3]-} in ''|*[!0-9]*) return 1;; esac
    { [ ${capacity[3]} -le 100 ] || { [ ${capacity[3]} -gt 3000 ] && [ ${capacity[3]} -le 5000 ]; }; } || return 1
    if [ ${capacity[3]} -gt 3000 ]; then
      [ $(volt_now) -le ${capacity[3]} ]
    else
      [ $(batt_cap) -le ${capacity[3]} ]
    fi
  }


  _lt_pause_cap() {
    case ${capacity[3]-} in ''|*[!0-9]*) return 1;; esac
    { [ ${capacity[3]} -le 100 ] || { [ ${capacity[3]} -gt 3000 ] && [ ${capacity[3]} -le 5000 ]; }; } || return 1
    if [ ${capacity[3]} -gt 3000 ]; then
      [ $(volt_now) -lt ${capacity[3]} ]
    else
      [ $(batt_cap) -lt ${capacity[3]} ]
    fi
  }


  _gt_resume_cap() {
    case ${capacity[2]-} in ''|*[!0-9]*) return 0;; esac
    { [ ${capacity[2]} -le 100 ] || { [ ${capacity[2]} -gt 3000 ] && [ ${capacity[2]} -le 5000 ]; }; } || return 0
    if [ ${capacity[2]} -gt 3000 ]; then
      [ $(volt_now) -gt ${capacity[2]} ]
    else
      [ $(batt_cap) -gt ${capacity[2]} ]
    fi
  }


  _le_resume_cap() {
    if $mtReached && _lt_pause_cap; then
      return 0
    fi
    # fail safe: an empty/unset OR non-numeric resume_capacity must read as "do
    # not resume", so a bad/garbage config can never re-enable charging on its own
    case ${capacity[2]-} in ''|*[!0-9]*) return 1;; esac
    { [ ${capacity[2]} -le 100 ] || { [ ${capacity[2]} -gt 3000 ] && [ ${capacity[2]} -le 5000 ]; }; } || return 1
    if [ ${capacity[2]} -gt 3000 ]; then
      [ $(volt_now) -le ${capacity[2]} ]
    else
      [ $(batt_cap) -le ${capacity[2]} ]
    fi
  }


  _le_shutdown_cap() {
    local _sd= _rs=
    case ${capacity[0]-} in ''|*[!0-9]*) return 1;; esac
    # rc20 CRITICAL: refuse to act on an INCONSISTENT shutdown level, not just a non-numeric
    # one. A numeric but absurd value (a hand-edited 99, a restored/foreign config, a partial
    # write) passes the guard above and then powers the phone OFF at a high battery level --
    # the same class of hole that let a numeric shutdown_temp=9 shut the phone down at room
    # temperature. write-config enforces shutdown < resume on the write path; this is the
    # daemon-side equivalent for a config that never went through it. Compared within one
    # domain only (percent <=100 vs millivolt >3000), so mV configs are unaffected, and the
    # legitimate low-battery protection (e.g. 5% with resume 65%) is untouched.
    _sd=${capacity[0]}; _rs=${capacity[2]-}
    case "$_rs" in ''|*[!0-9]*) _rs=;; esac
    if [ $_sd -gt 3000 ]; then
      [ $_sd -le 5000 ] || return 1
      [ -z "$_rs" ] || [ $_rs -le 3000 ] || [ $_sd -lt $_rs ] || return 1
      [ $(volt_now) -le $_sd ]
    else
      [ $_sd -le 100 ] || return 1
      [ -z "$_rs" ] || [ $_rs -gt 3000 ] || [ $_sd -lt $_rs ] || return 1
      [ $(batt_cap) -le $_sd ]
    fi
  }


  # rebootResume loop-guard (rc15): return 0 (ok to reboot) for at most 2 attempts, then 1 (capped),
  # so a reboot-to-resume that never actually fixes charging can NOT reboot the phone forever (which
  # on some phones ends in a Qualcomm CrashDump/EDL). The counter persists across reboots (dataDir)
  # and is cleared by a healthy charging resume, so a genuine one-off reboot is never penalized.
  _reboot_resume_allowed() {
    local _rrc
    _rrc=$(cat "$dataDir/.reboot-resume-count" 2>/dev/null || echo 0)
    case ${_rrc:-0} in ''|*[!0-9]*) _rrc=0;; esac
    [ "$_rrc" -lt 2 ] || return 1
    echo $(( _rrc + 1 )) > "$dataDir/.reboot-resume-count" 2>/dev/null || :
    sync 2>/dev/null || :
    return 0
  }


  _uptime() {
    [ $(cut -d '.' -f 1 /proc/uptime) -ge $1 ]
  }


  _tick() {
    # rc19 (standby): the shared 1-second wait for every nap. Each tick used to be a sleep
    # spawn plus a stat spawn (config-mtime watch) -- roughly 200k forks a night doing
    # nothing. Now: a timed builtin read on the daemon's wake fifo (zero forks; writing
    # anything to $TMPDIR/.wake wakes the daemon instantly), and the config watch is the
    # builtin -nt test against a tmpfs ref file the caller refreshes at nap start.
    # Returns 1 (break the nap) when the config changed; degrades to sleep if the fifo
    # could not be created at init. mksh read -t returns >128 on timeout -- swallowed.
    if $hasWakeFifo; then read -t 1 -u9 _wk 2>/dev/null || :; else sleep 1; fi
    [ ! $config -nt $TMPDIR/.nap-ref ]
  }


  _nap() {
    # fix10: interruptible sleep. The daemon already re-reads the config every loop,
    # so the only thing delaying a settings change is this wait. Wake as soon as the
    # config file changes, so AccA edits (limits, temps, switch, ...) apply within
    # ~1s -- live, no daemon restart, no UI freeze. rc19: fork-free ticks (see _tick);
    # xtrace is silenced inside the wait so the log does not grow 3 lines per second.
    local left=${1:-5}
    case $left in ''|*[!0-9]*) left=5;; esac
    : > $TMPDIR/.nap-ref 2>/dev/null || :
    set +x
    while [ $left -gt 0 ]; do
      left=$((left - 1))
      _tick || break
    done
    set -x
  }


  _nap_idle() {
    # fix#293 (deep sleep): when the device is UNPLUGGED and nothing is actionable,
    # waking the CPU every few seconds keeps it out of deep sleep and drains the
    # battery. Wait much longer here, but stay fully interruptible:
    #   - break within ~1s of a charger being plugged in (online polled each second),
    #   - break within ~1s of a config edit (config mtime watched, same as _nap),
    # so plugging in / changing settings still responds fast. The discharge-side
    # shutdown_capacity check is unaffected: the caller only takes this longer path
    # when no shutdown action is pending, and re-reads config + re-checks every wake.
    # Degrades safely to a plain countdown if stat/online are unavailable.
    # rc19: fork-free ticks (_tick) + a cached, builtin-read present() -- this loop used to
    # spawn sleep+stat+ls+grep+cat every second, all night, on every unplugged phone.
    local left=${1:-60}
    case $left in ''|*[!0-9]*) left=60;; esac
    : > $TMPDIR/.nap-ref 2>/dev/null || :
    set +x
    while [ $left -gt 0 ]; do
      left=$((left - 1))
      # charger attached -> wake now so charging logic runs immediately. rc9: gate on
      # present (cable attached), not online -- an input-cut switch holds online=0 while
      # plugged, which kept the daemon in this 120s deep nap (delaying resume + config
      # edits). present stays 1 whenever the cable is in. Written "! present || break"
      # so the truly-unplugged case returns 0 under set -e, like _nap's mtime guard.
      ! present || break
      # config changed -> wake now so AccA edits apply live (via _tick's -nt test)
      _tick || break
    done
    set -x
  }


  _nap_hold() {
    # rc19 (standby): plugged-and-paused is the overnight-on-charger state -- nothing is
    # actionable until the battery drifts down to the resume level (about 1% per hour) or
    # the cable moves, yet the loop kept its 9s cadence all night. Hold in fork-free 1s
    # ticks like _nap_idle, but break on UNPLUG (present gone) instead of plug-in; config
    # edits still break within ~1s. Worst-case resume detection moves from 9s to ~30s
    # against a multi-hour drain curve -- nothing a battery can do in 30s matters here.
    local left=${1:-30}
    case $left in ''|*[!0-9]*) left=30;; esac
    : > $TMPDIR/.nap-ref 2>/dev/null || :
    set +x
    while [ $left -gt 0 ]; do
      left=$((left - 1))
      present || break
      _tick || break
    done
    set -x
  }


  cap_idle_threshold() {
    # rc(6.3.1): guard unset/garbage pause_capacity (hand-corrupted config) -- return 1
    # (do not special-case idle) rather than let an unset ${capacity[3]} abort under set -u.
    case ${capacity[3]-} in ''|*[!0-9]*) return 1;; esac
    if [ ${capacity[3]} -gt 3000 ]; then
      [ ${capacity[3]} -gt 3900 ] && [ $(volt_now) -gt $(( ${capacity[3]} + 50 )) ]
    else
      [ ${capacity[3]} -gt 60 ] && [ $(batt_cap) -gt $(( ${capacity[3]} + 1 )) ]
    fi
  }


  exxit() {
    exitCode=$?
    $persistLog && set +eu || set +eux
    rm $TMPDIR/.forceoff* 2>/dev/null
    trap - EXIT
    [ -n "$1" ] && exitCode=$1
    [ -n "$2" ] && print "$2"
    $persistLog || exec > /dev/null 2>&1
    # rc19: reset Android's battery overrides only if something actually set them (marker),
    # instead of unconditionally. rc20 CRITICAL: the marker is .dsys-override, written by
    # dsys_batt for EVERY set/unplug (mask, cooldown, charge-once), not the mask-only marker
    # -- on exit the daemon must never leave Android's battery state frozen.
    [ ! -f $TMPDIR/.dsys-override ] || { dsys_batt reset >/dev/null; rm -f $TMPDIR/.mask-on $TMPDIR/.mask-last $TMPDIR/.mask-n 2>/dev/null; } || :
    # $TMPDIR/.config is written here AND by acc.sh's -t path, but the two can
    # never be live together, so this does not need the per-process name that
    # .state.json / .parse_switches / .tmp did. The -t path calls daemon_ctrl
    # stop first, which sources release-lock.sh, and that BLOCKS on
    # `timeout 10 flock 0` (and then a plain `flock 0`) until this daemon has
    # released the lock. The lock is held for the daemon's whole lifetime, so it
    # only comes free once this trap has finished and the process is gone. Even
    # if that ordering were somehow broken, the -t path's own acquire-lock.sh
    # uses `flock -n`, which fails outright rather than racing.
    grep -Ev '^$|^#' $config > $TMPDIR/.config
    config=$TMPDIR/.config
    applyOnPlug=(${applyOnPlug[*]-} ${applyOnBoot[*]-})
    apply_on_plug default
    tempLevel=0
    # D2 (rc15): do NOT re-enable charging on exit when the battery is AT/ABOVE the user's limit. On a
    # SIGTERM stop/restart (the exitCode=143 in the logs) the daemon used to enable_charging here, opening
    # an uncapped window until the NEXT daemon's first pause -- a real overshoot at the cap on every
    # restart. (The 'exec accd --init' reload paths REPLACE the process and never run this EXIT trap, so
    # they were never the source.) At/above the cap we leave the switch in its held state so a restart is
    # seamless; below it we resume charging exactly as before. If the cap can't be determined we keep the
    # old behavior (enable). Trade-off: 'acc -D stop' AT the cap leaves the phone paused until replug --
    # the safe direction (never overshoot).
    # rc22: ...and the same applies to a THERMAL pause. Resuming here because the level happens to
    # sit below pause_capacity hands back an uncapped charge on a pack that is over max_temp, with
    # no daemon left to pause it again. See _temp_hold.
    if _ge_pause_cap 2>/dev/null || _temp_hold 2>/dev/null; then :; else enable_charging; fi
    if [[ "$exitCode" = @(1|2|7|127) ]]; then
      . $execDir/logf.sh
      logf --export
      notif "⚠️ Exit $exitCode; log: acc -l tail"
    fi
    cd /
    echo versionCode=$versionCode
    exit $exitCode
  }


  is_charging() {

    local file=
    local value=
    local isCharging=false

    # source config & set discharge polarity
    set_dp

    if not_charging; then
      unsolicitedResumes=0
      xIdleCount=0   # rc7 (A2): reset the idle-avoidance budget each time charging genuinely stops (new session), so allow_idle_above_pcap users keep it across days without a reboot
      # rc16: charging is NOT happening (paused at limit, idle, or UNPLUGGED). Reset
      # the whole auto-lock campaign so a transient plug/unplug blip is never mistaken
      # for "charging past the limit", and the next real charge starts a clean detect.
      # (Deliberately keeps $TMPDIR/.sw-blacklist so a proven-bad switch stays excluded
      # for the session.)
      rm $TMPDIR/.autolock-tried $TMPDIR/.autolock-count $TMPDIR/.autolock-gaveup \
         $TMPDIR/.lockfail-count $TMPDIR/.breach \
         $TMPDIR/.resumewarned 2>/dev/null || :
    else
      isCharging=true
      # [auto mode] change the charging switch if charging has not been enabled by acc (if behavior repeats 3 times in a row)
      if $chDisabledByAcc && [ -n "${chargingSwitch[0]-}" ] && [[ "${chargingSwitch[*]}" != *\ -- ]] \
        && sleep ${loopDelay[1]} && { ! not_charging || { isCharging=false; false; }; }
      then
        if [ $unsolicitedResumes -ge 3 ]; then
          if grep -q "^${chargingSwitch[*]}$" $TMPDIR/ch-switches; then
            sed -i "\|^${chargingSwitch[*]}$|d" $TMPDIR/ch-switches
            echo "${chargingSwitch[*]}" >> $TMPDIR/ch-switches
          fi
          $TMPDIR/acca $config --set charging_switch=
          chargingSwitch=()
          unsolicitedResumes=0
        else
          unsolicitedResumes=$((unsolicitedResumes + 1))
        fi
      fi
      # [auto mode] set charging switch
      if [ -z "${chargingSwitch[0]-}" ]; then
        disable_charging
        enable_charging
      fi
    fi

    # rc5 (#5): coerce a garbage/empty currentWorkaround to the baseline FIRST, then quote both
    # operands. Unquoted + empty made "[ false = ]" a syntax error -> set -e abort (exxit re-enables
    # charging), and a garbage value would re-exec the daemon every loop.
    case ${currentWorkaround-} in true|false) :;; *) currentWorkaround=$currentWorkaround0;; esac
    [ "$currentWorkaround0" = "$currentWorkaround" ] || exec $TMPDIR/accd --init
    # rc10/rc12: a user-initiated "automatic" reset re-discovers the best switch now, without a
    # manual restart -- write-config drops $dataDir/.rediscover when a non-daemon acc/acca -s blanks
    # the switch. rc12 robustness: clear the marker + the session switch-blacklist (fresh slate),
    # then RE-ARM charging on the known cut nodes -- otherwise the just-blanked switch's leftover cut
    # makes the daemon read "already not charging", so it sees no cut-need and never re-detects.
    # Then self-init to re-pick + lock. (Re-arm runs ONLY on an explicit user reset.)
    [ -f $dataDir/.rediscover ] && {
      rm -f $dataDir/.rediscover $TMPDIR/.sw-blacklist 2>/dev/null || :
      for _en in /sys/class/power_supply/*/charging_enabled /sys/class/power_supply/*/battery_charging_enabled /sys/class/power_supply/*/charge_enabled; do [ -w "$_en" ] && { _wlog "exit $_en <- 1" 2>/dev/null; echo 1 > "$_en" 2>/dev/null; } || :; done
      for _di in /sys/class/power_supply/*/input_suspend /sys/class/power_supply/*/charge_disable /sys/class/power_supply/*/batt_slate_mode /sys/class/power_supply/*/op_disable_charge; do [ -w "$_di" ] && { _wlog "exit $_di <- 0" 2>/dev/null; echo 0 > "$_di" 2>/dev/null; } || :; done
      unset _en _di 2>/dev/null || :
      exec $TMPDIR/accd --init
    }
    (set +eu; eval '${loopCmd-}') || :

    # N1: coerce temperature[]/capacity[] to safe numeric defaults EACH loop. The daemon re-sources
    # $config RAW, so a hand-edited / partially-written / corrupt value would otherwise make a
    # downstream "$(( N * 10 ))" or "[ -ge N ]" abort the loop under set -eu and DROP the limit.
    # write-config sanitizes on WRITE; this guards the READ side for every arithmetic site below.
    case "${temperature[0]-}" in ''|*[!0-9]*) temperature[0]=45;; esac
    case "${temperature[1]-}" in ''|*[!0-9]*) temperature[1]=50;; esac
    case "${temperature[2]-}" in ''|*[!0-9]*) temperature[2]=40;; esac
    case "${temperature[3]-}" in ''|*[!0-9]*) temperature[3]=55;; esac
    case "${capacity[0]-}" in ''|*[!0-9]*) capacity[0]=5;; esac
    case "${capacity[1]-}" in ''|*[!0-9]*) capacity[1]=101;; esac
    case "${capacity[2]-}" in ''|*[!0-9]*) capacity[2]=70;; esac
    case "${capacity[3]-}" in ''|*[!0-9]*) capacity[3]=80;; esac

    # rc21: the rc20-alpha4 pump-cap warning and its opt-in veto were REMOVED.
    # They rested on one premise - that a max_charging_current of 3000-5499 mA
    # blocks a phone's charge pump and drops it to the buck path - and that
    # premise had exactly one source: a "the original ACC is faster" report from
    # a Redmi Note 9S. That report is now fully explained and the cap was never
    # the cause. Its logs show first a 5V/1.6A USB_DCP brick (8W into an 18W
    # phone, so no build could fast charge), and later ACC writing
    # constant_charge_current <- 500000 from a wrongly captured "default". The
    # Note 9S has no charge pump at all, so 4350 mA is near its ceiling, not
    # below a pump's draw. Nobody has ever observed the phenomenon this guarded
    # against, and the check told that same user his correct setting was wrong.
    # An unverified heuristic that misinforms people about their own hardware is
    # worse than no heuristic. The fast-charge cooldown guard (fast_session) is
    # unaffected and stays: it has two independent field confirmations.

    # shutdown if battery temp >= shutdown_temp
    # Coerce a garbage/empty shutdown-temp so a hand-edited / partially-migrated config cannot
    # trigger a SPURIOUS shutdown (non-numeric -> arithmetic 0 -> the -lt test fails -> shutdown).
    _st=${temperature[3]}; case "$_st" in ''|*[!0-9]*) _st=55;; esac
    # rc20 CRITICAL: BAND-check too, not just "is it a number". A low NUMERIC shutdown_temp
    # (st=9) is a number, passes the guard above, and then "temp >= 9C" is true at any room
    # temperature -- so the daemon powers the phone off on its very next loop. write-config
    # clamps this on the write path, but the daemon is the last line of defence for a config
    # that never went through it: a hand edit, a restored/older backup, a partially written
    # file, or another tool. Device-proven: st=9 fired the shutdown branch at 26C.
    # Battery temperatures are always Celsius here (no millivolt domain), so a fixed sane
    # band is safe; anything outside it is garbage, not a user preference.
    { [ "$_st" -ge 40 ] && [ "$_st" -le 70 ]; } 2>/dev/null || _st=55
    # rc21 CRITICAL: only ever power the phone off on a reading we actually TRUST.
    #
    # This line used to be `[ $(temp_now) -lt $(( _st * 10 )) ] || shutdown`, with the
    # substitution UNQUOTED. When the temperature read came back empty the word disappeared, so
    # the shell saw `[ -lt 550 ]`, which is not a valid test -- mksh returns 2 ("unexpected
    # operator/operand"), that counts as false, and the `||` powered the phone off. The check
    # failed OPEN, in the worst possible direction: an unreadable sensor was treated as an
    # overheating battery.
    #
    # temp_now coerces a bad read to 250, so this looked impossible; it is not. The relative
    # sysfs paths (temp=battery/temp, battStatus=battery/status) all resolve against the daemon's
    # CWD, and when that goes the reads fail together and the function's own output is lost with
    # them. Device-proven on a Mi A3: `accd shutdown` logged with level=, temp= AND status= all
    # empty, config perfectly sane (shutdown_temp 55) and the battery at 31C, immediately
    # followed by ShutdownActivity in logcat. It powered the phone off four times.
    #
    # Now: read once, demand a plain number, and only compare a value we have. No reading means
    # no shutdown -- max_temp still pauses charging, so nothing is left unprotected. A thermal
    # cutoff that cannot read the thermometer must do nothing, never fire.
    _tn=$(temp_now 2>/dev/null) || _tn=
    case "${_tn:-x}" in ''|*[!0-9-]*) _tn=;; esac
    [ -z "$_tn" ] || [ "$_tn" -lt $(( _st * 10 )) ] || shutdown

    [ -z "${cooldownCurrent-}" ] || {
      # N1: coerce cooldown(=[0])/resume(=[2]) temps so a corrupt/hand-edited value can't abort
      # the loop under set -eu (same hardening as the shutdown-temp read above).
      _ct0=${temperature[0]}; case "$_ct0" in ''|*[!0-9]*) _ct0=45;; esac
      _rt2=${temperature[2]}; case "$_rt2" in ''|*[!0-9]*) _rt2=40;; esac
      if [ $(temp_now) -le $(( _rt2 * 10 )) ] && ! _ge_cooldown_cap; then
        restrictCurr=false
      fi
      if _ge_cooldown_cap || [ $(temp_now) -ge $(( _ct0 * 10 )) ] \
        || { ! $isCharging && [ $(temp_now) -ge $(( _rt2 * 10 )) ]; }
      then
        restrictCurr=true
      fi
    }

    if $isCharging; then

      if [ -f $TMPDIR/.mcc-read ]; then
        # set charging current control files, as needed
        if [ -n "${maxChargingCurrent[0]-}" ] \
          && { [ -z "${maxChargingCurrent[1]-}" ] || [[ "${maxChargingCurrent[1]-}" = -* ]]; } \
          && grep -q / $TMPDIR/ch-curr-ctrl-files 2>/dev/null
        then
          set_ch_curr ${maxChargingCurrent[0]} || :
          . $execDir/write-config.sh
        fi
      else
        # parse charging current ctrl files
        . $execDir/read-ch-curr-ctrl-files-p2.sh
      fi

       # set charging voltage control files, as needed
      if [ -n "${maxChargingVoltage[0]-}" ] \
        && { [ -z "${maxChargingVoltage[1]-}" ] || [[ "${maxChargingVoltage[1]-}" = -* ]]; } \
        && grep -q / $TMPDIR/ch-volt-ctrl-files 2>/dev/null
      then
        set_ch_volt ${maxChargingVoltage[0]} || :
        . $execDir/write-config.sh
      fi

      $cooldown || {
        resetBattStatsOnUnplug=true
        if $resetBattStatsOnPlug && ${resetBattStats[2]:-false}; then
          sleep ${loopDelay[0]}
          not_charging || {
            resetbs
            resetBattStatsOnPlug=false
          } 2>/dev/null
        fi
      }

      if $restrictCurr && [ -n "${cooldownCurrent-}" ]; then
        $cooldown || (set_ch_curr ${cooldownCurrent:--} || :)
        (maxChargingCurrent=(); apply_on_plug)
      else
        [ -n "${maxChargingCurrent[0]-}" ] || (set_ch_curr - || :)
        apply_on_plug
      fi

      set_ch_volt ${maxChargingVoltage[0]:--}
      { $restrictCurr && [[ .${cooldownCurrent-} = .*% ]]; } || set_temp_level
      shutdownWarnings=true
      # rebootResume loop-guard (rc15): charging is being applied here = a healthy resume, so reset
      # the reboot-attempt counter. A genuine one-off reboot-to-resume is never penalized.
      [ ! -f "$dataDir/.reboot-resume-count" ] || rm -f "$dataDir/.reboot-resume-count" 2>/dev/null || :

    else

      if $rebootResume && _le_resume_cap && [ $(temp_now) -lt $(( ${temperature[1]} * 10 )) ]; then
        # LOOP-GUARD (rc15): only reboot if we haven't already burned our attempts -- a resume that
        # never works must not reboot the phone forever. After the cap, warn instead of rebooting.
        if _reboot_resume_allowed; then
          notif "⚠️ System will reboot in 60 seconds to re-enable charging! Run \"accd.\" to abort." || :
          sleep 60
          ! not_charging || {
            /system/bin/reboot || reboot
          }
        else
          warn_once_per reboot-resume-giveup 3600 "⚠️ ACC: charging still won't resume after repeated reboots; not rebooting again. Unplug + replug the cable, or check your charging switch in AccA." || :
        fi
      fi

      $cooldown || {
        resetBattStatsOnPlug=true
        if $resetBattStatsOnUnplug && ${resetBattStats[1]:-false}; then
          sleep ${loopDelay[1]}
          ! not_charging Discharging || {
            resetbs
            resetBattStatsOnUnplug=false
          } 2>/dev/null
        fi
      }
    fi

    mask_capacity

    set +u
    [ -n "${idleApps[0]}" ] \
      && dumpsys activity top | sed -En 's/(.*ACTIVITY )(.*)(\/.*)/\2/p' \
      | tail -n 1 | grep -E "$(echo ${idleApps[*]} | sed 's/ /|/g; s/,/|/g')" >/dev/null \
      && pause_now || :
    _enc=$(cat /dev/encore_mode 2>/dev/null || cat /data/adb/.config/encore/current_profile 2>/dev/null || print 0)
    case ${_enc:-0} in *[!0-9]*|'') _enc=0;; esac   # rc5 (#11): coerce non-numeric encore profile -> no "-ne" abort
    [ $_enc -ne 1 ] || pause_now
    set -u

    $isCharging && return 0 || return 1
  }


  # rc15 FLIGHT RECORDER: one compact state sample per loop into a ring-buffered log. This piggybacks
  # the loop the daemon ALREADY runs every ~9s (no new wakeup, no extra battery drain) so it captures
  # the full charge-control timeline -- including an overnight overcharge -- for acc-diag to bundle and
  # the user to share. Pure logging, fully guarded (|| :), can NEVER affect charging. Trims itself to
  # ~1500 lines. Fields: epoch,cap,cur_raw,status,online,present,cutByAcc,tag
  flight_rec(){
    { printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date +%s 2>/dev/null)" "$(batt_cap 2>/dev/null)" \
        "$(cat "$currFile" 2>/dev/null)" "$(read_status 2>/dev/null)" \
        "$(online 2>/dev/null && echo 1 || echo 0)" "$(present 2>/dev/null && echo 1 || echo 0)" \
        "${chDisabledByAcc:-?}" "${1:-loop}" >> "$dataDir/logs/flight.log"; } 2>/dev/null || :
    _frc=$(( ${_frc:-0} + 1 ))
    [ "$_frc" -ge 40 ] 2>/dev/null && { _frc=0; tail -n 1500 "$dataDir/logs/flight.log" > "$dataDir/logs/flight.log.t" 2>/dev/null && mv -f "$dataDir/logs/flight.log.t" "$dataDir/logs/flight.log" 2>/dev/null; } || :
  }

  amp_recheck() {
    # 6.4.1-rc5: STICKY-UP uA latch. The current_now unit is only knowable from a CHARGING
    # current: a microamp sensor reads >= 16000 raw when charging (no cell charges at 16+ amps),
    # a milliamp sensor stays under it (OnePlus 8 Pro tops out ~5000 mA). Latch + PERSIST uA the
    # moment a big current appears, so a daemon init while idling at the cap can self-heal on the
    # next charge instead of mis-defaulting to mA. Bumps UP only; a true mA device is never touched.
    [ "${ampFactor_:-1000}" = 1000000 ] && return 0
    local _c=$(cat $currFile 2>/dev/null); _c=${_c#-}
    [ "$_c" -ge 16000 ] 2>/dev/null || return 0
    ampFactor_=1000000
    echo ampFactor_=1000000 >> $TMPDIR/.batt-interface.sh 2>/dev/null || :
    grep -q '^ampFactor=1000000$' $dataDir/config.txt 2>/dev/null \
      || sed -i 's/^ampFactor=.*/ampFactor=1000000/' $dataDir/config.txt 2>/dev/null || :
  }

  ctrl_charging() {

    while :; do

      amp_recheck || :

      # publish the state export (subsystem A) -- best-effort, never blocks the loop
      #
      # rc21: this ran unconditionally every loop. The export is AccA's UI feed, not a safety
      # function, and rebuilding the whole snapshot forever cost 1673 of ACC's 2428 forks/min
      # at idle on a Mi A3 (69% of them; ~52% of one core, screen off, nothing happening).
      # Publish straight away whenever anything the app actually shows has moved -- battery
      # level or charging status -- and otherwise at most every 30s, so the file can never sit
      # stale for long. Both probes are `read` builtins with a redirect: no fork is spent
      # deciding not to fork, which is the whole point. $SECONDS is a shell builtin too.
      _wsLvl=; _wsSt=
      read -r _wsLvl < /sys/class/power_supply/battery/capacity 2>/dev/null || :
      read -r _wsSt  < /sys/class/power_supply/battery/status   2>/dev/null || :
      # A change-triggered publish alone is not enough: `status` flaps between Charging/Idle/
      # Discharging as the current fluctuates, so the key changed on nearly every loop and the
      # throttle barely bit (profiled: the export still ran 7-9x per 20s, not once per 30s).
      # Keep the immediate publish for responsiveness, but never more often than _wsMin seconds
      # apart, so a flapping value cannot cost more than that. The 30s ceiling still bounds
      # staleness when nothing changes at all.
      # The ceiling is now uiRefresh (default 30, unchanged behaviour). It bounds ONLY the idle
      # heartbeat: the second branch below still publishes a level/status change within 5s at any
      # setting, so nothing a user waits on gets slower. state.json is display-only -- no charging
      # decision reads it and acc -i / acc -j build fresh -- so this cannot affect control.
      #
      # Worth raising because the publish is by far the daemon's most expensive act: profiled at
      # 1216ms of CPU per call on an A3 and 444ms on a Pixel 6a, against a ~2000ms/min floor for
      # everything else combined. Measured idle, screen off: 30s = 3937ms/min, 60s = 2946 (-25%),
      # 120s = 2394 (-39%). uiRefresh=0 drops the heartbeat entirely (~2000ms/min, -49%) and
      # leaves only change-driven publishes, which suits a plugged phone nobody is watching.
      _uiR=${uiRefresh:-60}
      case $_uiR in ""|*[!0-9]*) _uiR=60;; esac
      if { [ "$_uiR" != 0 ] && [ $(( SECONDS - ${_wsAt:-0} )) -ge "$_uiR" ]; } \
      || { [ "$_wsLvl|$_wsSt" != "${_wsLast-}" ] && [ $(( SECONDS - ${_wsAt:-0} )) -ge 5 ]; }; then
        _wsLast="$_wsLvl|$_wsSt"
        _wsAt=$SECONDS
        write_state || :
      fi
      flight_rec || :

      # Trim the daemon log. This used to live at the end of is_charging(), which
      # meant it never ran on a native-firmware-limit phone: that branch continues
      # before is_charging() is called. The daemon `exec >> $log 2>&1` for its whole
      # life, so on Pixel/Tensor the log grew without bound in tmpfs - RAM that is
      # never given back until reboot. Here it runs once per loop on every phone,
      # which is exactly the cadence it had before for the generic path.
      [ "$(du -k $log 2>/dev/null | cut -f 1)" -lt 256 ] 2>/dev/null || : > $log

      # rc24: shared plug-transition tracker. freshPlug is true on the loop where the
      # charger goes offline->online; it drives native_unlatch (Pixel) and generic_rearm
      # (everything else) so a real re-plug re-arms charging exactly once -- no sawtooth,
      # and wasOnline clears on unplug.
      freshPlug=false
      if online; then $wasOnline || freshPlug=true; wasOnline=true; else wasOnline=false; fi

      # rc20: native firmware limit -- just keep the levels synced and let the firmware
      # hold/resume. Re-source $config so AccA limit changes apply live. No switch toggle,
      # no current-cut, no overshoot/drain. (Low-battery shutdown + thermal are handled by
      # the firmware/OS in this mode; opt out with $dataDir/.no-native-limit for the
      # generic switch logic below.)
      if $nativeLimit; then
        # rc21: the native (Tensor charge_stop_level) path continues before
        # is_charging() is ever reached, so it never ran the defensive _srccfg the
        # switch path uses. A terminal/third-party non-atomic write that left the
        # config truncated then killed the daemon HERE on a Pixel 9a (the Mi A3,
        # switch path, survived via _srccfg). Load defensively here too, and guard
        # sync_native_limit / mask_capacity so a broken read can never abort the
        # loop. The firmware limit keeps holding regardless, but the daemon must
        # not fall over.
        _srccfg
        # rc21: say so when the switch shown in settings is NOT what holds the limit. This branch
        # `continue`s before the generic switch logic, so on a phone with a firmware limit the
        # configured chargingSwitch is never written -- yet AccA still displays it. A Pixel 4a 5G
        # owner chasing an occasional charger blip spent the report hunting a switch that had
        # never been in use, because nothing anywhere said which mechanism was actually holding.
        # Warning only: the firmware limit is the right thing to be using, so behaviour is
        # unchanged and a user's chosen switch is still never silently overwritten.
        if [ -n "${chargingSwitch[0]-}" ] && [ "${chargingSwitch[0]}" != "$gcsl" ]; then
          warn_once_per nativeshadow 86400 "ACC: this phone has a firmware charge limit and that is what holds your limit. The charging switch listed in settings (${chargingSwitch[0]##*/}) is not being used, so changing it will not change anything." || :
        fi
        sync_native_limit || :
        native_unlatch || :
        native_verify_backstop || :
        # The Capacity Mask has to run here too. It is a DISPLAY feature and has
        # nothing to do with how charging is held, but it lives inside
        # is_charging(), and this branch continues before is_charging() is ever
        # called - so on every native-firmware-limit phone (Pixel / Tensor, via
        # google,charger/charge_stop_level) enabling the mask did nothing at all,
        # silently. Confirmed on a Pixel 9a: config read back as
        # capacity_mask=true, acc -sp agreed, and the daemon never created
        # .mask-n or .mask-on and never froze Android's level, while the same
        # build masked correctly on a Mi A3 whose switch is not native.
        mask_capacity || :
        # rc21: honour allow_idle_above_pcap on firmware-limit phones.
        #
        # This branch `continue`s before is_charging(), and the ONLY place that reads
        # allowIdleAbovePcap is inside it -- so on every phone with a native limit (any Pixel
        # with google,charger) "never sit above the limit, cycle down to resume" was accepted,
        # written to config, echoed back by acc -sp, and then silently ignored. A Pixel 3a owner
        # reported it as the battery indicator being stuck above the pause limit "after being in
        # bypass mode", which is precisely the state the setting exists to prevent.
        #
        # Fall through to the generic idle-avoidance instead of duplicating it here: that code is
        # field-hardened (xIdleCount budget, the sweet/M2101K6G churn fix) and was measured doing
        # the right thing on a Mi A3 -- input cut, battery discharging toward resume. The firmware
        # limit has already been synced above, so it keeps holding either way.
        #
        # Narrow on purpose: only when the user explicitly set the non-default false AND the
        # battery is at or above the pause level. Default (true) phones keep the pure native path
        # exactly as before, so the common case is untouched.
        # Cleared on EVERY pass before it can be set, so it can never leak into a later loop
        # where the user has raised the limit, turned the setting back on, or dropped below it.
        _nativeIdleAvoid=false
        if $allowIdleAbovePcap || ! _ge_pause_cap 2>/dev/null; then
          _nap ${loopDelay[1]:-9}
          continue
        fi
        # rc22: DO NOT hand a firmware-limit phone to the generic switch logic. Falling through
        # sends it into cycle_switches, and every candidate that does not hold costs a full
        # not_charging verification -- 35 one-second iterations each. The main loop is stopped for
        # the whole sweep: no flight.log, no sync_native_limit, and the firmware levels frozen at
        # whatever they held when it started.
        #
        # Device-proven on a Pixel 6a. Config said pause at 74% and the level was 42%, yet
        # charge_stop_level sat at 41 and the phone would not charge. acc.lock pointed at a live
        # pid in state S, so every health check said "daemon alive" while flight.log had not moved
        # in 30s; the child subshell's log grew 644 -> 5440 lines over 90s working through the
        # candidate list. `acc -D restart` recovered it instantly.
        #
        # And the sweep cannot succeed anyway: the generic toggle does not gate Tensor's charge
        # path at all, which is the entire reason the native path exists. So this was an unbounded
        # freeze in exchange for nothing. A frozen daemon enforces no limit, which is a worse
        # outcome than one setting going unhonoured -- say so plainly and keep the firmware limit,
        # which is still holding correctly throughout.
        if ! ${_niaWarned:-false}; then
          _niaWarned=true
          warn_once_per nativenoidle 86400 "ACC: 'never sit above the limit' cannot be applied on this phone. Its charge limit is held by the firmware, and the only way to drain down to the resume level would be a charging switch this hardware does not honour. Your limit is still being held; the battery will rest at it instead of cycling down." || :
        fi
        _nap ${loopDelay[1]:-9}
        continue
      fi

      leak_backstop && { _nap ${loopDelay[1]:-9}; continue; }

      if is_charging; then

        xIdle=false
        mtReached=false

        # disable charging after a reboot, if min < capacity < max
        if $offMid && [ -f $TMPDIR/.minCapMax ] && _lt_pause_cap && _gt_resume_cap; then
          disable_charging || :
          force_off
          sleep ${loopDelay[1]}
          rm $TMPDIR/.minCapMax 2>/dev/null || :
          continue
        fi

        # disable charging under <conditions>
        if mt_reached || _ge_pause_cap; then
          if ! $allowIdleAbovePcap && [ $xIdleCount -lt 2 ] \
            && { cap_idle_threshold || ${_nativeIdleAvoid:-false}; }; then
            # if possible, avoid idle mode when capacity > pause_capacity
            (cat $config > $TMPDIR/.cfg
            config=$TMPDIR/.cfg
            prioritizeBattIdleMode=no
            cycle_switches_off
            # Shared name with acc.sh's test_charging_switch_, and safe for the
            # same reason as .config above: every CLI arm that writes .sw (-t,
            # -e, -d) stops this daemon and takes the lock before it does, so a
            # writer here and a writer there cannot exist at the same moment.
            # enable_charging consumes and deletes it, which is the handoff.
            echo "chargingSwitch=(${chargingSwitch[@]-})" > $TMPDIR/.sw
            force_off)
            chDisabledByAcc=true
            # rc21: spend the budget HERE, where the attempt is made. The only other
            # increment is gated on _le_pause_cap (cap <= pause), but this branch only runs
            # when cap_idle_threshold is true (cap >= pause+2), and both sit in the same
            # is_charging iteration -- so that increment is unreachable from here and
            # xIdleCount never left 0. The "-lt 2" bound above therefore never expired and
            # cycle_switches_off re-ran every loop for as long as the level stayed above the
            # limit: endless charging-switch churn, and enough momentary on-states to trip
            # the lockhold warning about a switch that was in fact holding (field report,
            # sweet/M2101K6G: ~40 toggles in 21 min while pinned at 91%).
            xIdleCount=$((xIdleCount + 1))
            [ $_status != Discharging ] || xIdle=true
          else
            # rc(6.4-rc2): "|| :" -- disable_charging returns 7 on TOTAL switch failure
            # (no node could stop charging). The daemon runs under "set -eu", so an
            # unguarded plain call here EXITS the daemon (verified on mksh), which fires
            # exxit -> re-enables charging -> the limit is gone AND the rc19 give-up
            # monitor below never runs. Swallow the failure so the loop continues to that
            # monitor and keeps retrying. (Calls inside is_charging are if-suppressed and
            # safe; only these then-body call sites needed guarding.)
            disable_charging || :
            force_off
          fi
          ! ${resetBattStats[0]:-false} || {
            # reset battery stats on pause
            resetbs
          }
          # ── rc19: runtime contract monitor + breach notify (NO external scan) ──
          # disable_charging above ALREADY ran the daemon's own in-process,
          # current-verified switch locker (cycle_switches_off), which auto-selects and
          # LOCKS a working switch. We must NOT spawn the external acc-switch-scan.sh
          # here (rc16 did): it `acca -D stop`s the daemon and toggles switches in a
          # detached process Android can kill -- a kill leaves a current node at 0 (NO
          # CHARGE until reboot) and holds a scan lock that blocks the user's manual
          # scan ("another scan already running"). Two auto-lockers also raced. Now the
          # in-process locker is the ONLY auto path; below we just monitor + surface it.
          # Debounced so a transient plug/unplug blip is never mistaken for charging.
          # rc(6.4): gate on present (cable attached), NOT online. An input-cut switch
          # (input_suspend, current_max 0) drives */online to 0 while still plugged, so the
          # old online gate made this monitor BLIND on exactly the cut-switch devices that
          # most need it (Xiaomi/HyperOS): a non-holding cut would read online=0 -> treated
          # as "unplugged" -> breach cleared -> overcharge undetected. present stays 1.
          if present && _ge_pause_cap && ! not_charging \
             && sleep 2 && present && _ge_pause_cap && ! not_charging
          then
            if [[ "${chargingSwitch[*]-}" = *\ -- ]]; then
              # CONTRACT MONITOR: a LOCKED switch is not holding the limit. After a few confirmed
              # loops: if the USER locked it (.user-locked), WARN them (rc8) -- NEVER auto-replace a
              # manual lock; otherwise (an AUTO-locked switch) unlock + blacklist it so the in-process
              # locker picks a different one next loop (cycle_switches honors $TMPDIR/.sw-blacklist).
              lf=$(cat $TMPDIR/.lockfail-count 2>/dev/null || echo 0); lf=$((lf + 1))
              echo $lf > $TMPDIR/.lockfail-count
              if [ $lf -ge 3 ]; then
                if [ -f $dataDir/.user-locked ]; then
                  warn_once_per lockhold 21600 "⚠️ ACC: your locked charging switch isn't holding your ${capacity[3]:-?}% limit. Pick another in AccA - ACC will not change a locked switch for you."
                else
                  echo "${chargingSwitch[*]% --}" >> $TMPDIR/.sw-blacklist
                  notif "⚠️ ACC: the auto-selected charging switch stopped holding your ${capacity[3]:-?}% limit - selecting another."
                  $TMPDIR/acca $config --set charging_switch= 2>/dev/null || :
                  chargingSwitch=()
                  rm $TMPDIR/.lockfail-count 2>/dev/null || :
                fi
              fi
            else
              # Nothing locked yet and the in-process locker has not stopped charge this
              # loop; it retries automatically next loop. Just surface it, bounded, then
              # give up loudly -- never silently uncapped, never spawn an external scan.
              ac=$(cat $TMPDIR/.autolock-count 2>/dev/null || echo 0); ac=$((ac + 1))
              echo $ac > $TMPDIR/.autolock-count
              if [ $ac -le 6 ]; then
                [ -f $TMPDIR/.breach ] || { notif "🔍 ACC: selecting a charging switch that holds your ${capacity[3]:-?}% limit…"; touch $TMPDIR/.breach; }
              elif [ ! -f $TMPDIR/.autolock-gaveup ] \
                && { [ "${capacity[3]:-100}" -gt 100 ] || [ "$(batt_cap)" -ge $(( ${capacity[3]:-100} + 2 )) ] 2>/dev/null; }; then
                touch $TMPDIR/.autolock-gaveup
                warn_once_per nostop 21600 "⚠️ ACC: charging did not stop at your ${capacity[3]:-?}% limit; the battery went past it. In AccA, open the config editor and tap 'Find my charging switch'. This device may need a switch ACC does not have yet."
              fi
            fi
          else
            # not breaching (stopped at the limit, below it, or UNPLUGGED): clear the
            # per-loop markers. The full campaign reset happens in is_charging when
            # charging genuinely stops.
            rm $TMPDIR/.breach $TMPDIR/.lockfail-count 2>/dev/null || :
          fi 2>/dev/null || :
          _nap ${loopDelay[1]}
          rm $TMPDIR/.minCapMax 2>/dev/null || :
          continue
        fi

        # cooldown cycle

        while [ -n "${cooldownRatio[0]-}" ]; do

          if [ $(temp_now) -ge $(( ${temperature[0]} * 10 )) ] || _ge_cooldown_cap; then
            cooldown=true
          else
            break
          fi

          # rc20-alpha: cooldown toggles the charging switch (or pokes current caps), and that
          # tears down a live VOOC/SuperDart/HyperCharge session -- the firmware then falls back
          # to 500mA USB until a physical replug, so ONE cooldown cycle ruins the whole charge
          # (Realme GT Neo 2 field report: full 4400mA below the cooldown level, 500-600mA stuck
          # above it, normal with ACC off -- AccA's cooldown picker defaults to 60%, his exact
          # boundary). Skip the cycle while a session is live and say so once a day. Safety is
          # untouched: max_temp pause and shutdown_temp still fire; only the comfort throttle is
          # skipped. Testers: touch $TMPDIR/.fcguard-off restores the old behavior live.
          # ON by default: this is a confirmed fix, not a policy. The cooldown cycle toggles the
          # charging switch, and a VOOC/SuperDart/HyperCharge handshake does not survive a toggle -
          # the charger drops to 500 mA USB until the cable is physically pulled. So on those
          # phones the cycle does not throttle a fast charge, it destroys it for the rest of the
          # session. Confirmed on a Realme GT Neo 2: full speed below the cooldown level, 500 mA
          # stuck above it, normal with ACC off.
          # Reachable only when ALL of: the phone exposes a live-session node (see _fcNodes), the
          # user enabled cooldown, and a session is actually live. On every other phone this line
          # is dead code. Temperature safety is untouched - max_temp still pauses and shutdown_temp
          # still fires; only the comfort throttle is skipped, and the user is told once a day.
          # $TMPDIR/.fcguard-off disables it live, no reflash.
          if $cooldown && fast_session; then
            warn_once_per fcguard 86400 "ACC: skipped the cooldown cycle while fast charge is active - toggling would drop it to slow USB until you replug. (Override: create $TMPDIR/.fcguard-off)"
            cooldown=false
            break
          fi

          _lt_pause_cap && [ $(temp_now) -lt $(( ${temperature[1]} * 10 )) ] && is_charging || break

          if [ -z "${cooldownCurrent-}" ]; then
            dsys_batt set ac 1
            disable_charging || :
            sleep ${cooldownRatio[1]:-${loopDelay[0]}}
            # rc22: re-check the temperature across the sleep. The loop's own gate above tested it
            # BEFORE the off-phase, and this re-enable is on the other side of a wait that can run
            # for a whole cooldownRatio. A pack that crossed max_temp during it would be handed
            # charging back for another full cycle before the gate catches up. Cooling with the
            # switch off makes that unlikely but not impossible under load, and it is the same
            # shape as the three re-enable paths that DID let charging resume over the limit.
            _temp_hold || enable_charging
            # The `set ac 1` above is cosmetic (it stops the notification flickering while the
            # switch is toggled) but it also stops Android's battery updates, and a long
            # cooldown on a hot phone never leaves this loop -- so before rc20 the level stayed
            # frozen for the whole cooling period: the reading users saw stuck, and "charging"
            # still shown after unplugging.
            #
            # rc20 fixed that by RESETTING the override here, every cycle. That worked, but it
            # meant one freeze and one un-freeze per cycle: BatteryService flipped in and out of
            # override mode continuously. Measured on a Mi A3 at cooldownRatio 5/5: 19 override
            # transitions in 120s.
            #
            # The freeze does two jobs at once -- hold the plug state (wanted, so the notification
            # does not flicker while the switch toggles) and, as a side effect, hold the level
            # (not wanted). Dropping the override to let the level move is what caused the churn,
            # and there is no way to both release it every cycle AND avoid the transition. So keep
            # the override and refresh what it DISPLAYS instead. batt_cap is honest here: under
            # .dsys-override it reads the kernel node directly (batt-interface.sh:364), so this
            # can never re-assert its own stale value in a loop, and the limit still reads the
            # kernel regardless of what the status bar shows -- a lingering override has no safety
            # impact, only a cosmetic one. The numeric guard matters because batt_cap coerces an
            # unreadable result to 100 as a fail-safe, and publishing 100 would be a lie.
            #
            # Refresh TWICE across the charge half -- once now, once at its midpoint -- so the
            # displayed level is never more than half a charge-half stale. The kernel read is a
            # builtin (no fork) under an override, so the extra call is nearly free.
            #
            # Only when the Capacity Mask is OFF: with the mask on, that override belongs to
            # mask_capacity (it is the whole feature), and touching it here would wipe the mask a
            # moment after it was applied -- device-caught: the mask never survived a loop.
            _cd_refresh() {
              ${capacity[4]:-false} && return 0
              _cdLvl=$(batt_cap)
              case ${_cdLvl:-x} in
                ''|*[!0-9]*) ;;
                *) dsys_batt set level $_cdLvl >/dev/null 2>&1 || :;;
              esac
              return 0
            }
            _cd_refresh
            _cdHalf=${cooldownRatio[0]:-${loopDelay[0]}}
            case $_cdHalf in
              ''|*[!0-9]*) sleep ${loopDelay[0]};;
              *) if [ $_cdHalf -ge 4 ]; then
                   sleep $(( _cdHalf / 2 )); _cd_refresh; sleep $(( _cdHalf - _cdHalf / 2 ))
                 else
                   sleep $_cdHalf
                 fi;;
            esac
          else
            (set_ch_curr ${cooldownCurrent:--} || :)
            sleep ${cooldownRatio[1]:-${loopDelay[0]}}
            if [[ .${cooldownCurrent-} = .*% ]]; then
              set_temp_level $tempLevel
            else
              [ -n "${maxChargingCurrent[0]-}" ] || set_ch_curr -
            fi || :
            sleep ${cooldownRatio[0]:-${loopDelay[0]}}
          fi
        done

        # CRITICAL, and now the ONLY un-freeze: the cooldown cycle calls `dsys_batt set ac 1`
        # to keep Android showing "charging" while it toggles the switch, which stops Android's
        # battery updates. The cycle above no longer resets the override (it refreshes the
        # displayed level inside it instead), so this line alone is what hands Android's battery
        # state back when cooling ends. The loop-top cleanup cannot run while we are inside that
        # while-loop, so it has to happen here.
        #
        # Do not remove or make conditional. Upstream has no reset here at all, which is why an
        # upstream cooldown leaves the state frozen until the daemon exits: level stuck,
        # "charging" after unplug, and (before the batt_cap override rule) a limit that could
        # never fire. That is the rc19 report.
        #
        # No-op when nothing is frozen, and skipped when the Capacity Mask owns the override.
        ${capacity[4]:-false} || [ ! -f $TMPDIR/.dsys-override ] || dsys_batt reset >/dev/null 2>&1 || :

        cooldown=false
        _nap ${loopDelay[0]}

      else

        # A cleared max_charging_current must release the current-limit nodes in THIS branch too.
        # AccA's fast path (acca -s) only rewrites the config - it never calls set_ch_curr - and
        # the existing restore call sites all sit in the charging/cooldown paths, so a user who
        # disabled Charging power control while the daemon held the battery at the limit (the
        # normal resting state) kept the old cap until reboot: config clean, phone still
        # current-limited (field report: "disabled it but it still sticks", capped at 1100 mA).
        # Cheap: set_ch_curr short-circuits on its marker once the defaults are restored.
        [ -n "${maxChargingCurrent[0]-}" ] || (set_ch_curr - || :)

        # Same story for a cleared voltage limit. The charging branch releases voltage via
        # set_ch_volt above, but the daemon spends its resting life in THIS not-charging branch,
        # so a user who disabled a voltage cap while it held kept the old value on the nodes until
        # reboot - identical to the current-limit report. Release it here too when the config is
        # clean; set_ch_volt is a no-op once the defaults are back.
        [ -n "${maxChargingVoltage[0]-}" ] || (set_ch_volt - || :)

        # rc6 (L1 self-heal): some devices report current_now with an unreliable / rate-dependent
        # sign (e.g. Mi A3: charging reads NEGATIVE at full rate but POSITIVE when tapered near the
        # top), so the current-based status detection can land us in THIS not-charging branch while
        # the battery is actually charging ABOVE the limit -> the cap silently goes UNENFORCED and
        # the battery overshoots. The RAW battery status node IS reliable here, so use it as a
        # backstop TRIGGER: if it says Charging while online and at/above the pause level (debounced
        # one loop), force the pause directly. disable_charging can only STOP charging, never
        # overcharge, so this is always safe -- and it is a no-op on healthy devices, which never
        # reach this branch while genuinely charging above the limit.
        if online && _ge_pause_cap && [ "$(read_status)" = Charging ]; then
          _sh=$(cat $TMPDIR/.statusheal 2>/dev/null || echo 0); _sh=$((_sh + 1)); echo $_sh > $TMPDIR/.statusheal
          if [ $_sh -ge 2 ]; then
            disable_charging || :
            force_off
            # rc6 (H1): if forcing the pause repeatedly STILL does not stop charging, no switch on
            # this device holds the limit -- surface it ONCE (mirrors the charging-branch give-up)
            # rather than retrying silently forever.
            # rc4: warn ONLY when the cell has GENUINELY gone past the limit. On bypass/idle SoCs
            # (e.g. OnePlus op_disable_charge) the status node lies "Charging" while the battery
            # actually holds at 0A, which used to trip this give-up even though the switch works.
            # The capacity overshoot is the ground truth (skip the % test in millivolt mode, where
            # capacity[3] > 100).
            if [ $_sh -ge 8 ] && [ ! -f $TMPDIR/.statusheal-gaveup ] \
               && { [ "${capacity[3]:-100}" -gt 100 ] || [ "$(batt_cap)" -ge $(( ${capacity[3]:-100} + 2 )) ] 2>/dev/null; }; then
              touch $TMPDIR/.statusheal-gaveup
              warn_once_per nostop 21600 "⚠️ ACC: charging did not stop at your ${capacity[3]:-?}% limit; the battery went past it. In AccA, open the config editor and tap 'Find my charging switch'. This device may need a switch ACC does not have yet."
            fi
            _nap ${loopDelay[1]}
            continue
          fi
        else
          rm $TMPDIR/.statusheal $TMPDIR/.statusheal-gaveup 2>/dev/null || :
        fi

        # rc24: generic (non-Pixel) fresh-plug re-arm -- resume on re-plug without a reboot.
        generic_rearm || :

        if $xIdle && _le_pause_cap; then
          enable_charging
          disable_charging || :
          xIdle=false
          xIdleCount=$((xIdleCount + 1))
        # enable charging under <conditions>
        elif _le_resume_cap && [ $(temp_now) -le $(( ${temperature[2]} * 10 )) ]; then
          rm $TMPDIR/.forceoff* 2>/dev/null && sleep ${loopDelay[0]} || :
          _ccResume0=$(cc_now)
          # rc22: the temperature in this branch's own condition was read BEFORE the sleep above,
          # which runs whenever a force-off marker had to be cleared. Re-ask before actually
          # resuming, so no path in the daemon enables charging on a stale reading. The window is
          # narrow here -- the pack would have to cross from resume_temp past max_temp inside one
          # loopDelay -- but a guard on three of four re-enable paths and not the fourth is exactly
          # what made the original "charging resumes above max_temp" report so hard to find.
          _temp_hold || enable_charging
          # rc20: re-apply the charging-current limit IMMEDIATELY on resume. enable_charging
          # writes the switch's ON value, and on a current-class switch that ON value IS the
          # uncapped default (e.g. constant_charge_current_max 3000000 0), so the user's limit
          # was released and only restored on the next loop that reached the charging branch --
          # a multi-second window at full current, which users see as "my 1000 mA limit is
          # ignored every time it resumes" (field report). Idempotent: set_ch_curr skips nodes
          # already at target, so a healthy charge is undisturbed.
          [ ! -f $TMPDIR/.mcc-read ] || [ -z "${maxChargingCurrent[0]-}" ] \
            || (set_ch_curr ${maxChargingCurrent[0]} || :)
          # 6.5.1: below the resume level the intent is unambiguously to CHARGE, so release any
          # stray hard cut from ANY source (a killed test, a prior leak_backstop, an OEM app)
          # right here -- unconditionally, BEFORE the not_charging gate below. The status/current
          # nodes can false-read "charging" while a leftover input_suspend blocks real input (Mi A3:
          # current reads -1.5A while charge_counter stays flat), which made not_charging=false and
          # skipped the rc5 clear -> charging stayed dead until a reboot. enable_charging already put
          # the switch in its ON state, so clearing the cut family here only ever ALLOWS charging.
          # rc13: the release now covers BOTH polarities. A killed switch test (SIGKILLed AMPS/scan,
          # Android 15 phantom-process kills skip every trap) can leave an ENABLE-class node at 0
          # (e.g. battery/charging_enabled) that is not the configured switch -- enable_charging
          # never touches it and the 0-write cut sweep cannot revive it, so the phone sat plugged
          # and Draining until a manual restart (curtana field report). Writing the enable family
          # to 1 here is the same charge-allowing direction; during a hold above resume this code
          # does not run, so a pause is never broken. disable_charging joins the cut list (it was
          # already in the installer's fail-restore sweep, missed here).
          # 6.5.1-rc14 DEEP FIX: IDEMPOTENT revive -- only write a node that is NOT already at its
          # charge-allowing value. Re-writing the same value every loop re-triggers AICL / the
          # charge-pump FSM on fast-charge phones (PPS/PD/VOOC/QC-CP) -> fast charge collapses to the
          # main buck charger and never re-engages ("only slow/normal after ACC"). Read first: a node
          # the firmware drifted to a CUT value (!= target) is still re-armed, so the curtana stray-cut
          # revive is preserved; only redundant same-value pokes are skipped, so a healthy fast charge
          # is never disturbed. (Supersedes the rc14-test counter-gate: reading is more correct -- it
          # also re-arms a drifted node WHILE charging, which the gate skipped, and needs no state file.)
          # rc21: only sweep while a charger is actually attached.
          #
          # These two loops write "allow charging" to every node of their class. With no cable in
          # that achieves NOTHING electrically -- there is no input to allow -- but it is not
          # harmless: on some devices battery/charging_enabled=1 makes the KERNEL report
          # status=Charging with nothing plugged in. Android reads that node, so the system and
          # every third-party app announce charging while the battery icon (which reads the
          # separate */online nodes) correctly shows none. Field report on a fleur: dumpsys showed
          # "status: 2 (CHARGING)" next to "AC powered: false, USB powered: false", and removing
          # ACC fixed it. His resume_capacity was 80 with the battery at 56%, so this branch ran on
          # every single loop, holding the phantom status permanently.
          #
          # enable_charging already gates the same class of write on `present` for exactly this
          # reason (its unplug-blip note); this sweep simply never got the gate. Gating costs
          # nothing real: the stray-cut revive this exists for only matters when a charger is
          # there to be blocked, and the moment one is plugged in the sweep runs as before.
          if present; then
          for _di in */input_suspend */charge_disable */batt_slate_mode */op_disable_charge */disable_charging; do
            [ -w "$_di" ] || continue; [ "$(cat "$_di" 2>/dev/null)" = 0 ] || { _wlog "sweep $_di <- 0 (cut-release)"; echo 0 > "$_di" 2>/dev/null; } || :
          done
          for _en in */charging_enabled */battery_charging_enabled */charge_enabled */charging_enable */enable_charging */enable_charger; do
            [ -w "$_en" ] || continue; [ "$(cat "$_en" 2>/dev/null)" = 1 ] || { _wlog "sweep $_en <- 1 (enable-revive)"; echo 1 > "$_en" 2>/dev/null; } || :
          done
          fi
          # rc5 (#7): RESUME-side watchdog, symmetric to the rc19 breach monitor. enable_charging
          # wrote the switch ON value (+ the D8 rerun for current-cap), but on some current-cap
          # switches charging may STILL not restart -- an otherwise SILENT stall. If present and
          # at/below resume but still not_charging after a debounce, re-kick AICL/APSD; on
          # persistence, blacklist + reselect + notify. The first not_charging short-circuits the
          # whole test when charging is healthy, so there is zero latency on the happy path.
          if present && _le_resume_cap && not_charging && sleep ${loopDelay[1]:-9} && present && not_charging; then  # D8: was sleep 2 -- too short; a slow USB-PD switch resuming in 3-8s got falsely counted as failing -> blacklisted. Same ~9s settle as the pause side; the first not_charging still short-circuits with zero latency when healthy.
            # rc(6.4.1): the status node can read "not charging" while the cell IS gaining charge -- a
            # bypass/idle switch holds the battery idle (status is not "Charging" by design) and some ROMs
            # (OPLUS/OnePlus 8 Pro) lag or lie, made worse by a mis-latched polarity. The FUEL GAUGE is the
            # ground truth: if charge_counter climbed over the window, charging genuinely resumed -> this is
            # a FALSE "not resuming", so clear it (no warn, no apsd churn, no reselect). Fail-safe: cc_now=0
            # (node absent / signed) skips the gate, so phones without a usable charge_counter behave as before.
            if [ "${_ccResume0:-0}" -gt 0 ] && [ "$(cc_now)" -gt "$(( _ccResume0 + 1000 ))" ] 2>/dev/null; then
              rm $TMPDIR/.resumefail $TMPDIR/.resumewarned 2>/dev/null || :
            else
            for _di in */input_suspend */charge_disable */batt_slate_mode */op_disable_charge */disable_charging; do
              [ -w "$_di" ] || continue; [ "$(cat "$_di" 2>/dev/null)" = 0 ] || { _wlog "stall $_di <- 0"; echo 0 > "$_di" 2>/dev/null; } || :
            done
            for _en in */charging_enabled */battery_charging_enabled */charge_enabled */charging_enable */enable_charging */enable_charger; do
              [ -w "$_en" ] || continue; [ "$(cat "$_en" 2>/dev/null)" = 1 ] || { _wlog "stall $_en <- 1"; echo 1 > "$_en" 2>/dev/null; } || :
            done
            rekick_charger || :
            rf=$(cat $TMPDIR/.resumefail 2>/dev/null || echo 0); rf=$((rf + 1)); echo $rf > $TMPDIR/.resumefail
            if [ $rf -ge 4 ] && [[ "${chargingSwitch[*]-}" = *\ -- ]]; then
              # rc(6.4.1): tell "switch won't resume" apart from "charger died". If the cable is still
              # PRESENT but */online stayed 0 after the apsd_rerun above, the CHARGER de-negotiated (common
              # on qpnp-smb5 input-cut switches) -- the switch is FINE; only a REPLUG/reboot revives it, and
              # swapping switches just churns a good one. So warn REPLUG and DO NOT blacklist/reselect.
              # rc(6.4.1): these warnings now go through warn_once_per -> SILENT by default (logged to
              # warnings.log) and rate-limited; the protective apsd/blacklist/reselect actions still run.
              # Opt the popups back in with `acc -s warnings=on`.
              if present 2>/dev/null && ! online 2>/dev/null; then
                [ -f $TMPDIR/.resumewarned ] || { touch $TMPDIR/.resumewarned 2>/dev/null || :; warn_once_per resume-replug 1800 "⚠️ ACC: the charger stopped responding (online=0) at your ${capacity[2]:-?}% limit - UNPLUG and REPLUG the cable (or reboot) to resume. Your switch is fine; ACC won't change it."; }
              elif [ -f $dataDir/.user-locked ]; then
                # rc8: user-locked switch not resuming -> WARN, never auto-replace (respect the lock).
                [ -f $TMPDIR/.resumewarned ] || { touch $TMPDIR/.resumewarned 2>/dev/null || :; warn_once_per resume-locked 1800 "⚠️ ACC: charging isn't resuming at your ${capacity[2]:-?}% limit with your locked switch. Pick another in AccA - ACC will NOT change a locked switch."; }
              else
                echo "${chargingSwitch[*]% --}" >> $TMPDIR/.sw-blacklist
                warn_once_per resume-reselect 1800 "⚠️ ACC: charging is not resuming at your ${capacity[2]:-?}% limit - selecting another switch."
                $TMPDIR/acca $config --set charging_switch= 2>/dev/null || :; chargingSwitch=()
                rm $TMPDIR/.resumefail 2>/dev/null || :
              fi
            fi
            fi
          else
            # charging is healthy again -> drop the re-kick stamp too, so the NEXT genuine stall
            # gets its first kick immediately instead of waiting out a stale window.
            rm $TMPDIR/.resumefail $TMPDIR/.resumewarned $TMPDIR/.rekick-at 2>/dev/null || :
          fi
        fi

        # auto-shutdown
        if _uptime 900 && not_charging Discharging; then
          if [ ${capacity[0]} -ge 1 ]; then
            # warnings
            ! $shutdownWarnings || {
              if [ ${capacity[0]} -gt 3000 ]; then
                ! [ $(grep -o '^..' $voltNow) -eq $(( ${capacity[0]%??} + 1 )) ] \
                  || ! notif "⚠️ WARNING: ~100mV to auto shutdown, plug the charger!" \
                    || sleep ${loopDelay[1]}
              else
                ! [ $(batt_cap) -eq $(( ${capacity[0]} + 5 )) ] \
                  || ! notif "⚠️ WARNING: 5% to auto shutdown, plug the charger!" \
                    || sleep ${loopDelay[1]}
              fi
              shutdownWarnings=false
            }
            # action
            # rc21: AT MOST ONE low-battery shutdown per discharge episode.
            #
            # Powering the phone off at shutdown_capacity and then doing it again every 15 minutes
            # (_uptime 900 is the only thing that was holding it back) makes the device unusable
            # exactly when someone needs it most: flat battery, powered back on for an emergency
            # call. The threshold has already done its job once; after that the user has clearly
            # chosen to keep using the phone, and that choice is theirs, not the module's.
            #
            # The latch lives in dataDir, NOT tmpfs, and is deliberate: tmpfs is wiped every boot,
            # so a tmpfs latch would clear on exactly the power-on it exists to protect and the
            # phone would shut down again 15 minutes later - the bug this fixes.
            #
            # It re-arms on its own. The else branch below clears it as soon as the level is back
            # ABOVE the threshold, which only happens after a real charge, so the next flat
            # battery is treated as a new episode and gets its shutdown. Nothing is permanently
            # disabled and no config key changes, so AccA and every existing config are untouched.
            #
            # Scoped to the CAPACITY branch on purpose. shutdown_temp keeps firing every time:
            # repeated overheating is a genuinely repeating hazard, a flat battery is not.
            if _le_shutdown_cap; then
              if [ -f $dataDir/.sd-latched ]; then
                ${isAccd:-false} && command -v _wlog >/dev/null 2>&1 \
                  && _wlog "low-battery shutdown already fired this episode: leaving the phone on" || :
              else
                sleep ${loopDelay[1]}
                ! not_charging Discharging || {
                  : > $dataDir/.sd-latched 2>/dev/null || :
                  sync 2>/dev/null || :
                  shutdown
                }
              fi
            else
              rm -f $dataDir/.sd-latched 2>/dev/null || :
            fi
          fi
        fi
        # fix#293 (deep sleep): if genuinely unplugged and no shutdown action is
        # pending, wait much longer (interruptible) so the CPU can deep-sleep instead
        # of polling every ${loopDelay[1]}s. "No action pending" = shutdown_capacity
        # disabled (capacity[0] < 1) OR battery not yet near it (not _le_shutdown_cap);
        # in those cases the normal short nap bought us nothing but wakeups. Plug-in
        # and config edits still break the wait within ~1s (see _nap_idle). Anything
        # actionable (charger present, or at/below the shutdown threshold) keeps the
        # original short nap so shutdown/resume timing is never weakened.
        # rc9: gate the deep-idle nap on present (cable attached), not online -- an input-cut
        # switch holds online=0 while plugged, so a plugged-but-capped device used to enter
        # the 120s deep nap. _nap_idle's present check now breaks it in ~1s, but entering it
        # every loop churns the CPU; present here keeps a plugged device on the clean short nap.
        if ! present && { ! _le_shutdown_cap || [ "${capacity[0]:-0}" -lt 1 ] 2>/dev/null; }; then
          _nap_idle ${idleDelay:-120}
        elif present 2>/dev/null && _gt_resume_cap 2>/dev/null && [ ! -f $TMPDIR/.minCapMax ]; then
          # rc19 (standby): plugged and holding ABOVE the resume level = the overnight-on-
          # charger state. Nothing needs the 9s cadence until the level drifts down to
          # resume or the cable moves -- take the long fork-free hold (breaks on unplug
          # and config edits within ~1s; see _nap_hold).
          _nap_hold 30
        else
          _nap ${loopDelay[1]}
        fi
      fi
      rm $TMPDIR/.minCapMax 2>/dev/null || :
    done
  }


  force_off() {
    local f=$TMPDIR/.forceoff _pp=$$
    rm $f* 2>/dev/null || :
    $forceOff || return 0
    f=$f.$(date +%s)
    touch $f
    set +x
    # rc6 (B5): also stop if the parent daemon is gone. A SIGKILL skips exxit's flag cleanup,
    # so the tmpfs flag could otherwise orphan this background loop and keep current pinned at 0
    # (no charge) until reboot. kill -0 on the daemon pid ends the loop when the daemon dies.
    while [ -f $f ] && kill -0 $_pp 2>/dev/null && _gt_resume_cap; do
      flip_sw off || break
      sleep 1
    done &
    set -x
  }


  fast_session() {
    # rc20-alpha: is a PROPRIETARY fast-charge session live right now (VOOC/SuperDart, Xiaomi
    # HyperCharge/QC tiers, OPLUS fast_chg)? These sessions are fragile one-shot handshakes:
    # a switch toggle or a charge-node poke tears them down and the firmware falls back to
    # 500mA USB until a PHYSICAL replug. Detection is read-only builtin reads of the vendor
    # session nodes (cached list, computed at init). Test hooks: .fcguard-force pretends a
    # session is live (bench testing); .fcguard-off disables the guard entirely (A/B on the
    # tester's phone without reflashing).
    [ ! -f $TMPDIR/.fcguard-off ] || return 1
    [ ! -f $TMPDIR/.fcguard-force ] || return 0
    local _n= _v=
    for _n in ${_fcNodes:-}; do
      _v=
      { read -r _v < "$_n"; } 2>/dev/null || :
      case "$_n" in
        # alpha2: Xiaomi quick_charge_type idles at 1 on a plain 5V/9V charger -- only the
        # real fast tiers (>=2, HyperCharge/QC pump modes) count as a live session, so the
        # cooldown guard does not engage on an ordinary charge. (Verified on a Redmi Note 9S:
        # qct=1 while on a generic USB-PD brick with the pump never engaged.)
        */quick_charge_type) case "$_v" in ''|0|1|*[!0-9]*) :;; *) return 0;; esac;;
        *) case "$_v" in ''|0|*[!0-9]*) :;; *) return 0;; esac;;
      esac
    done
    return 1
  }


  mt_reached() {
    [ $(temp_now) -ge $(( ${temperature[1]} * 10 )) ] && mtReached=true
  }


  sync_native_limit() {
    # rc21: the blacklist has to reach HERE too. This path writes charge_stop_level /
    # charge_start_level with a raw echo, deliberately (see the idempotency note below), so it
    # never passes through write() and therefore never consulted the crash blacklist. On a Tensor
    # phone that meant blocking the node which had taken the phone down changed nothing: the
    # daemon kept writing it every loop. Device-proven on a Pixel 9a. Refusing to write is the
    # same trade-off the generic path makes, and it is safe in a way a cut switch is not: leaving
    # the firmware levels alone cannot strand the phone not charging, it only means the limit is
    # not held, which the warning says plainly.
    if command -v sw_blacklisted >/dev/null 2>&1 \
      && { sw_blacklisted "$gcsl" || sw_blacklisted "$gcst"; }
    then
      warn_once_per nativeblocked 21600 "ACC: this phone's firmware charge-limit control is on the blocked list, so ACC is not writing it. The limit is NOT being held. Remove it from Blocked settings to use it again."
      return 0
    fi
    # rc20: keep the firmware limit nodes in step with the user's pause/resume capacity.
    # The firmware charges to charge_stop_level, holds idle, and resumes at
    # charge_start_level. Temperature safety: at/above max_temp, force a pause by lowering
    # the stop level to the resume level; it self-restores once the battery cools.
    local stop=${capacity[3]:-80} start=${capacity[2]:-75} t _tl=
    # the firmware nodes are a percentage: clamp to [0..100] so a bad/out-of-range config
    # value can never be written raw to charge_stop_level / charge_start_level.
    case $stop in ''|*[!0-9]*) stop=80;; esac; [ "$stop" -le 100 ] || stop=100
    case $start in ''|*[!0-9]*) start=75;; esac; [ "$start" -le 100 ] || start=100
    t=$(cat $temp 2>/dev/null || echo 0)
    if [ "$t" -ge $(( ${temperature[1]:-50} * 10 )) ] 2>/dev/null; then
      # rc22: a thermal pause has to be BELOW the current level to be a pause at all. The firmware
      # charges until level >= charge_stop_level, so clamping stop to start only holds when the pack
      # already sits above start -- and below that it does nothing whatsoever. Measured on a Pixel 6a
      # at 38C against a 37C limit: stop=82, start=70, level=63, still drawing 1.2A with the
      # temperature limit supposedly in force. That is the whole limit silently absent for any
      # battery below its resume level, which is most of a charge.
      # Hold AT the present level instead, with start one point under it so the firmware does not
      # immediately resume. This is recomputed every loop, so as the pack drains the hold follows it
      # down, and it lifts on its own once the temperature drops back under max_temp.
      _tl=$(batt_cap 2>/dev/null)
      case "${_tl:-x}" in ''|*[!0-9]*) _tl=;; esac
      if [ -n "$_tl" ] && [ "$_tl" -lt "$start" ] 2>/dev/null; then
        stop=$_tl
        start=$_tl
        [ "$start" -le 0 ] 2>/dev/null || start=$(( start - 1 ))
      else
        # Already at or above start: clamping stop down to start does hold. Drop start a point too,
        # or stop and start are equal and the firmware resumes the instant the pack loses 1% -- while
        # it is still over max_temp.
        stop=$start
        [ "$start" -le 0 ] 2>/dev/null || start=$(( start - 1 ))
      fi
    fi
    # 6.5.1-rc14 DEEP FIX (Pixel/Tensor fast-charge + wireless): IDEMPOTENT native sync. Only
    # chmod+write a level node that is NOT already at target. Re-writing charge_start_level /
    # charge_stop_level (and the chmod) on EVERY loop re-triggers the google_charger MSC state
    # machine, which also gates the wireless (p9221) path via gcpm -> fast charge collapses and
    # wireless wedges ("hangs at charging", "stays Charging after lifting the phone off"). The
    # rc14 write() idempotency did NOT reach here: this path uses a raw echo, not write(). Reading
    # first is strictly safer -- a node the firmware drifted off target is still re-synced; only
    # redundant same-value pokes are skipped, so a healthy wired/wireless negotiation is never
    # disturbed. The values still change on a config edit, a thermal pause, or firmware drift.
    [ "$(cat $gcst 2>/dev/null)" = "$start" ] || { chmod 0644 $gcst 2>/dev/null || :; echo "$start" > $gcst 2>/dev/null || :; }
    if [ "$(cat $gcsl 2>/dev/null)" = "$stop" ]; then
      _nlDrift=0
    else
      chmod 0644 $gcsl 2>/dev/null || :; echo "$stop" > $gcsl 2>/dev/null || :
      # ACC is not the only thing that writes these nodes. Android's Adaptive
      # Charging and Google's Battery Defender manage the same firmware limit,
      # and when two owners disagree each correction re-triggers the
      # google_charger state machine -- the very thing the idempotent write above
      # exists to avoid (it collapses fast charge and wedges the wireless path).
      # A one-off correction is normal: a config edit, a thermal pause, or the
      # firmware settling. A sustained run of them means something else is
      # actively fighting, and the user is the only one who can resolve that.
      # Warning only; the limit itself is still enforced either way.
      _nlDrift=$(( ${_nlDrift:-0} + 1 ))
      if [ "${_nlDrift:-0}" -ge 20 ] 2>/dev/null; then
        _nlDrift=0
        warn_once_per nativedrift 21600 "ACC: something else keeps changing this phone's charge limit, and ACC keeps putting it back. That fight can break fast and wireless charging. Turn off Adaptive Charging (Settings > Battery > Charging optimisation > Standard) and let ACC own the limit." || :
      fi
    fi
  }


  leak_backstop() {
    # 6.5.1: ground-truth overcharge guard for the GENERIC switch path (the native
    # path has native_verify_backstop). batt_cap (coulomb-counted %) stays reliable
    # when the status/current nodes lie, so a cell sitting ABOVE the pause level
    # while plugged means the configured switch is LEAKING -- firmware overrode it
    # (e.g. Mi A3 charge_control_limit, which the PMI632 keeps re-arming to levels
    # that still charge). Engage a reversible hard input cut on a DIFFERENT node
    # than the switch (never fight the switch's own node) and REPORT holding (return
    # 0) so the caller skips the rest of the loop -- otherwise the daemon's own
    # re-arm/resume logic would clear the cut on the very next line and the two
    # would fight (filmed: is=1 then is=0 oscillation). Hysteresis: engage at
    # limit+2, keep holding until the cell drains to the limit or is unplugged.
    # Returns 1 (proceed normally) when the switch holds, below the limit,
    # unplugged, or in millivolt mode (capacity[3] > 100).
    local pause=${capacity[3]:-100} cap n sw0 _lbflip _lbrc
    [ "$pause" -le 100 ] 2>/dev/null || return 1
    cap=$(batt_cap) 2>/dev/null || return 1
    sw0="${chargingSwitch[0]-}"; sw0="${sw0##*/}"
    if ! present || [ "$cap" -le "$pause" ]; then
      [ -f $TMPDIR/.leakcut ] && {
        for n in input_suspend charge_disable batt_slate_mode op_disable_charge; do
          [ "$n" = "$sw0" ] && continue
          [ -w "battery/$n" ] && echo 0 > "battery/$n" 2>/dev/null || :
        done
        rm -f $TMPDIR/.leakcut 2>/dev/null || :
      }
      rm -f $TMPDIR/.leakbad.* 2>/dev/null || :
      return 1
    fi
    [ "$cap" -ge $(( pause + 2 )) ] || [ -f $TMPDIR/.leakcut ] || return 1
    # rc21: VERIFY the cut before claiming it holds. Writable != working: on an oplus
    # OnePlus 8 the only present candidate is input_suspend, which the firmware re-enables
    # (AMPS grades it "dropped current briefly then firmware RE-ENABLED -> would OVERCHARGE").
    # The old loop wrote it, returned 0 and reported "holding" while the cell kept climbing
    # past the limit, so the backstop silently became a no-op. Now: write, confirm charging
    # actually stopped, and if it did not, revert the node and move on to the next candidate.
    # A node that failed is marked for this boot (tmpfs) so the daemon does not re-write and
    # revert it on every loop; the marks clear with the cut when the cell is back at the limit.
    for n in input_suspend charge_disable batt_slate_mode op_disable_charge; do
      [ "$n" = "$sw0" ] && continue
      [ -w "battery/$n" ] || continue
      [ -f "$TMPDIR/.leakbad.$n" ] && continue
      # rc21: this is a RAW write, so it never passed through write()'s blacklist check and the
      # backup cut could seize a node that had already taken the phone down. Device-proven on a
      # Mi A3: seconds after the daemon released and dropped a blocked input_suspend, this loop
      # wrote 1 to it again and left charging cut by a node ACC may no longer touch. Same bypass
      # class as sync_native_limit on Tensor. The release loop above stays unconditional --
      # letting go of a node is always safe, taking one is not.
      if command -v sw_blacklisted >/dev/null 2>&1 && sw_blacklisted "battery/$n"; then continue; fi
      echo 1 > "battery/$n" 2>/dev/null
      # not_charging() consumes the global `flip` (flip_sw sets it, the next not_charging
      # eats it). This verification is an ad-hoc probe, NOT part of that handoff, so save
      # and restore it -- otherwise a pending flip context could be swallowed here.
      _lbflip="${flip-}"; not_charging; _lbrc=$?; flip="$_lbflip"
      if [ $_lbrc -eq 0 ]; then
        touch $TMPDIR/.leakcut
        warn_once_per leakcut 21600 "⚠️ ACC: your charging switch leaked past the ${capacity[3]:-?}% limit; holding a reversible input cut until the battery is back at the limit."
        return 0
      fi
      echo 0 > "battery/$n" 2>/dev/null || :
      : > "$TMPDIR/.leakbad.$n" 2>/dev/null || :
      warn_once_per "leakbad$n" 21600 "⚠️ ACC: the backup cut '$n' did not stop charging on this phone (firmware re-enabled it); trying the next one."
    done
    return 1
  }


  rekick_charger() {
    # rc21: RATE-LIMIT the stall re-kick. apsd_rerun/rerun_aicl force the charger to re-run input
    # detection. Firing it on every pass (measured 10x in 10 minutes on an oplus curtana) can
    # collapse a QC/HVDCP handshake back to 5V and leave the input settled around 1.8A, which the
    # owner sees as "my 9V charger only does 5V/2A". The FIRST kick still fires with no delay, so a
    # genuine stall recovers exactly as fast as before; only the repeats inside the window are
    # dropped. The .resumefail escalation counter is deliberately NOT touched, so the
    # warn/blacklist/reselect timing is unchanged. Stamp lives in tmpfs -> clears every boot.
    # Off switch, persistent (dataDir, not tmpfs) so it survives a reboot. The re-kick is what
    # recovers a stalled charger, but on a phone whose stall check misfires it is also what
    # collapses a fast-charge handshake, and the owner needs to be able to stop it without
    # editing scripts. `acc -sk off` writes this; `acc -sk on` removes it.
    [ ! -f $dataDir/.rekick-off ] || return 1
    local _now= _last= _gap=${REKICK_MIN_GAP:-300} _rn=
    _now=$(date +%s 2>/dev/null); case "${_now:-}" in ''|*[!0-9]*) _now=0;; esac
    _last=$(cat $TMPDIR/.rekick-at 2>/dev/null); case "${_last:-}" in ''|*[!0-9]*) _last=0;; esac
    if [ "$_now" -ne 0 ] && [ "$_last" -ne 0 ] && [ $(( _now - _last )) -lt "$_gap" ]; then
      _wlog "rekick suppressed ($(( _now - _last ))s since last, min ${_gap}s)"
      return 1
    fi
    for _rn in */apsd_rerun */rerun_aicl; do
      [ -w "$_rn" ] && { _wlog "rekick $_rn <- 1"; echo 1 > "$_rn" 2>/dev/null; } || :
    done
    [ "$_now" = 0 ] || echo "$_now" > $TMPDIR/.rekick-at 2>/dev/null || :
    return 0
  }


  native_verify_backstop() {
    # 6.5.1: the native %-limit is normally firmware-enforced, but a churned charge session
    # can ignore a retroactive stop write (probe-filmed on bramble). Verify the hold against
    # the FUEL GAUGE (charge_counter climbing = really charging, immune to lying status
    # labels): two consecutive climbing samples while >1% above the stop level -> hold a
    # reversible input cut each loop; restore it at/below the limit or on unplug. No-op on
    # phones without the node or the counter.
    local stop=${capacity[3]:-80} cap cc prev
    nvb_node=${NVB_NODE:-/sys/class/power_supply/usb/input_current_max}
    [ -f "$nvb_node" ] || return 0
    cap=$(batt_cap) || return 0
    if [ "$cap" -le $(( stop + 1 )) ] || ! online; then
      if [ -f $TMPDIR/.nvb-on ]; then
        chmod 0644 "$nvb_node" 2>/dev/null || :
        cat $TMPDIR/.nvb-restore > "$nvb_node" 2>/dev/null || :
        rm -f $TMPDIR/.nvb-on 2>/dev/null || :
      fi
      nvb_count=0; rm -f $TMPDIR/.nvb-cc 2>/dev/null || :
      return 0
    fi
    cc=$(cat ${NVB_CC:-/sys/class/power_supply/battery/charge_counter} 2>/dev/null) || return 0
    case "$cc" in ''|*[!0-9-]*) return 0;; esac
    prev=$(cat $TMPDIR/.nvb-cc 2>/dev/null || echo "")
    echo "$cc" > $TMPDIR/.nvb-cc
    [ -n "$prev" ] || return 0
    if [ "$cc" -gt $(( prev + 2000 )) ] 2>/dev/null; then
      nvb_count=$(( ${nvb_count:-0} + 1 ))
    else
      nvb_count=0; return 0
    fi
    [ ${nvb_count:-0} -ge 2 ] || return 0
    [ -f $TMPDIR/.nvb-on ] || { cat "$nvb_node" > $TMPDIR/.nvb-restore 2>/dev/null || echo 2000000 > $TMPDIR/.nvb-restore; }
    chmod 0644 "$nvb_node" 2>/dev/null || :
    echo 0 > "$nvb_node" 2>/dev/null && touch $TMPDIR/.nvb-on
    warn_once_per nvbackstop 21600 "⚠️ ACC: the firmware ignored the native charge limit (still charging past ${capacity[3]:-?}%); holding a reversible input cut until the battery is back at the limit."
  }


  native_unlatch() {
    # rc23 (stable.6.2): the Tensor google,charger driver LATCHES "stopped" once
    # charge_stop_level is reached and does NOT reliably re-arm at charge_start_level
    # (an upstream Google/Tensor bug -- reproduced on Pixel 6..10 and even with no ACC
    # installed; only a reboot or a write of exactly 100 to charge_stop_level clears it).
    # rc20 delegated resume to that firmware, so after the limit was hit the battery would
    # not resume on re-plug and the user had to REBOOT. Here we detect the latched state
    # and pulse charge_stop_level=100 (the only value that re-arms the FET), then let
    # sync_native_limit restore the real stop on the very next line, so we never linger at
    # 100 (no overshoot). Re-arm only on:
    #   (a) a FRESH plug-in (offline->online this loop) while below the limit -- the user
    #       just connected the charger and expects a top-up to the limit; or
    #   (b) capacity at/below resume_capacity -- where the firmware SHOULD have resumed.
    # NEVER in the steady [resume..pause] idle band (no sawtooth -- hysteresis preserved),
    # and NEVER when the kernel already reports Charging (self-disabling on healthy
    # firmware -- a phone whose driver resumes correctly is left completely untouched).
    # Fail-safe: a spurious pulse can only let the cell charge a little toward the limit
    # that sync_native_limit still enforces -- it can never overcharge or disable the cap.
    # rc24: $freshPlug is computed once per loop by the shared plug-transition tracker.
    online || return 0
    # rc21: skip entirely when the firmware nodes are on the crash blacklist. These two writes are
    # raw echoes, so like sync_native_limit they never pass through write() and never saw the list.
    # A release is normally exempt (a cut is what strands a phone, not a release), but this is not a
    # one-off release: it re-pulses on every fresh plug, so a node that has already taken the phone
    # down would be written again and again. sync_native_limit refuses to re-apply the limit while
    # blacklisted anyway, so the un-latch has nothing left to restore -- pulsing is pure risk with
    # no benefit. Caught on a Pixel 9a, where charge_stop_level moved 75 -> 100 while blocked.
    if command -v sw_blacklisted >/dev/null 2>&1 \
      && { sw_blacklisted "$gcsl" || sw_blacklisted "$gcst"; }
    then
      return 0
    fi
    # RESOLVED 2026-08-04. This was recorded on 2026-07-31 as a KNOWN GAP: "raising pause while the
    # firmware is latched does not resume charging; the phone stays at 0 mA until it drains to
    # resume_capacity". It was misattributed. The daemon was frozen, not the firmware -- on a
    # native-limit phone with allow_idle_above_pcap=false the loop fell through to the generic switch
    # prober and stopped running entirely, so nothing was writing charge_stop_level at all. With that
    # fixed, re-measured at the exact conditions in the original note (pause set equal to the level,
    # then raised): the phone latched, the raise took effect within 25s, and charging resumed at
    # 1.2A without draining to resume. The loop was verified alive throughout.
    #
    # The measurements below (stop=100 alone, stop=100 + start>SOC, bd_clear=1) were all taken
    # against that frozen daemon and prove nothing either way. Kept only as a record of what was
    # tried; do not treat them as evidence about the firmware.
    #
    # Do NOT "fix" this by pulsing charge_stop_level/charge_start_level without testing on
    # hardware first. Measured, with the DAEMON STOPPED so nothing could revert the writes:
    #   stop=100 alone            -> still latched
    #   stop=100 + start=74 (>SOC)-> still latched (charge_counter frozen for 70 s)
    #   bd_clear=1                -> still latched
    # so the "only a write of 100 re-arms the FET" note above is not sufficient on its own, and
    # an attempted fix along those lines was reverted rather than shipped unverified. A physical
    # unplug/replug does clear it, which is why the freshPlug path works. The actual trigger is
    # still unidentified; charging_status=31 and the bd_* Battery Defender block are unexplored.
    # rc22: never pulse while a thermal pause is in force. The pulse below sets charge_stop_level
    # to 100 -- no limit at all -- and then SLEEPS a full loopDelay before sync_native_limit pulls
    # it back. On a pack over max_temp that is a ~10s window of unrestricted charging, and
    # _le_resume_cap is true on every loop while the level sits below resume, so it repeats
    # indefinitely. Measured on a Pixel 6a at 38C against a 37C limit: charge_stop_level read 100
    # and the pack took 913mA for a whole 20s window with the temperature limit supposedly active.
    #
    # An earlier attempt at this guard was reverted on 2026-08-04 after an A/B appeared to show it
    # latching charge_stop_level at its old value. That A/B was confounded: the daemon was frozen in
    # the generic switch prober at the time (see the allow_idle_above_pcap fall-through), so nothing
    # was updating the node in either build -- the "unguarded" comparison only looked healthy
    # because it ran on a freshly restarted daemon. With the freeze fixed the guard cannot starve a
    # raised limit: sync_native_limit runs unconditionally on the line BEFORE native_unlatch every
    # loop, so a config change is already applied by the time this is reached.
    ! _temp_hold || return 0
    if { $freshPlug && _lt_pause_cap; } || _le_resume_cap; then
      [ "$(read_status)" = Charging ] && return 0 || :
      # rc(6.4-rc2): stop=100 ALONE re-arms the Tensor FET only SLOWLY (1-3 min via the
      # charger state machine + PD renegotiation -- measured on Pixel 9a/tegu, where the
      # cell stayed not-charging for minutes). The firmware resumes immediately when its
      # own condition capacity <= charge_start_level is met, so also raise start_level
      # above the current SOC for the pulse; sync_native_limit restores the real start on
      # the next line, so there is no overshoot and the cap is never disabled.
      chmod 0644 $gcsl $gcst 2>/dev/null || :
      echo 100 > $gcst 2>/dev/null || :
      echo 100 > $gcsl 2>/dev/null || :
      sleep ${loopDelay[0]}
      sync_native_limit
    fi
  }


  generic_rearm() {
    # rc24 (stable.6.3): generic (non-Pixel) counterpart to native_unlatch. Some charging
    # switches (input_suspend, */current_max 0, */charging_enabled 0, etc.) hold their
    # "off" state across an unplug/replug, so after the limit is hit, re-plugging does not
    # resume charging until capacity falls to resume_capacity -- or, on switches that latch,
    # until a REBOOT (the reported Motorola/Qualcomm symptom: stops correctly at the limit,
    # then will not resume on re-plug). On a genuine plug-in (freshPlug) below the limit we
    # re-arm at once via enable_charging, which writes the switch ON value and is itself
    # online-gated. Skipped on the boot loop (.minCapMax present) so it never fights
    # off_mid_charge, and one-shot per plug (freshPlug) so it cannot sawtooth. Native
    # (google,charger) devices use native_unlatch instead and are excluded here.
    $nativeLimit && return 0 || :
    $freshPlug || return 0
    [ ! -f $TMPDIR/.minCapMax ] || return 0
    _lt_pause_cap || return 0
    # rc22: a fresh plug below the capacity limit is not a reason to charge a pack that is over
    # max_temp. Without this, re-plugging a hot phone re-arms the switch and the thermal pause has
    # to fight it back off on the next loop. See _temp_hold.
    ! _temp_hold || return 0
    online || return 0
    enable_charging
  }


  pause_now() {
    capacity[3]=$(batt_cap)
    capacity[2]=$((capacity[3] - 5))
    [ ${capacity[2]} -ge 0 ] || capacity[2]=0   # rc5 (#11): clamp resume_capacity >=0 at very low SOC
  }


  # rc21: defensive config load. AccA and `acc -s` publish config.txt atomically,
  # but a TERMINAL user or ANOTHER APP can write it non-atomically - `echo > `,
  # `sed -i`, or a write killed half-way - and leave it TRUNCATED at the instant
  # the daemon sources it. A truncated file is a shell syntax error: a plain
  # `. $config` then either aborts the daemon (device-proven: sustained external
  # writes killed it) or skips a loop's enforcement. Never trust the raw file
  # blindly: source with errors suppressed so a broken file can never abort us,
  # then require a usable capacity array (>=4 fields). If it is missing - a
  # partial/truncated read - fall back to the last KNOWN-GOOD config so
  # enforcement always runs on a complete, consistent config and the limit is
  # never dropped. The good copy is refreshed only when capacity actually changes,
  # so a steady-state loop does no extra work (no per-loop fork; matters for
  # standby). Values that are merely out of range are still coerced by the inline
  # guards elsewhere; this guards the STRUCTURE of the file, not the values.
  # rc21: the FALLBACK needs the same parse test as the config itself. _srccfg used to source
  # .config-good blind, which reopens the exact hole it exists to close: that file is written
  # with `cat $config > .config-good`, so a truncated read, a full /data, or a crash mid-copy
  # leaves a half-written fallback -- and sourcing THAT is a parse error, fatal in mksh, killing
  # the daemon at the moment it is trying to recover. Test it in a throwaway subshell first
  # (exit trap cleared so its abort has no side effects); if even the fallback is unusable, keep
  # whatever config is already in memory rather than abort. Enforcement continues either way.
  _srcgood() {
    [ -f $dataDir/.config-good ] || return 0
    if ( trap - EXIT; . $dataDir/.config-good ) 2>/dev/null; then
      . $dataDir/.config-good 2>/dev/null || :
    else
      rm -f $dataDir/.config-good 2>/dev/null || :   # poisoned: never trust it again
    fi
  }

  _srccfg() {
    # Sourcing a config with a SYNTAX error (a truncated / half-written file from a
    # non-atomic external writer -- e.g. an unclosed `capacity=(` left by `echo >`,
    # `sed -i`, or a third-party app killed mid-write) is FATAL in mksh: the parse
    # error aborts the shell and fires the exit trap (exxit) BEFORE `2>/dev/null ||
    # :` can act. A redirect and an `|| :` guard only catch RUNTIME failures; a
    # PARSE-time error is not catchable that way. Confirmed on a Pixel 9a (Tensor,
    # native-limit path): the daemon died right at `. $config` on a config LEFT
    # truncated, xtrace showing 1282:. $config -> exxit. So do not source a file
    # blind. Test that it PARSES in a throwaway subshell first (exit trap cleared so
    # the subshell's own abort has no side effects and never runs exxit); only source
    # it for real in the live shell once it is known well-formed. A broken file thus
    # never reaches the live shell, and we keep enforcing from the last complete
    # config we saw. A usable capacity array has >=4 space-joined fields (shutdown
    # cooldown resume pause [mask]); tested with a case-glob, not `set --`, so the
    # caller's positional params are untouched.
    if ( trap - EXIT; . $config ) 2>/dev/null; then
      . $config 2>/dev/null || :
      case "${capacity[*]-}" in
        *' '*' '*' '*)
          if [ "${capacity[*]}" != "${_cfggood-}" ]; then
            cat $config > $dataDir/.config-good 2>/dev/null || :
            _cfggood="${capacity[*]}"
          fi
        ;;
        *)
          _srcgood
        ;;
      esac
    else
      # config does not even parse -- never source it into the live shell. Fall back
      # to the last complete config; if we have none yet, leave the in-memory config
      # as-is rather than abort.
      _srcgood
    fi
  }

  set_dp() {
    local curr= i= pos=0 neg=0 _force_relatch=0 _c0= _c1=
    _srccfg
    # _srccfg just re-sourced the config, so a chargingSwitch blocked since the last pass (AMPS
    # writes the list mid-run) is back in scope here. Re-check, or the daemon keeps a node the
    # write choke point refuses and holds nothing while reporting nothing.
    command -v _drop_blocked_sw >/dev/null 2>&1 && _drop_blocked_sw || :
    # skip if the status workaround is off or there is no usable current sensor
    { $battStatusWorkaround && [ $currFile != $TMPDIR/.dummy-mcc ]; } || return 0
    # rc6 (L1): latch the discharge polarity ONLY from a CONFIRMED "Charging" status -- that
    # is the one unambiguous moment (we KNOW charging, so the current sign IS the charge
    # direction). The old code ALSO inferred polarity from a non-Charging status; right after a
    # pause-release the status lags the current sign, so it latched the WRONG polarity -> the
    # daemon then read this device's steady +current as Discharging and NEVER enforced the limit
    # (silent overcharge). And _DPOL is cached in .batt-interface.sh, so a plain restart kept the
    # bad value (only --init recomputed it). If not clearly charging this loop, leave _DPOL unset
    # and try again next loop -- never guess from a transient.
    # 6.4.1: once latched, SELF-HEAL a cache that is wrong. Skip the costly 5s re-sample unless
    # a single LARGE, unambiguous live sample taken during confirmed Charging contradicts the
    # cached sign; only then fall through and re-latch. Recovers a _DPOL mis-latched on one
    # phone/Android rev (seen on Pixel / Android 17, where charging read as Discharging) with no
    # per-loop overhead and no flip-flop on noise -- a small current is ignored, so the rc6
    # silent-overcharge guard is preserved.
    if [ -n "${_DPOL-}" ]; then
      curr=$(cat $currFile 2>/dev/null)
      case ${curr:-x} in ''|x|*[!0-9-]*) return 0;; esac
      [ ${curr#-} -ge 16000 ] 2>/dev/null || return 0
      if [ "$(cat $battStatus 2>/dev/null)" != Charging ]; then
        # D9: the status node may LIE (the very reason battStatusWorkaround exists). Don't blindly return:
        # only when a large current is present while PLUGGED and the fuel gauge is genuinely RISING
        # (status-independent proof of charging) do we keep checking; otherwise trust status and return.
        # This heals a _DPOL mis-latched on phones whose status never reads "Charging" while charging --
        # the silent-overcharge case the original status-only gate could never recover. Rare path: on a
        # healthy phone status==Charging so this branch (and its sleep) never runs.
        { online 2>/dev/null || present 2>/dev/null; } || return 0
        _c0=$(batt_cap); sleep 3; _c1=$(batt_cap)
        [ "${_c1:-0}" -gt "${_c0:-0}" ] 2>/dev/null || return 0
        curr=$(cat $currFile 2>/dev/null); case ${curr:-x} in ''|x|*[!0-9-]*) return 0;; esac
        [ ${curr#-} -ge 16000 ] 2>/dev/null || return 0
      fi
      case "$curr" in
        -*) [ "$_DPOL" = + ] && return 0;;   # negative current, _DPOL=+ (charging is -) -> agrees
        *)  [ "$_DPOL" = - ] && return 0;;   # positive current, _DPOL=- (charging is +) -> agrees
      esac
      # rc13: on MODE-DEPENDENT-sign hardware (dual-path PMIC, curtana: 5V path positive / 9V
      # path negative, both genuinely charging) every contract change would trigger this re-latch
      # and the polarity would flip-flop forever, each latch wrong for the other mode. Once the
      # coulomb arbitration in idle_discharging has proven the sign unstable (marker), stop
      # re-latching: the charge_counter slope owns charge/discharge truth from then on and the
      # cached sign is only a magnitude hint.
      [ ! -f $TMPDIR/.dpol_unstable ] || return 0
      _force_relatch=1
      # a large sample disagrees with the cached polarity during proven charging -> re-latch
    fi
    set +x
    if [ "$(cat $battStatus 2>/dev/null)" = Charging ] || [ "$_force_relatch" = 1 ]; then
      # sample the (noisy) current a few times; require a consistent sign before committing
      for i in 1 2 3 4 5; do
        curr=$(cat $currFile 2>/dev/null)
        case ${curr:-x} in
          -*) neg=$((neg + 1));;
          ''|x|*[!0-9-]*|0) ;;
          *) pos=$((pos + 1));;
        esac
        sleep 1
      done
      if   [ $pos -ge 3 ]; then sdp -
      elif [ $neg -ge 3 ]; then sdp +
      elif [ -z "${_DPOL-}" ] && [ $((pos + neg)) -eq 0 ]; then
        # charging but current reads zero/unreadable = no usable current sensor; fall back to
        # the raw battery status (same intent as the old curr==0 path).
        /dev/acca --set batt_status_workaround=false
      fi
    fi
    set -x
  }


  shutdown() {
    # rc21: NEVER power the device off during offline charging. The phone is already off with the
    # cable in, running Android's `charger` binary and showing the battery icon. That path is a
    # last-resort safety net owned by the framework and the kernel: whatever ACC's limits say, a
    # user must always be able to shut the phone down and charge it. Someone who sets resume to
    # 10% and lets the battery run flat depends on exactly this to get the phone back.
    #
    # ACC's shutdown exists to protect a RUNNING system from deep discharge or heat. In charger
    # mode there is no runtime to protect, and the real cutoffs (PMIC low-voltage, kernel thermal)
    # are still in force underneath. So the only thing acting here could do is kill a charge the
    # user deliberately started. Same reasoning and same chokepoint placement as the cut guard in
    # disable_charging: one check inside the function every caller routes through, so no future
    # caller can miss it.
    if command -v in_charger_mode >/dev/null 2>&1 && in_charger_mode; then
      echo "=== $(date '+%Y-%m-%d %H:%M:%S') accd shutdown REFUSED: offline charging mode" \
        >> $dataDir/logs/shutdown-trace.log 2>/dev/null || :
      return 0
    fi
    # rc21: record WHY before acting. Powering the phone off is the most drastic thing this
    # module does, and until now it left no trace at all -- a user whose phone shut down had
    # nothing to look at, and neither did we. Three Mi A3 power-offs were chased through pstore,
    # tombstones and dmesg precisely because this line was silent. The record is written and
    # sync'd BEFORE the power-off so it survives it, and every read is guarded so a failure here
    # can never be the reason the safety shutdown does not happen.
    {
      echo "=== $(date '+%Y-%m-%d %H:%M:%S') accd shutdown"
      echo "    level=$(batt_cap 2>/dev/null) temp=$(temp_now 2>/dev/null) status=$(cat $battStatus 2>/dev/null)"
      echo "    capacity=(${capacity[*]-}) temperature=(${temperature[*]-})"
      echo "    switch=(${chargingSwitch[*]-})"
    } >> $dataDir/logs/shutdown-trace.log 2>/dev/null || :
    sync 2>/dev/null || :
    /system/bin/am start -n android/com.android.internal.app.ShutdownActivity < /dev/null > /dev/null 2>&1 \
      || /system/bin/reboot -p \
      || reboot -p || :
  }


  mask_capacity() {

    is_android || return 0

    local battCap= maskedCap= plug=0 t= lastPlug= lastCap= lastT= n=

    if ${capacity[4]:-false} && [ ${capacity[3]} -le 100 ] && [ ${capacity[3]:-0} -gt ${capacity[0]:-0} ]; then
      # the && pause>shutdown guard prevents a divide-by-zero in the masked-capacity
      # formula below when pause_capacity == shutdown_capacity.
      # rc19 (standby): change-gated. The three dumpsys writes (plus the calc/awk spawn
      # chain) ran EVERY loop around the clock. Now: plug state on transitions, level when
      # the kernel percent moves, temp on a >=0.3 C move -- and a full re-assert every 20th
      # pass, so an external `dumpsys battery reset` can never leave the mask silently dead.
      # The tmpfs marker (.mask-on) records that BatteryService holds our overrides, so the
      # off-path and the exit trap reset only when something was actually set (a daemon
      # reload can no longer strand a frozen status bar either).
      battCap=$(batt_cap)
      present 2>/dev/null && plug=1 || plug=0
      t=$(temp_now)
      { read -r lastPlug lastCap lastT < $TMPDIR/.mask-last; } 2>/dev/null || :
      { read -r n < $TMPDIR/.mask-n; } 2>/dev/null || n=0
      case ${n:-0} in ''|*[!0-9]*) n=0;; esac
      n=$((n + 1))
      if [ $n -ge 20 ] || [ ! -f $TMPDIR/.mask-on ]; then
        lastPlug=; lastCap=; lastT=; n=0
      fi
      echo $n > $TMPDIR/.mask-n 2>/dev/null || :

      if [ ".$plug" != ".$lastPlug" ] || [ ".$battCap" != ".$lastCap" ] \
        || [ $(( t - ${lastT:-99999} )) -ge 3 ] 2>/dev/null || [ $(( ${lastT:-99999} - t )) -ge 3 ] 2>/dev/null
      then
        if [ ${capacity[0]} -le 0 ]; then
          maskedCap=$(calc $battCap \* 100 / ${capacity[3]} | xargs printf %.f)
        else
          maskedCap=$(calc "($battCap - ${capacity[0]}) * 100 / (${capacity[3]} - ${capacity[0]})" | xargs printf %.f)
        fi

        [ $maskedCap -le 100 ] || maskedCap=100
        [ $maskedCap -ge 2 ] || maskedCap=2

        # rc18: the spoofed plug state follows the PHYSICAL cable (present/online), not isCharging.
        # isCharging mis-reads on inverted-polarity / bypass phones (charging reads negative; a bypass
        # switch reports status=Charging while the battery is idle), so after an unplug the daemon kept
        # writing 'set ac 1' and the status bar froze on 'charging' (the mask uses dumpsys battery set,
        # which stops Android's own battery updates). present() is the physical truth, and during a
        # cooldown pause the cable is still attached, so it correctly stays 'plugged'.
        [ $plug = 1 ] && dsys_batt set ac 1 || dsys_batt unplug
        dsys_batt set level $maskedCap
        dsys_batt set temp $t
        touch $TMPDIR/.mask-on 2>/dev/null || :
        echo "$plug $battCap $t" > $TMPDIR/.mask-last 2>/dev/null || :
      fi

    else
      # rc19: with the mask OFF this used to fire `dumpsys battery reset` every loop,
      # forever, to clear overrides that were never set. Reset once on the on->off
      # transition, then do nothing at all.
      # rc20 CRITICAL: gate on .dsys-override (set by dsys_batt for ANY set/unplug), not on
      # the mask marker. The cooldown cycle freezes Android's battery state too, and gating
      # on the mask alone left that freeze permanent - level stuck, "charging" shown after
      # unplug, and the limit unable to fire (overcharge). This restores the pre-rc19
      # guarantee (Android is always un-frozen when the mask is off) while keeping rc19's
      # drain fix: with nothing frozen there is no marker, so no dumpsys call at all.
      if [ -f $TMPDIR/.dsys-override ]; then
        dsys_batt reset >/dev/null
        rm -f $TMPDIR/.mask-on $TMPDIR/.mask-last $TMPDIR/.mask-n 2>/dev/null || :
      fi
    fi
  }


  # load generic functions
  . $execDir/misc-functions.sh

  # rc21: a CONFIGURED switch bypasses the candidate list entirely, so blocking the node you
  # are currently using had no effect: the daemon kept flipping it. Drop it back to automatic
  # instead of refusing the writes -- refusing them would also block enable_charging from
  # turning charging back ON, which is how a phone ends up stuck not charging. Cleared here,
  # the auto-locker picks a candidate that is not blocked, and if none exists the breach
  # monitor says the limit is not held rather than pretending it is.
  # This ran here in the first cut, which was ~80 lines BEFORE `_srccfg` loads the config that
  # defines chargingSwitch. ${chargingSwitch[0]-} was therefore always empty, the guard below
  # short-circuited, and the whole feature was dead: device-proven on a Mi A3, where a blocked
  # configured switch stayed in config.txt across two reboots with no warning ever logged.
  # It is a function now, called after the config load and again every loop, because AMPS
  # writes the blacklist WHILE the daemon is running -- that is exactly when a node gets
  # blocked -- and a once-at-init check can never see it. Costs nothing when nothing is
  # blocked: sw_blacklisted returns on the first [ -s ] with no fork.
  _drop_blocked_sw() {
    command -v sw_blacklisted >/dev/null 2>&1 || return 0
    [ -n "${chargingSwitch[0]-}" ] || return 0
    sw_blacklisted "${chargingSwitch[0]}" || return 0
    warn_once_per swblocked 21600 "ACC: your selected charging switch (${chargingSwitch[0]##*/}) is on the blocked list, so it is not being used. ACC will pick another. Remove it from Blocked settings to use it again."
    # Release it ONCE before letting go, so a switch blocked while it was holding a cut cannot
    # leave the phone unable to charge. After this the node is never written again.
    _BLRELEASE=1 flip_sw on >/dev/null 2>&1 || :
    unset _BLRELEASE
    # Persist, then CHECK. The write was fully error-suppressed before, so a failure left the
    # blocked node in config.txt and every restart resurrected it while the daemon silently
    # refused to use it -- a limit that is not enforced and never says so. Fall back to editing
    # the line directly (per-process temp, atomic rename) and warn if even that does not land.
    if [ -x $TMPDIR/acca ]; then
      $TMPDIR/acca $config --set charging_switch= >/dev/null 2>&1 || :
    else
      $execDir/acc.sh $config --set charging_switch= >/dev/null 2>&1 || :
    fi
    if grep -q '^chargingSwitch=([^)]' $config 2>/dev/null; then
      _dbt=$config.$$.blsw
      sed 's/^chargingSwitch=(.*/chargingSwitch=()/' $config > $_dbt 2>/dev/null \
        && [ -s $_dbt ] && mv -f $_dbt $config 2>/dev/null || rm -f $_dbt 2>/dev/null
    fi
    grep -q '^chargingSwitch=([^)]' $config 2>/dev/null \
      && warn_once_per swblockedcfg 21600 "ACC: could not clear the blocked charging switch from the config. The limit is NOT being held. Remove it from Blocked settings, or run: acc -s charging_switch=" \
      || :
    chargingSwitch=()
  }

  xIdle=false
  xIdleCount=0
  chDisabledByAcc=false
  chgStatusCode=""
  cooldown=false
  dischgStatusCode=""
  export isAccd=true   # D7: export so the daemon's own `acca --set` subprocesses are recognized as daemon-originated (write-config must not clear a user lock on a daemon write)
  # rc19 (standby): wake fifo. Every nap ticks on a timed builtin read of this fifo (zero
  # forks per second, replacing sleep+stat spawns); writing anything to $TMPDIR/.wake wakes
  # the daemon instantly (future front-end nudge). Survives the exec-reload (fd 9 inherited;
  # the -p guard skips a re-mkfifo). Falls back to sleep ticks if mkfifo is unavailable.
  # rc20 CRITICAL (clean slate): un-freeze Android's battery state ONCE at daemon start,
  # unconditionally. A marker only covers freezes THIS daemon caused - it cannot know about
  # one inherited from a previous version (rc19 froze via the cooldown cycle and left no
  # marker, so an upgrade would stay frozen forever: level stuck, "charging" after unplug,
  # limit unable to fire), nor one left by a third-party app or a SIGKILLed switch test.
  # One dumpsys per daemon start is free; from here the marker keeps the loop silent.
  dsys_batt reset >/dev/null 2>&1 || :
  rm -f $TMPDIR/.dsys-override $TMPDIR/.mask-on $TMPDIR/.mask-last $TMPDIR/.mask-n 2>/dev/null || :

  hasWakeFifo=false
  [ -p $TMPDIR/.wake ] || mkfifo $TMPDIR/.wake 2>/dev/null || :
  if [ -p $TMPDIR/.wake ]; then
    { exec 9<>$TMPDIR/.wake; } 2>/dev/null && hasWakeFifo=true || hasWakeFifo=false
  fi
  # rc20-alpha: proprietary fast-charge session nodes (see fast_session). Computed once; a
  # phone without any of these never pays more than this one init scan.
  # LIVE-SESSION indicators only. Each one below was observed in a field report MOVING with the
  # session (voocchg_ing 1->0 and fast_chg_type 20->0 the moment charging stopped), or carrying a
  # session tier (quick_charge_type). `fastcharge_mode` is deliberately NOT here: it read 0 on a
  # Xiaomi that was actively charging, so there is no evidence it reports a live session, and on
  # several ROMs a node by that name is a user-facing "fast charge" SETTING. Treating a setting as
  # a session would skip cooldown for everyone who ticked that box - a silent behaviour change on
  # phones with no fast-charge problem at all. Leaving it out cannot cost anything: the confirmed
  # fix works through the three below.
  _fcNodes=
  for _fn in usb/quick_charge_type \
    /sys/class/oplus_chg/battery/voocchg_ing /sys/class/oplus_chg/usb/fast_chg_type; do
    [ -f "$_fn" ] && _fcNodes="$_fcNodes $_fn"
  done
  mtReached=false
  resetBattStatsOnPlug=false
  resetBattStatsOnUnplug=false
  restrictCurr=false
  shutdownWarnings=true
  unsolicitedResumes=0
  wasOnline=false  # rc23: native_unlatch plug-transition tracker (false at start so a
                   # latched-from-before state is recovered on the first loop)
  versionCode=$(sed -n s/versionCode=//p $execDir/module.prop 2>/dev/null || :)


  if [ "${1:-y}" = -x ]; then
    log=/sdcard/Download/accd-${device}.log
    persistLog=true
    shift
  else
    log=$TMPDIR/accd-${device}.log
    persistLog=false
  fi


  # verbose
  [ -z "${LINENO-}" ] || export PS4='$LINENO: '
  echo "###$(date)###" >> $log
  exec >> $log 2>&1
  set -x


  misc_stuff "${1-}"
  . $execDir/oem-custom.sh
  _srccfg   # rc21: parse-safe load. A truncated/half-written external config can never abort init now -- _srccfg test-parses in a subshell and falls back to last-good (values coerced below)

  # rc21: settings that are legal, get applied exactly as asked, and then quietly cost the user
  # something they never connected to the setting. Both come from real reports where the person
  # could not have worked it out: nothing in ACC or the app said a word. Warnings only -- no
  # value is changed, no behaviour is altered, and warn_once_per keeps them to once a day.
  config_sanity() {
    # --- a charge-voltage cap far below the cell's own maximum wrecks the fuel gauge ---
    # A gauge re-anchors its charge estimate when the cell reaches termination voltage. Capped
    # well below that it never terminates, never re-anchors, and its reading drifts upward with
    # nothing to correct it. Pixel 3a, capped 3900 against a recorded 4200: the gauge claimed 78%
    # while the coulomb counter said 47% and the cell sat at 3.71 V -- reported as "the indicator
    # is stuck above my limit", which is what an over-reading gauge looks like near a cap.
    # The original is not guessed: set_ch_volt records it in the entry as node::capped::original.
    _mv="${maxChargingVoltage[0]-}"
    case ${_mv:-x} in ''|x|*[!0-9]*) _mv="";; esac
    if [ -n "$_mv" ] && [ -n "${maxChargingVoltage[1]-}" ]; then
      _orig="${maxChargingVoltage[1]##*::}"
      case ${_orig:-x} in ''|x|*[!0-9]*) _orig="";; esac
      if [ -n "$_orig" ]; then
        [ "$_orig" -ge 100000 ] 2>/dev/null && _orig=$(( _orig / 1000 ))   # uV entries -> mV
        if [ "$_orig" -gt 0 ] 2>/dev/null && [ "$_mv" -le $(( _orig - 200 )) ] 2>/dev/null; then
          warn_once_per mcvgauge 86400 "ACC: your charging voltage limit (${_mv} mV) is well below this battery's ${_orig} mV. Charging works, but the battery percentage will slowly drift and stop matching reality, because the gauge only recalibrates at a full charge it can now never reach. Raise it toward ${_orig} if the percentage looks wrong." || :
        fi
      fi
    fi

    # --- a pause/resume window only a point or two wide re-arms the charger constantly ---
    # Every resume is a charger re-negotiation, and on many phones that is an audible plug-in
    # chime. Pixel 4a 5G at 40/38 reported it as an occasional blip while sitting at the limit
    # in bypass. Nothing is wrong with the setting; it just costs a re-arm every couple of points.
    _res="${capacity[2]-}"; _pau="${capacity[3]-}"
    case ${_res:-x}${_pau:-x} in *[!0-9]*) _res=""; _pau="";; esac
    if [ -n "$_res" ] && [ -n "$_pau" ] && [ "$_pau" -le 100 ] 2>/dev/null \
      && [ $(( _pau - _res )) -le 3 ] 2>/dev/null && [ $(( _pau - _res )) -ge 0 ] 2>/dev/null
    then
      warn_once_per narrowwindow 86400 "ACC: your resume (${_res}%) and limit (${_pau}%) are only $(( _pau - _res )) apart. The charger re-starts every time the battery drops that far, which some phones announce with the plug-in sound. Lowering resume to about $(( _pau - 8 ))% makes it far less frequent." || :
    fi
  }
  config_sanity || :
  _drop_blocked_sw   # rc21: must run AFTER the config load; chargingSwitch does not exist before this
  currentWorkaround0=$currentWorkaround

  # rc20: NATIVE Pixel/Tensor firmware charge limit. When google,charger exposes the
  # charge_stop_level + charge_start_level pair, the FIRMWARE holds at the stop level and
  # resumes at the start level (confirmed on Pixel 9a: holds idle at the limit, no
  # overshoot, no drain). ACC's generic on/off toggle FIGHTS this (writes 100 = overshoot,
  # or off=5 = drains) and current_max=0 does not even gate Tensor's charge path, so on
  # these phones nothing worked. Here we DRIVE THE NATIVE PAIR from pause/resume_capacity
  # and skip the toggle entirely -- the 2023-era behavior that users confirm works.
  # Opt out (use the generic switch logic instead): touch $dataDir/.no-native-limit
  gcsl=; gcst=
  for _gd in ${NATIVE_DIRS:-/sys/devices/platform/google,charger /sys/devices/platform/soc/soc:google,charger}; do
    [ -f "$_gd/charge_stop_level" ] && [ -f "$_gd/charge_start_level" ] || continue
    gcsl=$_gd/charge_stop_level; gcst=$_gd/charge_start_level; break
  done
  nativeLimit=false
  { [ -n "$gcsl" ] && [ ! -f $dataDir/.no-native-limit ]; } && nativeLimit=true


  # fix#305/#308: boot blacklist. If a charging node kernel-panicked / hard-rebooted
  # the device on a prior boot, journal_check (defined in probe-journal.sh, sourced via
  # misc-functions.sh) blacklists it here so it is never re-probed and cannot loop-panic
  # the device again. Guarded: a no-op if the probe is absent, and never fatal.
  command -v journal_check >/dev/null 2>&1 && { journal_check || :; } || :

  apply_on_boot

  # rc21 (field report, Redmi Note 10 Pro / sweet -- "battery is draining rather than charging",
  # reproduced on a Mi A3 on a wall charger): recover a charger input that a previous run left
  # starved.
  #
  # The trap: a small value on the input-current nodes starves the charger, the charger then
  # drops OFFLINE, and the only code that restores those nodes -- `[ -n "${maxChargingCurrent[0]-}" ]
  # || set_ch_curr -` in the charging branch -- runs only while the phone is seen as plugged in.
  # So the state that needs undoing is exactly the state that stops the undo from running. The
  # phone sits on a cable at usb/current_max=0 and discharges until someone physically replugs,
  # while ACC's own sweep re-enables a charger its leftover cap is starving. The reporter's
  # ledger shows this precisely: `usb/current_max <- 50000 (was 1800000)` and then an hour of
  # enable-revive sweeps.
  #
  # Init is the one place this can be undone safely: it runs on every daemon start and reboot,
  # before any limit is applied, and it is not gated on the online state that the starvation
  # itself destroys. Only ever RAISES a node back to the default ACC recorded for it, and only
  # when the user has configured no current limit at all -- so it can never weaken a cap the
  # user asked for, and it cannot overcharge (input current is not the charge switch).
  if [ -z "${maxChargingCurrent[0]-}" ] && [ -f $TMPDIR/ch-curr-ctrl-files ]; then
    while IFS= read -r _ccl || [ -n "${_ccl:-}" ]; do
      case "$_ccl" in ''|'#'*) continue;; esac
      _ccf=${_ccl%%::*}                 # node path
      _ccd=${_ccl##*::}                 # the default ACC captured for it
      case "${_ccd:-x}" in ''|*[!0-9]*) continue;; esac
      case "$_ccf" in /*) : ;; *) _ccf=/sys/class/power_supply/$_ccf;; esac
      [ -w "$_ccf" ] || continue
      _ccn=$(cat "$_ccf" 2>/dev/null)
      case "${_ccn:-x}" in ''|*[!0-9]*) continue;; esac
      # only lift a node that is BELOW its recorded default; never lower one
      [ "$_ccn" -lt "$_ccd" ] 2>/dev/null || continue
      # ...and only one ACC could plausibly have ZEROED itself. "Below the recorded default" is
      # not the same as "a leftover ACC cap": during an HVDCP/QC ramp the charger driver holds
      # these nodes at real intermediate values on the way up, and they are legitimately below a
      # default captured in some earlier session. Lifting those fights the negotiation and it
      # collapses to the 5V DCP fallback -- field report on a curtana (Redmi Note 9S), where this
      # block overwrote usb/current_max 2450000->2600000, main/current_max 1600000->3000000,
      # main/input_current_settled 1850000->2600000 and pc_port/current_max 2150000->2600000 in
      # one pass, and the phone charged at 1.5A/5V afterwards with no fast charge. Upstream ACC
      # has no such restore, which is why it was unaffected.
      #
      # A cap ACC wrote for a cut reads 0, or a token value like 10000 on a current-cap switch.
      # Anything at or under 100mA is that; anything above is the driver mid-negotiation and is
      # none of our business. This keeps the bug the block exists for (ACC left a node at 0) and
      # drops the case where it was overwriting live values.
      [ "$_ccn" -le 100000 ] 2>/dev/null || continue
      # rc22: lift it HIGH, not back to the captured number. That number is only whatever the node
      # read when ACC first identified it, and if that happened on a weak source it is 500000 --
      # so "restoring" it caps the phone at 500mA on a 2A charger, over and over, every time the
      # driver zeroes the node. Device-proven on a Mi A3 on a HVDCP-3 charger: this block wrote
      # 500000 to input_current_settled, pc_port/current_max and usb/current_max within one second,
      # with the ledger reason "no current limit configured", and the phone sat at 5V/500mA.
      # The driver clamps a too-high value to what the charger can actually deliver, which is the
      # correct answer and the one the uninstaller already writes for these same nodes. Only INPUT
      # nodes get this; a battery-side charge current keeps its recorded default.
      case "$_ccf" in
        */current_max|*/input_current|*/input_current_limit|*/input_current_settled) _ccd=5000000;;
      esac
      echo "$_ccd" > "$_ccf" 2>/dev/null || :
      command -v _wlog >/dev/null 2>&1 \
        && _wlog "init restore $_ccf <- $_ccd (was $_ccn; no current limit configured)" || :
    done < $TMPDIR/ch-curr-ctrl-files
    unset _ccl _ccf _ccd _ccn
  fi

  # rc21 (same field report, and reproduced on a Mi A3 on a wall charger): release a charge
  # switch that a previous run left in its CUT position.
  #
  # This is the half that actually strands phones. A switch left cut -- `input_suspend=1` on the
  # A3 -- suspends the charger input, so the charger reads OFFLINE and every input-current node
  # reads 0. ACC's release paths all sit inside the charging branch, which only runs while it
  # believes it is plugged in, so the one thing that would undo the cut is disabled by the cut.
  # The phone then discharges on a live cable indefinitely and SURVIVES REBOOTS: verified here,
  # where a full reboot came back with input_suspend still 1, online 0, and the charger correctly
  # identified as USB_HVDCP_3 the whole time. Writing 0 to that single node restored 2.28 A
  # instantly.
  #
  # Only runs when ACC does not currently want a cut, i.e. the level is genuinely BELOW the
  # user's pause level, so it can never fight a legitimate pause and can never overcharge: at or
  # above the limit this does nothing at all. Percent limits only -- a mV pause_capacity is left
  # to the normal path. The writes are the same idempotent sweep used on the resume side: a node
  # already permissive is not re-poked, which matters because re-writing these re-triggers AICL
  # and collapses fast charge.
  _icl=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  _icp=${capacity[3]-}
  case "${_icl:-x}" in ''|*[!0-9]*) _icl=;; esac
  case "${_icp:-x}" in ''|*[!0-9]*) _icp=;; esac
  # rc22: ...and only when no THERMAL pause is in force. "Level below the pause level" says nothing
  # about temperature, so on a hot pack this swept every cut node permissive and undid a max_temp
  # pause the main loop then had to re-apply -- the field report's repeated re-enables above
  # max_temp, logged here as `init release ... (left cut, level N < pause M)`. See _temp_hold: it
  # blocks only on a positive over-temperature reading, so an unreadable sensor still releases and
  # the stranded-cut recovery this block exists for is preserved.
  if [ -n "$_icl" ] && [ -n "$_icp" ] && [ "$_icp" -le 100 ] 2>/dev/null \
     && [ "$_icl" -lt "$_icp" ] 2>/dev/null && ! _temp_hold; then
    ( cd /sys/class/power_supply 2>/dev/null || exit 0
      for _idi in */input_suspend */charge_disable */batt_slate_mode */op_disable_charge */disable_charging; do
        [ -w "$_idi" ] || continue
        [ "$(cat "$_idi" 2>/dev/null)" = 0 ] && continue
        command -v _wlog >/dev/null 2>&1 && _wlog "init release $_idi <- 0 (left cut, level $_icl < pause $_icp)" || :
        echo 0 > "$_idi" 2>/dev/null || :
      done
      for _ien in */charging_enabled */battery_charging_enabled */charge_enabled */charging_enable */enable_charging */enable_charger; do
        [ -w "$_ien" ] || continue
        [ "$(cat "$_ien" 2>/dev/null)" = 1 ] && continue
        command -v _wlog >/dev/null 2>&1 && _wlog "init release $_ien <- 1 (left cut, level $_icl < pause $_icp)" || :
        echo 1 > "$_ien" 2>/dev/null || :
      done ) || :
  fi
  unset _icl _icp

  touch $TMPDIR/.minCapMax
  # rc16: clear TRANSIENT auto-lock markers on (re)start so a crash mid-scan can never
  # lock the scanner out forever (the audit bug). The attempt-count, give-up flag and
  # blacklist are intentionally NOT cleared here so reruns stay bounded across the
  # scanner's own daemon restart; they reset when charging stops (see is_charging).
  rm $TMPDIR/.testingsw $TMPDIR/.sw-strict-done $TMPDIR/.breach \
     $TMPDIR/.autolock-tried $TMPDIR/.lockfail-count \
     $TMPDIR/.statusheal $TMPDIR/.statusheal-gaveup \
     $TMPDIR/.resumewarned 2>/dev/null || :   # rc6 (H5)/rc8/rc15: clear self-heal + resume-warn markers on (re)start (NOT $dataDir/.user-locked or the $dataDir/.warn-* rate-limit stamps, which persist by design)
  # rc19 recovery: a killed manual scan (SIGKILL skips its restore trap) can leave a
  # charge-current node pinned at 0 -> the phone will not charge until reboot, because
  # enable_charging only restores the LOCKED switch, not other nodes. When plugged in,
  # restore candidate switches to their ON value ONCE at (re)start to un-pin it, so AccA's
  # "restart daemon" recovers charging with no reboot. Subshell isolates cycle_switches'
  # chargingSwitch writes from the locked config value (set_dp re-sources $config anyway).
  if $nativeLimit; then
    # rc2: record the native firmware limit as the (locked) switch so AccA shows it instead of an
    # empty "Automatic". The daemon drives it via sync_native_limit regardless of chargingSwitch,
    # but an empty switch reads as "nothing is holding" and users re-run Find-Switch in vain (and
    # the early-cap skips). Cosmetic + idempotent: fills an EMPTY switch only, never overrides a
    # user's choice; nativeLimit still owns the actual hold.
    _srccfg
    # rc21: do not refill with a node that is on the blocked list. _drop_blocked_sw clears the
    # switch precisely because it is blocked; this cosmetic refill then saw an empty switch and
    # put the same blocked node straight back, so on Tensor the drop never stuck (Pixel 9a: the
    # warning fired every restart while config.txt still named the blocked node).
    if [ -z "${chargingSwitch[*]-}" ] \
      && ! { command -v sw_blacklisted >/dev/null 2>&1 && sw_blacklisted "$gcsl"; }
    then
      # This refill is COSMETIC (see above): it exists so AccA shows the native limit instead of
      # an empty "Automatic". It is the daemon filling in its own choice, so it must not claim the
      # USER locked it. It used to write the " --" marker and touch .user-locked, which had two
      # real consequences beyond the label: misc-functions' lock arm treats .user-locked as
      # "RESPECT a manual lock, NEVER auto-replace", so a Tensor phone whose charge_stop_level
      # stopped holding would only warn instead of self-healing onto another switch; and
      # write-config's pbim arm skips its deliberate auto-mode switch reset for a marked switch.
      # A non-empty value alone satisfies the cosmetic goal, so write it bare.
      sed -i "s|^chargingSwitch=.*|chargingSwitch=($gcsl 100 pcap)|" $config 2>/dev/null || :
      _srccfg
    fi
    sync_native_limit 2>/dev/null || :   # set the firmware limit at once (no toggle/overshoot)
  else
    online 2>/dev/null && ( cycle_switches on ) >/dev/null 2>&1 || :
  fi
  ctrl_charging
  exit $?


else


  args="$(echo "$@" | sed -E 's/(--init|-i)//g')"


  # filter out missing and problematic charging switches (those with unrecognized values)

  filter_sw() {
    local over3=false
    [ $# -gt 3 ] && over3=true
    # rc(6.3.1): the MTK current_cmd idle switch is promoted above input_suspend, but it can
    # only be trusted where cycle_switches can read real current to verify it actually cuts.
    # On a device with NO current sensor (currFile is the dummy), verification is blind, so
    # drop current_cmd here and let input_suspend (which physically cuts the input) be chosen
    # instead -- never blind-lock a non-cutting idle switch. Real-sensor devices keep it.
    case "$1" in *mtk_battery_cmd/current_cmd*) [ "${currFile-}" != "${TMPDIR-}/.dummy-mcc" ] || return 1;; esac
    # rc(6.4): drop pure throttle / feature-toggle nodes that scan-OK-but-never-HOLD --
    # they reduce current or re-flag a mode, they do not stop charging, so locking one
    # only overcharges-then-recovers. cycle_switches' sustained current check would reject
    # them anyway; excluding up front avoids the lock window + test latency. NOTE: only the
    # unambiguous throttles are listed. Device-dependent stops (siop_level on Samsung,
    # night_charging on Xiaomi) are NOT excluded -- the sustained current check validates
    # those per device, so we never remove a switch that genuinely holds somewhere.
    #
    # rc21: *_now joins them. Under the power_supply ABI *_now is always an instantaneous
    # reading, not a setting, so the "on" value captured for one is just whatever current
    # happened to be flowing during the scan (a Redmi Note 9S got `usb/input_current_now
    # 602075 0`, and every sweep pinned that stale 0.6 A back over the live value). AMPS
    # already refuses these (_now$ in its deny list); this brings the candidates in line.
    #
    # rc21: and the test now runs against every name the entry EXPANDS to, not only the
    # entry itself. ctrl-files.sh ships globs (`*/*charging_enable* 1 0`), and a glob matches
    # none of these literals, so the check passed and the expansion below then emitted
    # battery/step_charging_enabled -- a node this list exists to keep out. The daemon
    # auto-locked it on a Mi A3 after a clean install, giving a "switch" that cannot hold.
    sw_excluded() {
      case "$1" in
        *step_charging*|*restricted_charging*|*cool_mode*|*cool_down*|*system_temp*level*|*temp_cool*|*hmt_ta_charge*) return 0;;
        *_now) return 0;;
      esac
      return 1
    }
    if sw_excluded "$1"; then return 1; fi
    for f in $(echo $1); do
      # An excluded expansion drops only itself, so a glob's good matches still register.
      # In an over-3 group the nodes are written together as one switch, so a bad member
      # voids the whole group, which is what the loop below already does on any failure.
      if sw_excluded "$f"; then
        if $over3; then return 1; fi
        continue
      fi
      # rc21: honour the crash blacklist here too. AMPS refuses to write a blacklisted node,
      # but the daemon kept its own separate list and never consulted AMPS's, so a node blocked
      # in the app was still picked and written by ACC: on a Mi A3 with input_suspend blocked,
      # AMPS logged 12 refusals while the daemon cut charging with that same node. Dropping it
      # as a CANDIDATE (rather than refusing the write later) means the daemon never locks it,
      # so there is no half-applied switch to unwind and enable_charging is never blocked from
      # restoring one. A node with no candidates left is surfaced by the existing breach
      # monitor, which is the honest outcome: the limit is not held, and it says so.
      if command -v sw_blacklisted >/dev/null 2>&1 && sw_blacklisted "$f"; then
        if $over3; then return 1; fi
        continue
      fi
      if [ -f "$f" ] && chmod a+r $f 2>/dev/null \
        && {
          ! cat $f > /dev/null 2>&1 \
          || [ -z "$(cat $f 2>/dev/null)" ] \
          || grep -Eiq '^([0-9]+|0 0|0 1|on|off|(en|dis)abl(e|ed))$' $f
        }
      then
        $over3 && printf "$f $2 $3 " || printf "$f $2 $3\n"
      else
        return 1
      fi
    done
  }


  # log
  mkdir -p $TMPDIR $dataDir/logs
  exec > $dataDir/logs/init.log 2>&1
  set -x


  # prepare executables

  ln -fs $execDir/${id}.sh /dev/$id
  ln -fs $execDir/${id}.sh /dev/${id}d,
  ln -fs $execDir/${id}.sh /dev/${id}d.
  ln -fs $execDir/${id}a.sh /dev/${id}a
  ln -fs $execDir/service.sh /dev/${id}d

  mkdir -p $TMPDIR

  ln -fs $execDir/${id}.sh $TMPDIR/$id
  ln -fs $execDir/${id}.sh $TMPDIR/${id}d,
  ln -fs $execDir/${id}.sh $TMPDIR/${id}d.
  ln -fs $execDir/${id}a.sh $TMPDIR/${id}a
  ln -fs $execDir/service.sh $TMPDIR/${id}d

  if [ -d /sbin ]; then
    if grep -q '^tmpfs / ' /proc/mounts; then
      /system/bin/mount -o remount,rw / \
        || mount -o remount,rw /
    fi
    for h in $TMPDIR/$id \
      $TMPDIR/${id}d, $TMPDIR/${id}d. \
      $TMPDIR/${id}a $TMPDIR/${id}d
    do
      ln -fs $h /sbin/ 2>/dev/null || break
    done
  fi


  # fix Termux's PATH (missing /sbin/)
  termuxSu=/data/data/com.termux/files/usr/bin/su
  grep -q 'PATH=.*/sbin/su' $termuxSu 2>/dev/null && {
    sed '\|PATH=|s|/sbin/su|/sbin|' $termuxSu > ${termuxSu}.tmp
    cat ${termuxSu}.tmp > $termuxSu # preserves attributes
    rm ${termuxSu}.tmp
  }


  # whitelist MTK-specific switch, if necessary
  if test -f /proc/mtk_battery_cmd/current_cmd \
    && ! test -f /proc/mtk_battery_cmd/en_power_path \
    && grep -q "^#/proc/mtk" $execDir/ctrl-files.sh
  then
    sed -i '/^#\/proc\/mtk/s/#//' $execDir/ctrl-files.sh
  fi


  cd /sys/class/power_supply/
  : > $TMPDIR/ch-switches_
  : > $TMPDIR/ch-switches__

  for f in $TMPDIR/plugins/ctrl-files.sh \
    ${execDir}-data/plugins/ctrl-files.sh \
    $execDir/ctrl-files.sh
  do
    [ -f $f ] && . $f && break
  done

  ls_ch_switches | grep -Ev '^#|^$|num_system_temp' | \
    while IFS= read -r chargingSwitch; do
      set -f
      set -- $chargingSwitch
      set +f
      [ $# -lt 3 ] && continue
      if [ $# -gt 3 ]; then
        while [ $# -ge 3 ]; do
          if ! filter_sw "$@" >> $TMPDIR/ch-switches__; then
            rm $TMPDIR/ch-switches__
            break
          fi
          [ $# -lt 3 ] || shift 3
        done
        [ -f $TMPDIR/ch-switches__ ] \
          && cat $TMPDIR/ch-switches__ >> $TMPDIR/ch-switches_ \
          && rm $TMPDIR/ch-switches__
      else
        filter_sw "$@" >> $TMPDIR/ch-switches_
      fi
      echo >> $TMPDIR/ch-switches_
    done

  ls_ch_switches | grep num_system_temp | \
    while IFS= read -r chargingSwitch; do
      chsw=($chargingSwitch)
      [ -f ${chsw[0]} ] || continue
      chsw[2]=$(cat ${chsw[2]})
      [ -n "${chsw[2]}" ] || continue
      echo "${chsw[*]}" >> $TMPDIR/ch-switches_
      for i in 1 2; do
        echo "${chsw[0]} ${chsw[1]} $((chsw[2] - i))" >> $TMPDIR/ch-switches_
      done
    done

  cat $dataDir/logs/parsed.log 2>/dev/null >> $TMPDIR/ch-switches_
  sed -i -e 's/ $//' -e '/^$/d' $TMPDIR/ch-switches_


  # read charging voltage control files
  rm $TMPDIR/.mcc-read 2>/dev/null
  : > $TMPDIR/ch-volt-ctrl-files_
  ls -1 $(ls_volt_ctrl_files | grep -Ev '^#|^$') 2>/dev/null | \
    while read file; do
      chmod a+r $file 2>/dev/null && grep -Eq '^4[1-4][0-9]{2}' $file || continue
      grep -q '.... ....' $file && continue
      echo ${file}::$(sed -n 's/^..../v/p' $file)::$(cat $file) \
        >> $TMPDIR/ch-volt-ctrl-files_
    done
  grep -q / $TMPDIR/ch-volt-ctrl-files_ || rm $TMPDIR/ch-volt-ctrl-files_


  # exclude troublesome ctrl files
  for file in $TMPDIR/ch-*_; do
    awk '!seen[$0]++' $file | grep -Eiv 'parallel|::-|bq[0-9].*/current_max' > ${file%_}
    rm $file
  done


  # prepare default config help text and version code for oem-custom.sh and write-config.sh
  sed -n '/^# /,$p' $execDir/default-config.txt > $TMPDIR/.config-help
  sed -n '/^configVerCode=/s/.*=//p' $execDir/default-config.txt > $TMPDIR/.config-ver


  # preprocess battery interface
  . $execDir/batt-interface.sh


  # start $id daemon
  rm $TMPDIR/.ghost-charging 2>/dev/null
  if [ -f $TMPDIR/.install-notes ]; then
    $TMPDIR/acca $config --notif "$(cat $TMPDIR/.install-notes)"
    mv -f $TMPDIR/.install-notes $TMPDIR/.updated
  fi 2>/dev/null
  exec $0 $args
fi

exit 0
