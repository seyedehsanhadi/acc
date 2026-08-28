apply_on_boot() {

  local entry=
  local file=
  local value=
  local default=
  local arg=${1:-value}
  local exitCmd=false
  local force=false

  [ ${2:-x} != force ] || force=true

  [[ "${applyOnBoot[*]-}${maxChargingVoltage[*]-}" != *--exit* ]] || exitCmd=true

  # RESTORE NEEDS A SOURCE OF ENTRIES, and the array is empty by the time it is asked for one.
  # set_ch_volt's clear calls this to put the voltage nodes back, but the daemon reaches that clear
  # only after the config has been re-read with maxChargingVoltage=() -- so this loop iterated
  # nothing and restored nothing. A 4150mV cap stayed on the nodes with a config and a UI that both
  # said no limit; on a Mi A3 that is what left the pack floating at 3.9V against a 4.4V default.
  #
  # apply_on_plug already solves this for the current side by falling back to the resolved control
  # files when its array is empty and the caller asked for defaults. The voltage side never got the
  # same fallback. Same idiom, same guard: only on a `default` restore, so an APPLY still needs real
  # entries and can never be conjured out of the ctrl-files list.
  #
  # This surfaced only after the config clear was fixed. Previously the stale node entries survived a
  # clear, which meant the cap could not be released but this loop always had data -- the two faults
  # hid each other, and fixing the first exposed the second.
  for entry in ${applyOnBoot[@]-} ${maxChargingVoltage[@]:-$([ .$arg != .default ] || cat $TMPDIR/ch-volt-ctrl-files 2>/dev/null || :)}; do
    set -- ${entry//::/ }
    # RESOLVE THE PATH, do not depend on the working directory. ch-volt-ctrl-files and
    # ch-curr-ctrl-files store entries RELATIVE to /sys/class/power_supply
    # ("battery/voltage_max"), and this test only passes when cwd happens to BE that directory.
    # The daemon cds there, so a daemon-driven apply or restore worked; a front-end one did not.
    # acc.sh, acca.sh and this file never cd, so `acc -s mcv=` ran the whole loop, skipped every
    # entry on this test, and reported success having restored nothing.
    #
    # Device-proven on a Mi A3 from a front-end shell (cwd "/"): the entry parsed correctly as
    # file=battery/voltage_max default=4400000, and `[ -f $1 ]` was FALSE from / while TRUE from
    # /sys/class/power_supply. The nodes stayed pinned at 4150000 across a clear, an unplug and
    # a reboot, with the config and the UI both reporting no limit - a 4.15V ceiling holds that
    # pack near 70% and nothing on screen says why.
    #
    # Resolving here rather than adding a cd keeps the loop correct from ANY caller, which is
    # exactly what the daemon/front-end split showed is needed.
    file=${1-}
    case "$file" in
      /*) ;;
      *) file=${PS:-/sys/class/power_supply}/$file ;;
    esac
    [ -f "$file" ] || continue
    value=${2-}
    if $exitCmd && ! $force; then
      default=${2-}
    else
      default=${3:-${2-}}
    fi
    # READ BEFORE WRITE. A node already holding the target value must not be written again.
    #
    # This path wrote unconditionally, and on the input-negotiation nodes every write re-triggers
    # AICL - the charger re-measures the source and can settle LOWER. Repeating that is how a
    # healthy contract erodes: traced on a Mi A3 across one test run, 7.6V down to 5.76V through
    # ordinary cap cycling with no re-kick involved at all, and the same phone had already been
    # measured taking ~105 futile writes in 90s on a node that never changed.
    #
    # ACC already holds this convention elsewhere - set_temp_level reads before writing for exactly
    # this reason, and t52 asserts it - so this is bringing the current path in line rather than
    # inventing a rule. A write that would change nothing can only cost: a fork, and a nudge to a
    # negotiation the driver had already settled.
    #
    # Deliberately NOT applied when exitCode_ is set (a switch test/scan must write regardless of
    # what a node reads), and the comparison is string-exact so any unreadable or oddly-formatted
    # value falls through to the write - failing toward doing the work, which is the safe direction
    # for a cap.
    if [ -z "${exitCode_-}" ]; then
      eval "_tv=\$$arg"
      _lv=; { read -r _lv < "$file"; } 2>/dev/null || _lv=
      if [ -n "${_lv:-}" ] && [ "$_lv" = "${_tv:-}" ]; then
        continue
      fi
    fi

    set +e
    write \$$arg $file 0 &
    set -e
  done

  wait
  $exitCmd && [ $arg = value ] && exit 0 || :
}


apply_on_plug() {

  local entry=
  local file=
  local value=
  local default=
  local arg=${1:-value}
  local _rk= _rv= _rc= _lv= _tv=

  for entry in ${applyOnPlug[@]-} ${maxChargingVoltage[@]-} \
    ${maxChargingCurrent[@]:-$([ .$arg != .default ] || cat $TMPDIR/ch-curr-ctrl-files 2>/dev/null || :)}
  do
    set -- ${entry//::/ }
    # RESOLVE THE PATH, do not depend on the working directory. ch-volt-ctrl-files and
    # ch-curr-ctrl-files store entries RELATIVE to /sys/class/power_supply
    # ("battery/voltage_max"), and this test only passes when cwd happens to BE that directory.
    # The daemon cds there, so a daemon-driven apply or restore worked; a front-end one did not.
    # acc.sh, acca.sh and this file never cd, so `acc -s mcv=` ran the whole loop, skipped every
    # entry on this test, and reported success having restored nothing.
    #
    # Device-proven on a Mi A3 from a front-end shell (cwd "/"): the entry parsed correctly as
    # file=battery/voltage_max default=4400000, and `[ -f $1 ]` was FALSE from / while TRUE from
    # /sys/class/power_supply. The nodes stayed pinned at 4150000 across a clear, an unplug and
    # a reboot, with the config and the UI both reporting no limit - a 4.15V ceiling holds that
    # pack near 70% and nothing on screen says why.
    #
    # Resolving here rather than adding a cd keeps the loop correct from ANY caller, which is
    # exactly what the daemon/front-end split showed is needed.
    file=${1-}
    case "$file" in
      /*) ;;
      *) file=${PS:-/sys/class/power_supply}/$file ;;
    esac
    [ -f "$file" ] || continue
    value=${2-}
    default=${3:-${2-}}

    # rc21 bug 2: back off a node the firmware will not let hold its value. Some
    # control files are owned by charger/USB negotiation (usb/current_max and the
    # other input-current nodes): a write above the negotiated source current is
    # reverted instantly, and the daemon otherwise rewrote it EVERY tick forever
    # - measured on a Mi A3 as ~105 futile writes in 90s, and the root of the
    # Xiaomi "ACC keeps writing a value the phone won't take" report. Once a node
    # has rejected the SAME target 5 times, skip it, retrying only every 8th tick
    # so a charger that later frees up is still picked up. Guards:
    #  - APPLY only (arg=value). A skipped RESTORE would strand a node capped
    #    ("the cap won't clear" field reports), so a clear is never backed off.
    #  - never during a switch test/scan (exitCode_ set) - that path must write.
    #  - the charging SWITCH is enforced elsewhere and is untouched here, so this
    #    can never weaken the pause/overcharge guard; the worst case is a current
    #    cap that leaks high on one node it could not have held anyway.
    # rc22: never APPLY a current cap once the marker is gone. The marker is created when a cap is
    # set and removed the moment one is cleared, so its absence means "no cap is configured" -- and
    # the daemon can reach here holding a config it read before the user cleared it. Without this
    # the cap is re-applied a second after being released, and the phone stays capped.
    if [ "$arg" = value ] && [ -n "${maxChargingCurrent[0]-}" ]        && [ ! -f "$TMPDIR/.mcc-custom" ] && [ -z "${exitCode_-}" ]; then
      # MEMBERSHIP, not five hardcoded names. ls_curr_ctrl_files resolves roughly twenty patterns and
      # this list covered five, so a released cap was re-applied to everything else and then left
      # pinned with no later clear to lift it: restrict_cur on Qualcomm (measured 4.64V/1.51A against
      # a charger that had negotiated far more), usb/input_current_max on Tensor, and the
      # batt_tune_*/ac_charge/sdp_charge family on Samsung. ch-curr-ctrl-files IS the set of nodes a
      # cap writes, so ask it, and keep the patterns as the fallback for a phone that has not
      # resolved its ctrl files yet (tmpfs, so that is every phone on its first charge after a boot).
      case "$file" in /*) _mf=${file#/sys/class/power_supply/};; *) _mf=$file;; esac
      if [ -s "$TMPDIR/ch-curr-ctrl-files" ]          && { grep -q "^${_mf}::" "$TMPDIR/ch-curr-ctrl-files" 2>/dev/null               || grep -q "^${file}::" "$TMPDIR/ch-curr-ctrl-files" 2>/dev/null; }; then
        continue
      fi
      case "$file" in
        */current_max|*/input_current*|*constant_charge_current*|*restrict_cur*|*restrict_chg*) continue;;
      esac
    fi

    if [ "$arg" = value ] && [ -z "${exitCode_-}" ]; then
      _rk=$TMPDIR/.mccrej-${file//\//_}
      read -r _rv _rc < "$_rk" 2>/dev/null || { _rv=; _rc=0; }
      case ${_rc:-0} in ''|*[!0-9]*) _rc=0;; esac
      [ "$_rv" = "$value" ] && [ $_rc -ge 5 ] && [ $((_rc % 8)) -ne 0 ] && continue
    fi

    # rc22: on a RESTORE, never LOWER a live value. The "default" is a snapshot taken whenever the
    # control files were first identified. Taken on a computer's USB port that snapshot is 500000,
    # and writing it back later on a wall charger holds the phone at 500mA for the rest of the
    # session -- the same mistake as the curtana init restore, which accd already bounds for exactly
    # this reason. The back-off guard above cannot catch it: it is deliberately APPLY-only, so
    # nothing bounded a restore at all.
    # An unreadable or non-numeric live value still writes, and so does a non-numeric default:
    # leaving a node capped is the failure this path exists to prevent, so it fails toward writing.
    if [ "$arg" = default ]; then
      case "$file" in
        */current_max|*/input_current|*/input_current_max|*/input_current_limit|*/input_current_settled|*/restrict_cur)
          # restrict_cur belongs here too, and it was missed because the pattern above is written
          # around node NAMES under power_supply and this one lives in /sys/class/qcom-battery.
          #
          # Measured on a Mi A3 on a QC3 charger: ACC's recorded default for it was 1000000, because
          # that is simply what the node read when ACC first identified it - with the vendor's
          # restricted-charging mode already engaged. Restoring that "default" holds the phone at 1 A.
          # Lifting it (restrict_chg 0, restrict_cur 5000000, the values ACC's OWN uninstaller writes)
          # took the same phone from 4.64 V / 1.51 A to 5.97 V / 3.03 A, and the level climbed 63% to
          # 70% in three minutes. It had been charging at half speed.
          #
          # That is the curtana complaint on Qualcomm hardware: "fast charge is gone". The node is an
          # input-current ceiling like the others, so it gets the same rule - release high and let the
          # driver clamp to what the charger can really deliver.
          # rc22: these are INPUT nodes, owned by charger negotiation. Two rules, both measured.
          #
          # 1. Only touch one ACC could plausibly have capped. Anything above ~100mA is the driver
          #    mid-negotiation and is none of our business: writing it re-triggers AICL and the
          #    negotiation settles LOWER. Measured on a Mi A3 -- a restore wrote over a healthy live
          #    1200000 and the driver came back at 200000. Same rule the init restore already uses.
          # 2. When it IS ours to lift, lift it HIGH rather than to the recorded default. That
          #    default is only whatever the node read when ACC first identified it; captured on a
          #    weak source it is 500000, so "restoring" it caps the phone at 500mA on a 2A charger,
          #    again every time the driver zeroes the node. Measured on the same A3: five input
          #    nodes written to 500000, phone left at 4836mV/500mA. Writing high lets the driver
          #    clamp to what the charger can really deliver -- 0 -> 1.9A on that phone, device-proven
          #    -- and it is what the uninstaller already writes for these same nodes.
          # A RESTORE means "ACC is no longer capping this", so release it: write high and let the
          # driver clamp to what the charger can actually deliver. The recorded default must not be
          # used -- it is only whatever the node read when ACC first identified it, and captured on
          # a weak source that is 500000, which then caps a 2A charger at 500mA every time the
          # driver zeroes the node (measured on a Mi A3). Writing high is what the uninstaller
          # already does for these same nodes.
          #
          # Two narrower rules were tried here and both were wrong. Gating on "at or below 100mA"
          # refused to release ACC's own cap, because a user cap of 1000mA sits above that bound --
          # reproduced on a Pixel 6a and a Mi A3 as "the cap will not clear". Gating on "the node
          # still reads exactly what ACC applied" fails on the unit boundary: the config carries
          # milliamps (1000) and the node holds microamps (1000000), so it never matched.
          #
          # The measurement that motivated those bounds -- 5000000 written over a live 1200000,
          # after which the driver settled at 200000 -- was later explained by the cable: that phone
          # has ~500 milliohm of series resistance, and its input collapses to zero identically with
          # ACC uninstalled and never run. So there was no live negotiation being harmed, only a
          # supply that cannot hold current at all.
          default=5000000
          ;;
        *)
          # Everything else: never LOWER a live value on a restore. The recorded default is still a
          # snapshot, and the back-off guard above is deliberately APPLY-only, so nothing bounded a
          # restore at all. An unreadable live value or a non-numeric default still writes -- leaving
          # a node capped is the failure this path exists to prevent, so it fails toward writing.
          _lv=; { read -r _lv < "$file"; } 2>/dev/null || _lv=
          case "${_lv:-x}" in
            ''|*[!0-9]*) : ;;
            *) case "${default:-x}" in
                 ''|*[!0-9]*) : ;;
                 *) [ "$_lv" -lt "$default" ] 2>/dev/null || continue;;
               esac;;
          esac
          ;;
      esac
    fi

    set +e
    write \$$arg $file 0 &
    set -e
  done

  wait

  # rc21 bug 2: a restore clears all reject state so the next cap starts fresh.
  [ "$arg" = value ] || { rm -f $TMPDIR/.mccrej-* 2>/dev/null || :; return 0; }

  # rc21 bug 2 bookkeeping: after the writes settle, learn which mcc nodes held.
  # A node that reverted grows its per-target reject count (feeding the skip
  # above); one that holds, or whose target changed, resets to zero. Cheap (one
  # cat per node) and only while a cap is applied. exitCode_ set = switch test,
  # skip. warn once (daemon only) so the user learns their cap is hardware-bound.
  [ -z "${exitCode_-}" ] || return 0
  for entry in ${maxChargingCurrent[@]-}; do
    set -- ${entry//::/ }
    # RESOLVE THE PATH, do not depend on the working directory. ch-volt-ctrl-files and
    # ch-curr-ctrl-files store entries RELATIVE to /sys/class/power_supply
    # ("battery/voltage_max"), and this test only passes when cwd happens to BE that directory.
    # The daemon cds there, so a daemon-driven apply or restore worked; a front-end one did not.
    # acc.sh, acca.sh and this file never cd, so `acc -s mcv=` ran the whole loop, skipped every
    # entry on this test, and reported success having restored nothing.
    #
    # Device-proven on a Mi A3 from a front-end shell (cwd "/"): the entry parsed correctly as
    # file=battery/voltage_max default=4400000, and `[ -f $1 ]` was FALSE from / while TRUE from
    # /sys/class/power_supply. The nodes stayed pinned at 4150000 across a clear, an unplug and
    # a reboot, with the config and the UI both reporting no limit - a 4.15V ceiling holds that
    # pack near 70% and nothing on screen says why.
    #
    # Resolving here rather than adding a cd keeps the loop correct from ANY caller, which is
    # exactly what the daemon/front-end split showed is needed.
    file=${1-}
    case "$file" in
      /*) ;;
      *) file=${PS:-/sys/class/power_supply}/$file ;;
    esac
    [ -f "$file" ] || continue
    value=${2-}
    _rk=$TMPDIR/.mccrej-${file//\//_}
    if [ "$(cat "$file" 2>/dev/null)" = "$value" ]; then
      rm -f "$_rk" 2>/dev/null || :
    else
      read -r _rv _rc < "$_rk" 2>/dev/null || { _rv=; _rc=0; }
      case ${_rc:-0} in ''|*[!0-9]*) _rc=0;; esac
      [ "$_rv" = "$value" ] || _rc=0
      _rc=$((_rc + 1))
      echo "$value $_rc" > "$_rk" 2>/dev/null || :
      [ $_rc -eq 5 ] && ${isAccd:-false} && command -v warn_once_per >/dev/null 2>&1 \
        && warn_once_per mccreject-${file##*/} 21600 "ACC: this phone's firmware will not let ${file##*/} hold ${value}; the charger's own negotiated limit wins, so charging current stays at the hardware maximum." || :
    fi
  done
}


at() {
  ${isAccd:-false} || return 0
  local file=$TMPDIR/schedules/${1/:}
  # rc(6.3.1): reject a malformed schedule time BEFORE the arithmetic below -- an empty or
  # non-numeric hour/HHMM ('at :30', 'at 8x:30') would make $((10#...)) abort under set -e
  # (and $config is sourced unguarded), so guard it like the rest of the config fail-safes.
  case ${1%:*} in ''|*[!0-9]*) return 0;; esac
  case ${file##*/} in ''|*[!0-9]*) return 0;; esac
  # rc(6.3.1): force base-10 -- a leading-zero clock (e.g. 08xx/09xx from date +%H%M, or an
  # 08:/09: schedule) is parsed as invalid octal by the arithmetic test and aborts at() under
  # set -e. 10# makes every comparison decimal regardless of leading zeros.
  if [ ! -f $file ] && [ $((10#$(date +%H%M))) -ge $((10#${file##*/})) ] && [ $((10#$(date +%H))) -eq $((10#${1%:*})) ]; then
    mkdir -p ${file%/*}
    shift
    echo "$@" | sed 's/,/\;/g; s|^acc$|/dev/acc|; s|^acc |/dev/acc |; s| acc$| /dev/acc|; s| acc | /dev/acc |g' > $file
    . $file || :
  elif [ $((10#$(date +%H%M))) -lt $((10#${file##*/})) ]; then
    rm $file 2>/dev/null || :
  fi
}


calc() {
  awk "BEGIN {print $*}" | tr , .
}


# At or above the level the user asked ACC to pause at? Used to decide whether a switch candidate
# that did not work should be left CUT or handed back.
#
# Leaving it cut is right only when a pause is what we are trying to achieve. During discovery on a
# healthy charge - fresh install, an AccA Automatic reset, .rediscover, an auto-lock blacklist - the
# phone is nowhere near the limit, and a cut candidate is pure loss: it is not protecting anything,
# it just stops the charge. The values these candidates hold are hostile: */current_max 0,
# */constant_charge_current* 0, charge_stop_level 5, siop_level 0.
#
# Handles both domains the pause setting can be in, the same way the daemon does: a value <= 100 is
# a percentage, 3001-5000 is millivolts. Anything unparseable answers "no", so the caller hands the
# node back rather than latching it - the safe direction when we cannot tell.
at_or_above_pause() {
  local _v=
  case "${capacity[3]-}" in ''|*[!0-9]*) return 1;; esac
  if [ "${capacity[3]}" -gt 3000 ] 2>/dev/null && [ "${capacity[3]}" -le 5000 ] 2>/dev/null; then
    _v=$(volt_now 2>/dev/null)
  elif [ "${capacity[3]}" -le 100 ] 2>/dev/null; then
    _v=$(batt_cap 2>/dev/null)
  else
    return 1
  fi
  case "${_v:-x}" in ''|x|*[!0-9-]*) return 1;; esac
  [ "$_v" -ge "${capacity[3]}" ] 2>/dev/null
}

cycle_switches() {

  local on=
  local off=
  local strict=${3:-false}
  local _cc= _cbase= _thr= _mag= _bs= _cs= _rej= _chg_n= _chg_last= _this= _s=

  # The scanning pid, not an empty file: a scan killed with SIGKILL skips its restore trap and
  # leaves this behind, and a bare marker cannot be told apart from a scan still in progress.
  # Consumers testing -f are unaffected; one that wants the truth checks /proc for the pid.
  echo $$ > $TMPDIR/.testingsw 2>/dev/null || touch $TMPDIR/.testingsw

  # rc21 (field report: OnePlus SM8250 / KernelSU, probe-crash into EDL): a global stop.
  # journal_check blacklists ONE node per crash-boot, so a device whose charge driver wedges
  # on several nodes pays one hard reboot per node. That is bounded by the candidate list
  # (139 lines) but not by anything a user survives -- a Qualcomm device falls into EDL long
  # before the list runs out. Once probing has taken this phone down $probeStrikeMax times,
  # stop probing ALTOGETHER and let the user pick a switch by hand. Charging is never blocked
  # by this; only the automatic search for a switch stops. Cleared by `acc -sb clear`.
  if [ -f "$dataDir/.no-probe" ]; then
    ${isAccd:-false} && command -v _wlog >/dev/null 2>&1 \
      && _wlog "probe latch set (.no-probe): not searching for a switch; pick one with acc -ss" || :
    rm -f $TMPDIR/.testingsw
    return 1
  fi

  while read -A chargingSwitch; do

    # rc23d: stop when the sweep's budget is spent. Unbounded, this loop held a plugged Mi A3 off
    # charge for over five minutes with four limiters standing at once and flight.log frozen, while
    # every liveness check still reported the daemon alive. Nothing is lost by stopping: the reject
    # arm and the failure arm below rotate every candidate that COST TIME to the end of ch-switches,
    # so the next sweep resumes on new work, while free skips (absent node, blacklisted) stay at the
    # front and are re-passed in milliseconds.
    #
    # Only an ARMED off-sweep is bounded. cycle_switches_off owns the budget as a local, so the
    # restore direction and accd.sh:2885's exit-trap sweep never see one. acc -t is exempt as well:
    # it walks every candidate on purpose, with a user watching it, and that is how an awkward phone
    # gets a switch at all.
    if [ -n "${_swEnd-}" ] && ! ${acc_t:-false} && [ $SECONDS -ge $_swEnd ]; then
      # `read -A` has ALREADY overwritten the global array with this untried candidate, and
      # accd.sh:1219 writes it straight to $TMPDIR/.sw. Leave nothing that looks like a selection.
      chargingSwitch=()
      ${isAccd:-false} && command -v _wlog >/dev/null 2>&1 \
        && _wlog "sweep budget spent; stopped early, next sweep resumes from here" || :
      break
    fi

    # Brick-safe guard (GitHub #305/#308): a switch that panicked the kernel mid-write
    # on a previous boot is on the persistent blacklist -- never touch it again.
    ! journal_blacklisted "${chargingSwitch[*]}" || continue

    # rc16 contract blacklist: a switch the runtime monitor caught NOT holding the
    # limit (firmware drift / partial multi-path) is parked for this session so the
    # daemon's own locker never immediately re-picks the same failing switch.
    ! grep -qxF "${chargingSwitch[*]}" $TMPDIR/.sw-blacklist 2>/dev/null || continue

    [ ! -f ${chargingSwitch[0]:-//} ] || {

      # Write-ahead journal ONLY around the risky pause (off) write. If flip_sw off
      # kernel-panics and reboots the device, the pending record survives and accd's
      # boot-time journal_check blacklists this exact switch line. The resume (on) write
      # is not journalled -- re-arming charging never bricks, and arming there would
      # falsely blacklist a perfectly good switch.
      if [ "$1" = on ]; then
        flip_sw $1 || :
      else
        _cbase=$(cat "$currFile" 2>/dev/null)   # charging-direction baseline (signed) before pausing
        journal_arm "${chargingSwitch[*]}"
        # rc21: the journal is the ONLY thing that makes this write recoverable, so verify it
        # actually landed before taking the risk. If dataDir is read-only, full, or not yet
        # decrypted, journal_arm silently no-ops (every path in it is best-effort) and the
        # write below would go UNPROTECTED: a panic could never be attributed, so this node
        # gets re-probed on every boot forever -- the unbounded loop the journal exists to
        # prevent. post-fs-data.sh already refuses its early cut on exactly this condition;
        # the probe path must not be weaker. Skip the candidate, do not abort the sweep.
        # -f as well as -s: `-s` alone is TRUE for a directory (a dir has non-zero size), so a
        # stale directory sitting at the journal path would satisfy the guard and let the risky
        # write through unprotected -- the exact case this exists to stop. Caught by the rc21/rc21
        # benchmark, where rc21 wrote a node that rc21 happened not to reach.
        _pjf=${probePending:-$dataDir/.probe-pending}
        if [ ! -f "$_pjf" ] || [ ! -s "$_pjf" ]; then
          ${isAccd:-false} && command -v _wlog >/dev/null 2>&1 \
            && _wlog "journal unwritable; skipped probing ${chargingSwitch[0]:-?} (fail-safe)" || :
          continue
        fi
        flip_sw $1 || :
        journal_disarm
      fi

      if [ "$1" = on ]; then
        not_charging || break
      else
        if not_charging ${2-}; then
          # Stability gate: re-confirm the off state PERSISTS before adopting this
          # switch. A level/throttle node (e.g. *charge_stop_level*, siop_level)
          # can read "stopped" for an instant and then be re-armed by the charger
          # firmware -- that is the on/off flicker. Only enforced on the strict
          # pass; cycle_switches_off runs a lenient fallback afterwards, so a
          # device whose ONLY working switch flickers is still capped (no regression).
          if $strict; then
            # SUSTAINED-HOLD verify (6.4-rc1). The old check sampled current ONCE after a
            # single settle: a switch that stops current for that one read then lets the
            # firmware re-arm charging (MediaTek current_cmd on Xiaomi HyperOS/klee: passes
            # a 3s check, then bounces back -> overcharge) was accepted and LOCKED. Now sample
            # the SIGNED current 3x across the settle window; reject the switch if current is
            # charging-direction in the LAST sample OR in a majority of samples. Judged ONLY on
            # current delta vs the pre-pause baseline -- NEVER status/online, which both read
            # "stopped" on an input-cut switch while current still flows. A switch that settles
            # INTO a hold (charging early, stopped late) is still accepted (last sample stopped),
            # so slow USB-PD re-negotiation is not falsely rejected. Unreadable current counts as
            # "still charging" (cautious -- never lock blind). Sign-agnostic + unit-scaled (uA/mA
            # via ampFactor_), so inverted-current kernels and discharge-holds are judged right.
            _thr=50000; [ "${ampFactor_:-1000000}" -ge 1000000 ] 2>/dev/null || _thr=50
            _chg_n=0; _chg_last=1
            # If the pre-pause baseline current is unreadable, the charging DIRECTION is
            # unknown, so a hold cannot be judged on an inverted-sign kernel -> reject
            # (never lock blind). Otherwise sample 3x.
            case "${_cbase:-x}" in
              ''|x|*[!0-9-]*) _chg_last=1; _chg_n=3 ;;
              *)
                for _s in 1 2 3; do
                  sleep ${loopDelay[0]}
                  _cc=$(cat "$currFile" 2>/dev/null)
                  _this=1
                  case "${_cc:-x}" in
                    ''|x|*[!0-9-]*) _this=1 ;;
                    *) _mag=${_cc#-}; _bs=p; _cs=p
                       case "$_cbase" in -*) _bs=n ;; esac
                       case "$_cc" in -*) _cs=n ;; esac
                       if [ "${_mag:-0}" -gt "$_thr" ] 2>/dev/null && [ "$_cs" = "$_bs" ]; then _this=1; else _this=0; fi ;;
                  esac
                  [ "$_this" = 1 ] && _chg_n=$((_chg_n + 1))
                  _chg_last=$_this
                done ;;
            esac
            # reject if the LAST sample is still charging-direction, OR all three are. A
            # switch that settles INTO a hold (charging early, stopped late) is accepted
            # (honours slow USB-PD re-negotiation); klee/MTK current_cmd bounces back and
            # STAYS charging -> last sample charging -> rejected. The rare "charges then dips
            # only at the final sample" non-holder is caught by the runtime breach watchdog.
            if [ "$_chg_last" = 1 ] || [ "$_chg_n" -ge 3 ]; then _rej=true; else _rej=false; fi
            if $_rej; then
              # Rejected: it resumed on its own, so it does not hold. Keeping it CUT is correct
              # only while we are actually trying to pause - at or above the limit. Below it, this
              # arm used to latch the node OFF for the rest of the session with no restore
              # anywhere: not here, not in cycle_switches_off's second pass (skipped by the
              # `not_charging ||` guard precisely when the abandoned node is the thing cutting),
              # and not in enable_charging, which only touches the ACCEPTED switch. A discovery
              # probe on a healthy charge could therefore leave */current_max or
              # */constant_charge_current at 0 for the whole session while ACC reported normal.
              # Same rule as the failure arm below, which already got this right.
              # rc23c: a VOLTAGE candidate is always restored, whatever the level.
              #
              # The suppression below is right for a current/suspend switch: at or above the pause
              # level charging is meant to be off, leaving the node cut costs nothing, and the next
              # enable_charging puts it back. A voltage switch is a different animal. Its off value
              # is a float-voltage CEILING, so leaving it applied does not pause charging - it ends
              # it, at every level, including far below resume, and across reboots. Nothing restores
              # it either, because the daemon never recorded owning the node.
              #
              # Measured on a Mi A3 with chargingSwitch=(): sitting at 31% with pause=31, a rejected
              # battery/voltage_max was left at 3600000 against a 3.9V pack, and the charger refused
              # everything - "battery over-voltage vbat_fg = 3905196uV, fv = 3600000uV" - until the
              # value was written back by hand, whereupon charging resumed at 2.8A.
              case "${chargingSwitch[0]}" in
                *voltage*) flip_sw on 2>/dev/null || : ;;
                *)         at_or_above_pause || flip_sw on 2>/dev/null || : ;;
              esac
              if ! ${acc_t:-false}; then
                sed -i "\|^${chargingSwitch[*]}$|d" $TMPDIR/ch-switches
                echo "${chargingSwitch[*]}" >> $TMPDIR/ch-switches
              fi
              continue
            fi
          fi
          # set working charging switch(es). PERSISTING the switch is what ends the re-probe
          # sawtooth ("stopped at the limit, then resumed/reset", ~40 toggles in 21 min at 91%):
          # the fan-out is gated on an EMPTY chargingSwitch[0], so a non-empty value alone stops
          # it. The trailing " --" this used to append on the strict pass was never what
          # suppressed the re-probe, and it is the SAME marker a user lock writes, so an
          # automatic settle was indistinguishable from a manual pin in three places:
          # state-export reported userLocked=true, AccA's isAutomaticSwitchEnabled reads the
          # marker straight off the config line and showed its manual-lock label, and
          # write-config's pbim arm skipped the deliberate "reset switch (in auto-mode)" that
          # exists so a prioritizeBattIdleMode change re-picks an appropriate switch class.
          # An automatic selection is not a user lock and no longer claims to be one. The real
          # user-lock paths (set-prop's picker, acc -ss N, AccA Apply&Lock) append " --"
          # themselves, and that is what makes write-config touch .user-locked, which it only
          # ever does when isAccd is false.
          s="${chargingSwitch[*]}"
          # rc13: breadcrumb. Cache the bare switch line (no trailing " --") so the next
          # cycle_switches_off on this or a future session can try it FIRST instead of
          # fanning out through the full candidate list (each failed candidate's
          # flip_sw on re-arms charging briefly -> battery rises during cycling).
          _swAdopted=1
          printf '%s\n' "${chargingSwitch[*]}" > $dataDir/.last-good-switch 2>/dev/null || :
          . $execDir/write-config.sh
          break
        else
          # reset switch/group that fails to comply, and move it to the end of the list.
          # rc13: SUPPRESS the flip_sw on re-arm when we're already at/above the pause level
          # (post-install fan-out through N candidates can otherwise let cap creep past pause:
          # each failed candidate's "on" briefly un-cuts before the next is tried). The failed
          # switch's "off" write had no protective effect anyway, so leaving the nodes alone
          # is no worse than re-arming them, and the loop body still moves the candidate to
          # the end. Mirrors the daemon's ${capacity[3]} domain check (% if <=100, else mV).
          # One helper, two callers. This arm and the reject arm above must agree, and when they
          # were separate copies only this one had the level check.
          # rc23c: same rule as the reject arm above - a voltage candidate is always restored.
          # Leaving a float-voltage ceiling applied does not pause charging, it ends it, at every
          # level and across reboots, with nothing to put it back.
          case "${chargingSwitch[0]}" in
            *voltage*) flip_sw on 2>/dev/null || : ;;
            *)         at_or_above_pause || flip_sw on 2>/dev/null || : ;;
          esac
          if ! ${acc_t:-false}; then
            sed -i "\|^${chargingSwitch[*]}$|d" $TMPDIR/ch-switches
            echo "${chargingSwitch[*]}" >> $TMPDIR/ch-switches
          fi
        fi
      fi
    }
  done < $TMPDIR/ch-switches

  # rc24: a candidate that was NOT adopted must not stay in the global. `read -A` leaves the last
  # line of ch-switches there and enable_charging runs this loop in the current shell, so the next
  # disable_charging could treat a leftover voltage node as the configured switch - a float ceiling,
  # not a pause. -f on the rm: a missing marker aborted the caller under set -e.
  [ -n "${_swAdopted-}" ] || chargingSwitch=()
  unset _swAdopted
  rm -f $TMPDIR/.testingsw
}


_rearm_sweep() {
  local _swEnd=$(( SECONDS + ${_rearmBudget:-120} ))
  cycle_switches on
}


cycle_switches_off() {
  # rc23d: ONE sweep budget for this whole call, shared by all three passes below. It is a local and
  # that is the design, not an accident: mksh scopes locals dynamically, so cycle_switches sees it
  # while this call is on the stack and it is gone the moment this returns. A global would never
  # clear, and cycle_switches is also reached by the exit-trap `online && ( cycle_switches on )` at
  # accd.sh:2885 - the restore sweep, and the ONLY path that un-cuts candidates deliberately left cut
  # at or above the pause level. Bounding that strands a phone unable to charge.
  #
  # 120s comes from the measured cost. A candidate that does not hold costs ~35s (batt-interface.sh
  # _STI=35, one sleep 1 per iteration) and the strict pass adds 3 x loopDelay[0]=3, so the checks at
  # 0, ~44 and ~88 all pass: at least three candidates START per sweep and a sweep can never make
  # zero progress, which is what the resume story rests on. The check is only at the top of the loop
  # body and a started candidate always runs to completion, so the honest ceiling is budget + one
  # candidate = ~164s, against a full walk measured at 326s on laurus and 582s on bluejay.
  #
  # One budget for the call, not one per pass: three would put the ceiling above the full walk it is
  # meant to beat, so the bound would buy nothing.
  local _swEnd=$(( SECONDS + ${_SWMAX:-120} ))
  # rc11: demote the current-cap class (*/current_max, constant_charge_current[_max],
  # */input_current) to the END of the candidate list -- those can pass the 9s sustained-hold
  # verify yet get re-armed by the charger firmware afterwards, so discovery wastes ~9s on each
  # before the runtime monitor parks it. Reliable cut/native-level switches are tried first now.
  # Pure reorder of the candidate ORDER; the verify + ranking logic is unchanged; no-op if awk absent.
  [ -f $TMPDIR/ch-switches ] && awk '/current_max|constant_charge_current|input_current/{lo=lo $0 ORS; next}{hi=hi $0 ORS}END{printf "%s%s",hi,lo}' $TMPDIR/ch-switches > $TMPDIR/ch-switches.r 2>/dev/null && mv -f $TMPDIR/ch-switches.r $TMPDIR/ch-switches 2>/dev/null || :
  # rc13: if a previously verified switch is cached AND still in the candidate list,
  # promote it to the TOP so the strict pass tries it FIRST. Skips the full fan-out
  # through the candidate list (each failing candidate's flip_sw on briefly re-arms
  # charging -> cap can rise past pause during cycling on fresh installs / blanks).
  # Pure reorder; if the cached switch fails the strict verify it just falls through
  # to the existing list. No effect once a switch is locked (the guard below is false).
  if [ -z "${chargingSwitch[0]-}" ] && [ -s $dataDir/.last-good-switch ] && [ -f $TMPDIR/ch-switches ]; then
    awk -v lgs="$(cat $dataDir/.last-good-switch 2>/dev/null)" 'lgs!="" && $0==lgs{hit=hit $0 ORS; next}{rest=rest $0 ORS}END{printf "%s%s",hit,rest}' $TMPDIR/ch-switches > $TMPDIR/ch-switches.l 2>/dev/null && mv -f $TMPDIR/ch-switches.l $TMPDIR/ch-switches 2>/dev/null || :
  fi
  # Pass 1 (strict): prefer a switch whose off state persists, so a flicker-prone
  # level switch is skipped whenever a cleaner one exists on this device.
  # Probe strictly only while no switch is set yet, and at most once per accd
  # session. Re-probing on every pause loop is what made a flicker-prone device
  # cycle charging on/off near the limit; once a switch is chosen the plain
  # disable below holds it off without probing (or pulsing) again.
  # One current-verified strict pass that LOCKS the first switch which actually stops
  # charging (idle OR discharge). Runs whenever nothing is locked yet -- once a switch is
  # locked this guard is false, so it stops on its own (no sentinel needed). This replaces
  # the idle-preference + once-per-session gating that left discharge-only devices unlocked.
  if [ -z "${chargingSwitch[0]-}" ]; then
    cycle_switches off "" true
  fi
  # Pass 2 (lenient fallback): if nothing latched cleanly (e.g. the device only
  # exposes a flicker-prone level switch), restore the original behavior so
  # charging is still capped. Worst case here equals the previous behavior.
  not_charging || {
    case $prioritizeBattIdleMode in
      true) cycle_switches off Idle;;
      no)   cycle_switches off Discharging;;
    esac
    not_charging || cycle_switches off
  }
}


sw_holds() {
  # Level-type switches (charge_stop_level / pcap / charge_control_limit) are applied by the
  # FIRMWARE on its own evaluation tick (~30s on google_charger). An instant not_charging
  # check always fails there, and the old flip-on revert then CANCELLED the pending limit --
  # the filmed 40<->100 oscillation. Settle across up to 4 ticks before judging a level
  # switch; instant on/off switches keep the immediate check.
  not_charging && return 0
  $levelSwitch || return 1
  local _i=0
  while [ $_i -lt 4 ]; do
    sleep ${LVL_SETTLE_STEP:-10}
    not_charging && return 0
    _i=$(( _i + 1 ))
  done
  return 1
}

# rc21: is this offline charging mode -- the phone powered OFF with the cable in, showing the
# charge animation, running Android's `charger` binary instead of a full system?
# It matters because a cut there does not merely stop charging: `healthd`/charger reads the
# resulting online=0 as the cable having been pulled and POWERS THE PHONE OFF. Captured on a
# Mi A3 in this exact state:
#   [charger] charger: [33910] device unplugged, shutting down (@ 36910)
#   [charger] reboot: Power down / Powering off the SoC
# A user who plugs in overnight with the phone off would find it dead rather than charged.
# Detection is belt and braces: the boot-mode props name it directly on most devices, and where
# they do not, offline charging is the state where the `charger` process exists and zygote does
# not. Fails CLOSED (returns false) if it cannot tell, so normal Android is never affected.
in_charger_mode() {
  case "$(getprop ro.bootmode 2>/dev/null)" in *charger*) return 0;; esac
  case "$(getprop ro.boot.mode 2>/dev/null)" in *charger*) return 0;; esac
  pgrep -f zygote >/dev/null 2>&1 && return 1
  pgrep -x charger >/dev/null 2>&1 && return 0
  return 1
}


disable_charging() {

  local autoMode=true

  # rc21: never cut while the phone is in offline charging mode -- the cut reads as an unplug
  # and powers the device off (see in_charger_mode above). Refusing here costs nothing: the
  # phone is off, so there is no runtime to protect, and the limit is applied the moment Android
  # comes up. Deliberately placed at the top of the one function every pause path goes through,
  # rather than at each caller, so no future caller can miss it.
  if in_charger_mode; then
    ${isAccd:-false} && command -v _wlog >/dev/null 2>&1 \
      && _wlog "refusing to cut: offline charging mode (a cut here powers the phone off)" || :
    return 0
  fi

    [[ "${chargingSwitch[*]-}" != *\ -- ]] || autoMode=false

    case "${chargingSwitch[*]-}" in
      *pcap*|*stop_level*|*charge_control_limit*) levelSwitch=true;;
      *) levelSwitch=false;;
    esac

    if [[ "${chargingSwitch[0]-}" = */* ]]; then
      if [ -f ${chargingSwitch[0]} ]; then
        if ! { flip_sw off && sw_holds; }; then
          $isAccd || print_switch_fails "${chargingSwitch[@]-}"
          $levelSwitch || flip_sw on 2>/dev/null || :
          # rc8: RESPECT a manual lock. If the USER locked this switch (.user-locked, set by
          # write-config when a non-daemon `acc/acca -s` wrote it), NEVER auto-replace it -- the user
          # locks precisely to stop ACC ever using a different node. Just WARN (debounced) so they
          # can fix it; keep retrying THEIR switch each loop. An AUTO-locked switch (daemon-chosen)
          # still self-heals as before. (was: any failing locked switch was unset + auto-selected.)
          if [ -f $dataDir/.user-locked ]; then
            warn_once_per lockhold 21600 "⚠️ ACC: your locked charging switch isn't holding your ${capacity[3]:-?}% limit. Pick another in AccA - ACC will not change a locked switch for you."
          else
            unset_switch
            cycle_switches_off
          fi
        fi
      else
        invalid_switch
      fi
    else
      cycle_switches_off
    fi

    # rc23e: re-arm the suppression before confirming OUR OWN cut.
    #
    # not_charging CONSUMES the global $flip (batt-interface.sh: `local switch=${flip-}; flip=`), and
    # sw_holds above already consumed the `off` that flip_sw set. So by this line $flip is empty AND
    # chDisabledByAcc is still false - it is set below. Both suppressors of the kernel-status tie-break
    # are therefore off, and on a phone whose status node keeps reporting Charging under a current cut
    # the promotion fires and grades a WORKING cut as "still charging".
    #
    # The consequence is not a bad log line. It is `return 7` below, which means chDisabledByAcc is
    # never set: the phone is cut and ACC has forgotten it cut it. Every later pass re-promotes for the
    # same reason, is_charging stays true, and the loop parks in the charging branch - leaving the
    # entire resume path, which is the `else` of that same `if`, unreachable. Measured on a Mi A3 as
    # four stalls of 90-190s with the daemon awake and logging every 3s, which is loopDelay[0], the
    # charging branch's own nap.
    #
    # Suppressing here is safe and is the same judgement the flip test above makes: a cut that did NOT
    # work leaves current flowing in the charging direction, so the sign verdict says Charging on its
    # own and a broken switch is still graded broken. t79 covers exactly that case.
    flip=off
    if ! not_charging; then
      # fix7: restore 2022/2023 behavior -- report failure and let the daemon loop
      # retry the pause next tick (now also for --locked switches, since the
      # fallback above runs regardless of the lock). Do NOT exec/re-init mid-pause:
      # tearing the daemon down re-arms charging in the init window and thrashes on
      # a switch that only needs another loop to settle.
      return 7 # total failure
    fi

    (set +eux; eval '${runCmdOnPause-}') || :
    chDisabledByAcc=true

  if [ -n "${1-}" ]; then
    case $1 in
      *%)
        print_charging_disabled_until $1
        echo
        set +x
        until [ $(batt_cap) -le ${1%\%} ]; do
          sleep ${loopDelay[1]}
        done
        eval "${_logOn:-:}"
        enable_charging
      ;;
      *[hms])
        print_charging_disabled_for $1
        echo
        case $1 in
          *h) sleep $(( ${1%h} * 3600 ));;
          *m) sleep $(( ${1%m} * 60 ));;
          *s) sleep ${1%s};;
        esac
        enable_charging
      ;;
      *m[vV])
        print_charging_disabled_until $1 v
        echo
        set +x
        until [ $(volt_now) -le ${1%m*} ]; do
          sleep ${loopDelay[1]}
        done
        eval "${_logOn:-:}"
        enable_charging
      ;;
      *)
        print_charging_disabled
      ;;
    esac
  else
    $isAccd || print_charging_disabled
  fi
}


# rc21: rate-limit the APSD/AICL re-kick. Forcing a charger to re-run power-source detection and
# input-current negotiation is a RECOVERY action, not a per-loop one -- it is a heavy I2C round
# trip into the charger driver. Both gates that trigger it can stay true indefinitely: an
# input-cut switch (input_suspend/bypass/vbus) masks */online to 0 for the WHOLE time the cut is
# latched, and not_charging stays true on a current-cap switch whose current has not come back
# yet. So on those devices the re-kick fired on every single loop, forever, with nothing bounding
# it. Device-proven on a Mi A3 (battery/input_suspend): a burst of config writes kept the daemon
# in that state, the charger driver wedged, ACC's loop stalled ~76s, every power_supply read came
# back EMPTY while the cable was still attached, and the phone powered off at 71%.
#
# The re-kick is still fired -- just not faster than a charger can plausibly respond to one. The
# stamp lives in TMPDIR so it resets each boot, and an unreadable/garbage stamp is treated as due
# (fail toward the recovery action, never toward silence).
_rekick_due() {
  # The interval defaults INSIDE the function on purpose. A file-scope assignment would be a
  # hidden dependency: anything that pulls this helper out on its own (the unit tests extract
  # single functions from this file) would get an empty interval, the arithmetic test would
  # error, and the gate would answer "not due" forever -- silently disabling the recovery
  # re-kick rather than rate limiting it. Self-contained means it cannot fail that way.
  # 300s, not 30s. This is now the ONLY re-kick interval: accd's stall path used to keep a second
  # 300s counter in a different file, so the two could not see each other and the effective gap
  # collapsed to whichever fired last. The protective value wins because it is the one with a
  # hardware reason behind it - repeated input re-detection drops a QC/HVDCP contract to 5V. A
  # genuine stall still recovers on the FIRST kick with no delay; only repeats inside the window
  # are dropped.
  local _now= _then= _min=${_rekickMinInterval:-300}
  _now=$(date +%s 2>/dev/null) || return 0
  case ${_now:-x} in ''|*[!0-9]*) return 0;; esac
  _then=$(cat "$TMPDIR/.rekick" 2>/dev/null || echo 0)
  case ${_then:-x} in ''|*[!0-9]*) _then=0;; esac
  # rc24: DO NOT stamp here. The caller can still withhold on the contract gate without kicking
  # anything, and stamping first burned the whole 300s budget on a kick that never ran - so a real
  # stall stayed unrepaired for up to five minutes. rekick_usb stamps after it has acted.
  [ $(( _now - _then )) -ge "$_min" ] || return 1
  return 0
}


# rc24 UNIT NORMALISATION - read this before touching any threshold below.
#
# usb/voltage_now is MICROVOLTS on some kernels and MILLIVOLTS on others, from the identical path.
# Measured on the two test phones, both idle and unplugged: a Mi A3 reports 4144, a Pixel 6a
# reports 25000. Every electrical threshold in ACC was written in microvolts, so on a millivolt
# phone `>= 6000000` can never be true - the high-voltage contract latch never set, and rekick_usb
# and aim-high therefore treated a live 9V QC3 plug as an unnegotiated one, re-ran APSD and
# renegotiated it down to ~4.4V. That is the A3 outage, and it is a UNIT bug, not a policy bug.
#
# The bus is physically bounded: USB never exceeds 20V, and the input never exceeds 20A. So a
# reading above 20000 cannot be millivolts (that would be 20V+) and must be microvolts; at or below
# 20000 it is already millivolts. The same shape holds for current. Everything downstream now works
# in mV and mA, which are the units the comments were always written in.
_mv() {
  case "${1:-x}" in ''|x|*[!0-9]*) return 1;; esac
  [ "$1" -gt 20000 ] 2>/dev/null && echo $(( $1 / 1000 )) || echo "$1"
}

_ma() {
  local _a=${1#-}
  case "${_a:-x}" in ''|x|*[!0-9]*) return 1;; esac
  [ "$_a" -gt 20000 ] 2>/dev/null && echo $(( _a / 1000 )) || echo "$_a"
}

# The bus voltage in mV, empty when unreadable.
_vbus_mv() {
  local _v=
  { read -r _v < usb/voltage_now; } 2>/dev/null || :
  _mv "${_v:-}"
}

# Input current in mA from whichever node this kernel provides. usb/input_current_now does not exist
# on a Pixel 6a and usb/current_now does not exist on a Mi A3, so a single hardcoded path silently
# disables every check that depends on it - which is how a gate can end up permanently answering
# "no" on half the fleet.
_iin_ma() {
  local _n= _v= _a= _f=$TMPDIR/.iinmicro
  for _n in usb/input_current_now usb/current_now usb/input_current_settled \
            main-charger/current_now main/current_now; do
    [ -f "$_n" ] || continue
    _v=
    { read -r _v < "$_n"; } 2>/dev/null || :
    case "${_v:-x}" in ''|x|*[!0-9-]*) continue;; esac
    _a=${_v#-}
    # The scale rule is INLINE on purpose. Written as a second function it became a dependency of
    # this one, and every fixture that extracts helpers by name - t111, t112 and the scenario
    # replays - pulls _iin_ma without knowing to pull its new helper too. They then got an
    # undefined command, an empty reading, and reported "the supply is not dead" for seven cases
    # that were about a dead supply. A reader with no dependencies cannot be half-extracted.
    if [ "$_a" -gt 20000 ] 2>/dev/null; then
      grep -qxF "$_n" "$_f" 2>/dev/null || echo "$_n" >> "$_f" 2>/dev/null || :
      echo $(( _a / 1000 ))
    elif grep -qxF "$_n" "$_f" 2>/dev/null; then
      echo $(( _a / 1000 ))
    else
      echo "$_a"
    fi
    return 0
  done
  return 1
}


# WHY _iin_ma LEARNS THE SCALE (the rule above is inline in it)
#
# rc24: learn the node's units, do not re-guess them from every reading.
#
# _ma decides per value: above 20000 it must be microamps, at or below it is already milliamps.
# That is sound for a charging reading and wrong for a collapsed one. Measured on a Mi A3, whose
# usb/input_current_now is microamps:
#
#     charging   2696040  -> 2696 mA   correct
#     collapsed     5353  -> 5353 mA   a 5.35 mA supply reported as 5.35 A
#
# The whole band from about 51 to 20000 - which is 0.05 mA to 20 mA, precisely "collapsed but not
# quite zero" - reads as alive on a microamp kernel. The A3's own measured collapse sat at 5190-5353.
# Zero normalises correctly in either scale, which is why fixtures built on zero never caught it.
#
# A reading above 20000 is PROOF the node is microamps, because no port carries 20 A. That proof is
# recorded per node for the boot, and afterwards every reading from that node is divided - including
# the small ones the magnitude rule cannot classify. Normal charging produces such a reading on every
# plug, so the scale is known long before a collapse is ever seen.
#
# A node that has never read high keeps today's behaviour: its small values are returned untouched
# and an ambiguous reading therefore still fails closed in _hv_may_kick, which is what keeps this a
# missed repair rather than a spurious re-detection.

# The thresholds, in the units the hardware actually speaks.
: ${hvLatchMv:=6500}     # at or above this, a contract exists
: ${hvLostMv:=6000}      # sustained below this while plugged = a supply in a low-voltage phase
: ${hvPeakMaxMv:=5500}   # a plug whose peak stayed under this was never negotiated
: ${hvDeadMa:=50}        # input current at or below this = the supply is delivering nothing


# rc24 CONTRACT POLICY - the one rule every caller goes through.
#
#   LIFT  raise the input CURRENT limit on the charger-owned supplies. Always safe: current is not
#         the contract, and no allow-listed node renegotiates anything. This is the answer to a
#         stall, to ICL=0, and to a resume.
#   KICK  apsd_rerun / rerun_aicl. This RE-DETECTS the charger and can drop a won contract to 5V.
#         Allowed only when there is demonstrably nothing to lose.
#
# A kick needs ALL of:
#   - no contract latched this plug
#   - charger type is not a high-voltage type
#   - the highest voltage seen this plug is under 5.5V (a plug that was ever high stays "negotiated")
#   - input current is essentially zero, so the supply really is dead rather than merely slow
#   - it has not already been kicked this plug
#   - the user has not set `acc -sk off`
# Anything short of all six gets a LIFT instead.
_hv_may_kick() {
  [ ! -f "$TMPDIR/.hvcontract" ] || return 1
  [ ! -f "$TMPDIR/.hvkicked" ] || return 1
  [ ! -f "$dataDir/.rekick-off" ] || return 1
  present 2>/dev/null || return 1
  local _t= _tn= _pk= _in=
  for _tn in real_type usb_type type; do
    [ -f "usb/$_tn" ] || continue
    _t=$(cat "usb/$_tn" 2>/dev/null) || :
    break
  done
  case "${_t:-}" in *HVDCP*|*PD*|*QC*|*hvdcp*|*pd*) return 1;; esac
  # .hvpeak is stored in mV (the writer normalises), so this compares like with like.
  _pk=$(cat "$TMPDIR/.hvpeak" 2>/dev/null || echo 0)
  case "${_pk:-x}" in ''|*[!0-9]*) _pk=0;; esac
  [ "$_pk" -lt "${hvPeakMaxMv:-5500}" ] 2>/dev/null || return 1
  # No readable input-current node means we cannot prove the supply is dead, and a kick is only ever
  # justified against a supply proven dead. Fail closed.
  _in=$(_iin_ma) || return 1
  [ "$_in" -le "${hvDeadMa:-50}" ] 2>/dev/null || return 1
  # rc24: CLAIM the kick here rather than trusting each caller to remember. The once-per-plug rule
  # was enforced by convention - rekick_usb set the marker, aim-high set the marker - and a third
  # caller added later would silently get an unlimited budget. Claiming it inside the gate makes the
  # invariant structural: whoever is told "yes" has already spent the plug's single repair. The
  # conservative failure mode is a kick that was authorised and then not carried out, which costs
  # one missed repair rather than an unbounded re-detection loop on a live contract.
  : > "$TMPDIR/.hvkicked" 2>/dev/null || :
  return 0
}


# Raise the input current limit on the charger-owned supplies only. Never usb/, dc/, pc_port/ or
# tcpm*: those are the negotiation side, and one write to usb/current_max was measured dropping a
# port to 100mA. Through write(), so the blacklist and the write ledger apply.
_hv_lift() {
  local _n=
  for _n in main/current_max main-charger/current_max mainchg/current_max charger/current_max \
            gccd/current_max bbc/current_max main/input_current_limit main-charger/input_current_limit \
            main/input_current_settled main-charger/input_current_settled; do
    [ -f "$_n" ] || continue
    write 5000000 "$_n" 0 || :
  done
  return 0
}


rekick_usb() {
  # rc22: the ONE place a USB re-kick happens. apsd_rerun/rerun_aicl make the charger re-run input
  # detection. That is what recovers a stalled charger, and also what renegotiates a live QC/PD
  # contract down to 5V -- and a PD contract does not come back on its own, only a physical replug
  # restores it, which is why the field workaround was always "unplug and plug it back in".
  #
  # set_ch_curr's clear path fired it raw, from two places. Neither honoured `acc -sk off` -- the
  # switch whose own help text says "turn it off if it disturbs fast charging on your phone" -- and
  # neither wrote a ledger line, so a re-kick left no trace in any diagnostic bundle. In the curtana
  # bundle the clear's own current writes are recorded at 13:26:38 with no re-kick beside them.
  local _reason=${1:-unspecified} _rn=
  if [ -f "${dataDir:-/data/adb/vr25/acc-data}/.rekick-off" ]; then
    command -v _wlog >/dev/null 2>&1 && _wlog "rekick skipped ($_reason): acc -sk off" || :
    return 1
  fi
  if ! _rekick_due; then
    command -v _wlog >/dev/null 2>&1 && _wlog "rekick skipped ($_reason): too soon" || :
    return 1
  fi

  # NEVER RENEGOTIATE A CONTRACT THAT IS ALREADY WORKING.
  #
  # This is the whole hazard of the function, and until now the only thing standing between a user
  # and it was a rate limit. apsd_rerun re-runs charger-type detection; on a QC or PD supply that
  # means dropping to the 5V floor, and it does not come back without a physical replug - the note
  # at the top of this function has said so all along while the code fired it regardless.
  #
  # A re-kick is a REPAIR. Repairing something that is not broken can only lose: the best case is
  # the contract survives and nothing was gained, the worst case is a user on 9V/2A wakes up on
  # 5V/500mA until they unplug. Traced on a Mi A3: 7712800 uV at the start of a run, a 5V floor by
  # the middle, and no software path back - apsd_rerun, two rounds of rerun_aicl and `acc -e` all
  # failed while the input limit ratcheted 900000 -> 0.
  #
  # So: if a high-voltage contract is live AND the input limit is healthy, there is nothing to
  # recover and this must not run. The stalled-charger cases this function exists for all present
  # as a collapsed limit or a 5V supply, and both still fall through to the re-kick below.
  #
  # 6V threshold: a 5V supply sagging under load (5.0-5.2V measured) can never reach it, and the
  # lowest real negotiated step is 9V. Two builtin reads, no fork.
  # VOLTAGE ALONE. The first version of this guard also required the input limit to be above
  # 600mA, and that condition was the hole it leaked through.
  #
  # A low input limit is almost always ACC'S OWN CAP, not a sick charger. During a cap cycle ACC
  # deliberately drives the limit to 500mA - and the guard then read "unhealthy", permitted the
  # re-kick, and tore down the contract at exactly the moment a cap was applied. Traced from the
  # write ledger on a Mi A3, one run: the guard correctly refused twice at 7851mV and 6005mV, and
  # let two through while a cap held the limit at 700mA, after which the supply sat at 4675mV.
  #
  # So the only question worth asking is whether a negotiated contract exists. If it does, a
  # re-kick can only lose it - there is nothing above 5V that apsd_rerun can win back, and it does
  # not come back without a physical replug. The stalled-charger case this function exists for is
  # handled better downstream anyway: the zero-ICL branch below restores the recorded limit
  # directly, which is what actually recovered a stuck phone in testing, and it does so without
  # renegotiating anything.
  #
  # Below 6V there is no high-voltage contract to protect and the re-kick proceeds as before.
  # A LATCH, NOT AN INSTANTANEOUS READING.
  #
  # The previous version compared usb/voltage_now against 6V at the moment of the call. That is not
  # a reliable statement about whether a negotiated contract exists, because a high-voltage supply
  # SAGS UNDER LOAD: a QuickCharge 3 contract measured 6433-6712mV on a Mi A3 while delivering ~2A,
  # already brushing the threshold. The instant it dipped below, the guard concluded there was no
  # contract to protect, permitted a re-kick, and the re-kick made the drop permanent. Ledger from
  # that run: a clean sequence of rate-limit skips, then "rekick usb/apsd_rerun <- 1" at 07:28:59,
  # and the supply sat at 4860mV/400mA afterwards.
  #
  # A contract is a property of the PLUG, not of this millisecond. So latch it: once a high voltage
  # has been seen since the cable went in, treat the contract as live until the cable comes out.
  # accd sets and clears $TMPDIR/.hvcontract around the plug transition. A sag can no longer open
  # the door, and a genuine 5V-only supply never sets the latch, so real stalls still get repaired.
  # rc24 CONTRACT POLICY. One question decides everything below: may this plug be re-detected at
  # all? If not, the stall is answered by lifting the input current limit, which cannot disturb a
  # contract, and no APSD is fired. This replaces the old bare latch check, which said "skip" and
  # then left every other caller to invent its own escape - the escapes are what dropped 9V to 4.4V.
  if ! _hv_may_kick; then
    _hv_lift || :
    _rkv=
    { read -r _rkv < usb/voltage_now; } 2>/dev/null || :
    command -v _wlog >/dev/null 2>&1 && _wlog "rekick withheld ($_reason): lifted the input limit instead (now $(_vbus_mv)mV) - re-detection would renegotiate a plug we have already won" || :
    return 1
  fi
  : > "$TMPDIR/.hvkicked" 2>/dev/null || :

  # NO LATCH YET - AND A SINGLE READ HERE IS THE v3 BUG VERBATIM.
  #
  # There are real windows where no loop has latched this plug and a contract nonetheless exists:
  #   - the daemon is STOPPED (users stop ACC to charge at full speed) and AccA clears a current
  #     limit, which reaches this function through set-ch-curr's clear path;
  #   - the plug-time aim-high block is mid-poll, holding for up to 17s before it writes the latch,
  #     while the charger has already stepped up to 9V.
  # In both, the only thing standing between the user and a dead contract is this check - and a
  # single instantaneous sample is exactly what failed on hardware: a QC3 line delivering ~2A was
  # measured at 6433-6712mV, dipping under the threshold, and one unlucky sample permitted the
  # re-kick that killed it.
  #
  # So SAMPLE, do not glance. Three reads about a second apart, refuse if ANY of them shows a
  # negotiated contract. A real high-voltage supply cannot read below 6V on three consecutive
  # samples; a 5V-only or collapsed supply always does. The cost is two seconds on a path already
  # rate-limited to once per five minutes, and it buys the difference between a guess and a fact.
  _rkv=; _rkhi=0; _rkn=0
  while [ $_rkn -lt 3 ]; do
    _rkn=$(( _rkn + 1 ))
    _rkv=
    { read -r _rkv < usb/voltage_now; } 2>/dev/null || :
    case "${_rkv:-x}" in
      ''|x|*[!0-9]*) : ;;
      *) [ "$(_mv "$_rkv")" -ge "${hvLatchMv:-6500}" ] 2>/dev/null && { _rkhi=$_rkv; break; } ;;
    esac
    [ $_rkn -lt 3 ] && sleep 1
  done
  if [ "$(_mv "${_rkhi:-0}")" -ge "${hvLatchMv:-6500}" ] 2>/dev/null; then
    : > "$TMPDIR/.hvcontract" 2>/dev/null || :
    command -v _wlog >/dev/null 2>&1 && _wlog "rekick skipped ($_reason): $(( _rkhi / 1000 ))mV negotiated contract seen while sampling - apsd_rerun would drop it to 5V until replug" || :
    return 1
  fi
  for _rn in */apsd_rerun */rerun_aicl; do
    [ -w "$_rn" ] || continue
    command -v _wlog >/dev/null 2>&1 && _wlog "rekick $_rn <- 1 ($_reason)" || :
    echo 1 > "$_rn" 2>/dev/null || :
  done
  # VERIFY the input limit came back.
  #
  # apsd_rerun ZEROES the ICL while charger detection re-runs; rerun_aicl is what restores it. The
  # loop above writes both, which is why this normally self-corrects in milliseconds - but nothing
  # ever checked. Measured by hand on a Mi A3 against a PD-only laptop brick: after apsd_rerun the
  # ICL read 0 and stayed there until AICL was run a second time.
  #
  # An operation whose purpose is to restore full charging speed must not be able to leave a phone
  # at zero current. One read, one retry, and only when the limit is actually still zero.
  _rkicl=
  { read -r _rkicl < usb/current_max; } 2>/dev/null || :
  case "${_rkicl:-x}" in
    ''|x|0)
      sleep 2
      { read -r _rkicl < usb/current_max; } 2>/dev/null || :
      case "${_rkicl:-x}" in
        ''|x|0)
          # Still zero after a second look. Another rerun_aicl is the WRONG remedy, and this used to
          # do exactly that.
          #
          # AICL is a MEASUREMENT of what the source can supply, not a repair. Re-running it on a
          # degraded supply just re-measures a degraded supply, and each pass ratchets the estimate
          # further down. Traced on a Mi A3 whose QuickCharge contract had collapsed to a 5V floor,
          # sampling every 10s:
          #
          #     start        icl 900000   charging
          #     rerun_aicl   icl 800000 -> 700000 -> 500000
          #     apsd_rerun   icl 300000 -> 100000 -> 0
          #     acc -e       icl 0, and the phone DISCHARGED on a live cable for the next 40s
          #
          # Writing the limit back ended it instantly in the same session: 0 -> 1700000, charging at
          # 1.35A. So restore the recorded default and let the driver clamp - which is ACC's standing
          # rule everywhere else, and what the clear path in set-ch-curr.sh already does before it
          # calls this function.
          #
          # Only the input-negotiation nodes, and only when the limit is genuinely at zero: a phone
          # that is charging fine must never have a snapshot replayed onto it.
          command -v _wlog >/dev/null 2>&1 && _wlog "rekick icl still 0 after $_reason - restoring recorded defaults (aicl cannot repair a degraded source)" || :
          while IFS= read -r _rkl; do
            case "$_rkl" in
              */current_max::*|*/input_current*::*) : ;;
              *) continue ;;
            esac
            _rkn=${_rkl%%::*}
            _rkd=${_rkl##*::}
            case "${_rkd:-x}" in ''|x|*[!0-9]*) continue;; esac
            [ -w "$_rkn" ] || continue
            # rc24 LIFT: release HIGH and let the driver clamp - the rule apply_on_plug already
            # uses. The recorded default is a SNAPSHOT of whatever the node read when ACC first
            # identified it; taken on a computer port that is 500000, and replaying it on a wall
            # charger pinned the phone at 500mA for the rest of the session. Through write(), so the
            # blacklist and the write ledger apply - this was a raw echo that bypassed both.
            command -v _wlog >/dev/null 2>&1 && _wlog "rekick lift $_rkn <- 5000000 (recorded default was $_rkd)" || :
            write 5000000 "$_rkn" 0 || :
          done < "$TMPDIR/ch-curr-ctrl-files" 2>/dev/null || : ;;
      esac ;;
  esac
  # rc24: the budget is spent HERE, where a kick or a lift actually happened.
  echo "$(date +%s 2>/dev/null)" > "$TMPDIR/.rekick" 2>/dev/null || :
  return 0
}


enable_charging() {

    # Same unplug-blip guard as below: restore the saved switch config, but only
    # physically flip it ON when actually plugged in (online); otherwise just clear the
    # saved state so the next plug-in restores cleanly without a phantom "Charging" flash.
    # rc5 (#4/#18): restore the idle-avoidance switch. Source in the CURRENT shell so the parent
    # chargingSwitch is actually updated (the old subshell discarded it), and re-arm input-cut /
    # current-cap switches even while online=0 (same name exception as the resume gate below).
    if [ -f $TMPDIR/.sw ]; then
      . $TMPDIR/.sw 2>/dev/null || :; rm -f $TMPDIR/.sw 2>/dev/null || :
      # rc22: NOT gated on present -- see the release below for why. A switch latched off while the
      # cable is out must still be returned to its resume value, or nothing electrically undoes it.
      flip_sw on 2>/dev/null || :
    fi

    if ! $ghostCharging || { $ghostCharging && online; }; then

      # Unplug blip fix: do NOT physically flip the switch ON while the charger is
      # offline. On unplug the daemon still calls enable_charging to leave the switch
      # in the "resume" state ready for the next plug-in, but actually re-arming the
      # node makes the UI flash ~2s of phantom "Charging". online=0 means there is no
      # power anyway, so skipping the flip changes nothing electrically -- it only
      # suppresses the cosmetic blip. State is still made correct below
      # (chDisabledByAcc=false), and the next real plug-in re-runs this and flips on.
      # rc(6.3.2): an input-CUT switch (input_suspend, *_suspend, *bypass*, vbus_disable) cuts
      # the charger input, so while paused */online reads 0 -- meaning `online` can NEVER become
      # true to re-arm it, and charging is stuck off until a reboot (the no-charge-til-reboot bug
      # on these devices, e.g. MTK Moto). For these switches the online signal is unreliable, so
      # flip ON regardless, and rc22: regardless of `present` too.
      #
      # The old gate rested on "skipping the flip changes nothing electrically". That is false: it
      # changes everything on the NEXT plug. A node left latched off keeps blocking charge as soon
      # as power returns, and the only thing that would undo it is a later enable_charging from a
      # RUNNING daemon -- which is exactly what is missing here. `acc -e` and `acc -d` stop the
      # daemon by design and never restart it, and the daemon's EXIT trap calls this on the way
      # out, when no daemon is left to retry.
      #
      # Measured on a Mi A3, unplugged, battery/input_suspend latched at 1: `acc -e` printed
      # "Charging enabled", exited 0, wrote no switch value at all, and left the phone unable to
      # charge. A direct `echo 0` to the same node worked, so the hardware was never the problem.
      #
      # The anti-blip reason is obsolete: write() is idempotent (read-before-write), so a switch
      # already at its resume value writes nothing and cannot blip. The only case that writes is
      # the latched one, which must never be skipped.
      #
      # Re-negotiation stays behind present: APSD/AICL only mean anything with a cable attached.
      # rc23c: the SWEEP fallback needs a cable. cycle_switches is DISCOVERY - it walks every
      # candidate and each one costs a full not_charging verification, 35 one-second iterations with
      # a status read (and a fork) per iteration. flip_sw returns 2 immediately when no switch is
      # configured, so on a phone with chargingSwitch=() this `||` fired on every enable_charging
      # and swept, forever, with no charger attached and nothing to re-arm.
      #
      # Measured on a Mi A3, unplugged, screen off, rc23:
      #     system forks, ACC stopped :    96 per 600s
      #     system forks, ACC running :  4068 per 600s
      #     accd CPU                  :  5452 ticks per 600s, about 9% of one core
      #     loop passes logged        :     0
      # The trace showed two back-to-back 35s verify loops per 90s, indefinitely. A Pixel with a
      # configured switch never reaches this line, which is exactly why it cost 83 forks per pass
      # while the A3 burned 6.6 forks per second. The Pixel 6 Pro field report ships the same empty
      # chargingSwitch, so this is not a lab-only state.
      #
      # ONLY the sweep is gated. Releasing a latched switch with the cable out must still happen -
      # that is the rc22 fix for a phone left unable to charge - and it is done by the .sw restore
      # block above and by flip_sw itself, both untouched. A sweep cannot re-arm anything
      # electrically when there is no charger, so gating it costs no capability: with a cable
      # attached, discovery still runs exactly as before.
      # rc24: the fallback sweep gets a ceiling. _swEnd is a local of the helper, so mksh's dynamic
      # scoping hands it to cycle_switches for this call only - accd's exit-trap restore sweep still
      # walks every candidate unbounded, which is what keeps a stranded phone able to charge again.
      # Unbounded here, an empty chargingSwitch held a plugged A3 off charge for over five minutes.
      flip_sw on || { present && _rearm_sweep; } || :
      if present; then
        # D8 (rc5: extended to current-cap classes): after un-cutting, re-run APSD/AICL so the
        # charger re-negotiates. Input-cut switches (input_suspend/bypass/vbus) mask */online to 0
        # -> fire when present && !online. CURRENT-CAP switches (constant_charge_current[_max],
        # */current_max, */input_current) keep */online=1 but the CHARGE CURRENT can stay 0 after
        # the cap is restored -> fire while the cable is present and charging has NOT actually
        # resumed (not_charging), regardless of online. Harmless when already charging (no-op
        # re-detect); self-limits once current flows. (rc4 D8 missed both: the *constant_charge_
        # current* (no _max) name, and the !online gate that a current-cap never satisfies.)
        case "${chargingSwitch[*]-}" in
          # Both arms went straight at the nodes, bypassing rekick_usb() and therefore the user's
          # `acc -sk off`. The help text tells people that switch stops ACC re-running input
          # detection - the usual advice when a QC/PD contract keeps collapsing - and these two ran
          # on every resume regardless. rekick_usb() carries the off flag, the rate limit and the
          # ledger entry; nothing here needs to reach past it.
          *current_max*|*input_current*|*constant_charge_current*)
            # rc24: clear `flip` first. flip_sw on leaves flip=on, and not_charging treats any
            # non-empty flip as a SWITCH TEST - so this became a 35-iteration ON-test that answered
            # "charging started", and the re-kick then fired AFTER a successful resume. The question
            # here is only "is current flowing".
            flip=
            present && not_charging && rekick_usb resume 2>/dev/null || : ;;
          *suspend*|*bypass*|*vbus*)
            present && ! online && rekick_usb resume 2>/dev/null || : ;;
        esac
      fi

    else
      wait_plug
      return 0
    fi

    # rc23e: clear the flag only when the release is OBSERVED, not when the write is issued.
    #
    # Once $flip has been consumed this flag is the SOLE suppressor of the kernel-status tie-break
    # (batt-interface.sh). Clearing it on the write alone means that if the ON write did not actually
    # restore current, the very next pass promotes status to Charging, is_charging returns true, and the
    # whole resume path becomes unreachable - including the resume-stall watchdog at accd.sh:1613 that
    # exists to catch precisely this, and which is blinded by the flag its own resume just cleared.
    #
    # The check below runs while the flag is STILL TRUE, so the tie-break is suppressed and it reads the
    # current sign honestly rather than the kernel's stale "Charging". Asking with the promotion live
    # would be circular: it would answer "yes, charging" because of the very staleness being tested.
    #
    # Leaving it true costs nothing when the resume did work - the next pass sees real charging current
    # and clears it there - and buys a retry when it did not.
    if not_charging; then
      :
    else
      chDisabledByAcc=false
    fi

  set_temp_level

  if [ -n "${1-}" ]; then
    case $1 in
      *%)
        print_charging_enabled_until $1
        echo
        set +x
        until [ $(batt_cap) -ge ${1%\%} ]; do
          sleep ${loopDelay[0]}
        done
        eval "${_logOn:-:}"
        disable_charging
      ;;
      *[hms])
        print_charging_enabled_for $1
        echo
        case $1 in
          *h) sleep $(( ${1%h} * 3600 ));;
          *m) sleep $(( ${1%m} * 60 ));;
          *s) sleep ${1%s};;
        esac
        disable_charging
      ;;
      *m[vV])
        print_charging_enabled_until $1 v
        echo
        set +x
        until [ $(volt_now) -ge ${1%m*} ]; do
          sleep ${loopDelay[0]}
        done
        eval "${_logOn:-:}"
        disable_charging
      ;;
      *)
        print_charging_enabled
      ;;
    esac
  else
    $isAccd || print_charging_enabled
  fi
}


# condensed "case...esac"
# The PATTERN has to be eval'd: it is a glob alternation like --test*|-t*|-x and
# a case arm cannot come from a quoted expansion. The VALUE never needed to be.
# It used to be interpolated into the same string, so eval saw
#     case "$(reboot)" in
# and the shell ran the substitution. $1 here is the caller's first CLI argument
# (acc.sh:322, 330, 663 all pass it), so `acc '$(cmd)'` executed cmd as root.
# Staging the value in a variable and referencing it keeps the pattern eval'd
# while the value goes through one ordinary expansion, which is never rescanned.
eq() {
  _eqv=$1
  eval "case \"\$_eqv\" in
    $2) return 0;;
  esac"
  return 1
}


flip_sw() {

  flip=$1
  local on=
  local off=
  local _wrote=0

  set -- ${chargingSwitch[@]-}
  [ -f ${1:-//} ] || return 2
  swValue=

  while [ -f ${1:-//} ]; do

    [ $# -ge 3 ] || return 2   # rc5 (#10): a 2-field / malformed switch has no OFF value -> $3 empty -> "[ = 3600mV ]" abort
    on="$(parse_value "$2")"
    # "pcap" resolves to pause_capacity -- used as the OFF (stop) value so charging
    # stops AT your limit. Numeric-safe: empty/garbage pause_capacity -> a safe low
    # cap (60), so it can only cap low, never charge on. The ON (resume) value is 100,
    # NOT pcap: charge_stop_level latches "stopped", and only a higher value (100)
    # re-arms the charger -- writing the limit value back would leave it frozen.
    [ "$2" != pcap ] || on=100
    if [ "$3" = 3600mV ]; then
      # rc7 (U4): the float-voltage node can blip empty/garbage during PD/AICL renegotiation. An
      # unguarded "[ $off -lt 10000 ]" then aborts flip_sw under set -e (pause lost). Coerce: if
      # unreadable, FAIL this flip (caller retries next loop) rather than write a wrong-unit value.
      off=$(cat $1 2>/dev/null)
      case ${off:-x} in
        ''|*[!0-9-]*) return 1;;
        *) [ $off -lt 10000 ] && off=3600 || off=3600000;;
      esac
    elif [ "$3" = pcap ]; then
      case ${capacity[3]-} in ''|*[!0-9]*) off=60;; *) off=${capacity[3]};; esac
      # A percentage cap only stops charging once the level REACHES it, so pause_capacity as the
      # OFF value cannot stop a phone that is BELOW the limit - which is every forced disable
      # (acc -d, AccA's "disable charging") taken before the limit is reached. The write succeeds,
      # sw_holds waits its four firmware ticks, charging legitimately continues, and
      # disable_charging concludes the switch is broken: unset_switch runs, chargingSwitch is
      # emptied and the daemon exits 7, leaving the phone with NO charge control until something
      # restarts it. Reproduced on a Pixel 6a at 74% with pause 75: the cap went to 75, the phone
      # kept charging, and the only switch the device has was thrown away.
      #
      # Cap at the CURRENT level when that is lower, so an OFF always means "stop now". At or
      # above the limit this is pause_capacity exactly as before, so the ordinary pause path that
      # every other test exercises is byte-for-byte unchanged.
      _fsLvl=$(batt_cap 2>/dev/null)
      case ${_fsLvl:-x} in
        ''|*[!0-9]*) ;;
        *) [ "$_fsLvl" -lt "$off" ] 2>/dev/null && off=$_fsLvl || :;;
      esac
    else
      off="$(parse_value "$3")"
    fi

    [ $flip = on ] || cat $currFile > $curThen
    # rc7 (U1): write EVERY node of a multi-node group (best-effort) instead of aborting on the
    # first node that fails -- a group like the Pixel all-paths current cut needs ALL nodes set, and
    # actual success is judged by not_charging afterwards, not by one node's write. Report total
    # failure (return 1) only if NO node could be written at all.
    write \$$flip $1 && _wrote=1 || :

    [ $# -lt 3 ] || shift 3
    [ $# -ge 3 ] || break

  done
  [ $_wrote = 1 ] || return 1
}


invalid_switch() {
  $isAccd || print_invalid_switch
  unset_switch
  cycle_switches_off
}


log_on() {
  [ ! -f ${log:-//} ] || {
    [[ $log = */accd-* ]] && set -x || set -x 2>>$log
  }
}

# rc21: mksh SAVES AND RESTORES the shell options across every function call, so a `set -x`
# performed INSIDE log_on() is undone the instant log_on returns -- the call is a no-op and
# tracing never comes back. Every call site pairs a `set +x` (to keep a long polling loop out
# of the log) with a log_on afterwards, so on mksh the log simply stopped at the first wait and
# the rest of the operation was never traced. Device-proven: a function that runs `set -x`
# leaves $- with no x in the caller, while the same `set -x` written in the caller's own scope
# does not. Same text, evaluated in the caller's scope, where the option actually sticks.
_logOn='[ ! -f ${log:-//} ] || { [[ $log = */accd-* ]] && set -x || set -x 2>>$log; }'


misc_stuff() {
  set -eu
  mkdir -p $dataDir 2>/dev/null || :
  # rc21: $config can EXIST and not be a regular file -- a directory left behind by a bad backup
  # restore or a botched script. `[ -f ]` correctly reads that as "no config", but the remedy on
  # the same line then runs `cat default > $config`, which fails with "Is a directory" and, under
  # set -e, takes the front-end down with it: `acc -i`, `acc -s` and every `acc -D` start died, so
  # the daemon could not be started to repair the very thing that was broken, and nothing said why.
  # Device-proven on a Mi A3: a garbage config FILE starts the daemon fine, a directory kills it
  # before it can even open its log. Clear the obstruction, prefer the daemon's last known-good
  # copy over the shipped defaults so the user's own limits come back rather than silently
  # resetting to 80/70, and never let this write abort the caller.
  if [ -e $config ] && [ ! -f $config ]; then
    mv -f $config $config.bad.$$ 2>/dev/null || rm -rf $config 2>/dev/null || :
    if [ -f $dataDir/.config-good ]; then
      cat $dataDir/.config-good > $config 2>/dev/null || :
    else
      cat $execDir/default-config.txt > $config 2>/dev/null || :
    fi
  fi
  [ -f $config ] || cat $execDir/default-config.txt > $config

  # custom config path
  ! eq "${1-}" "*/*" || {
    [ -f $1 ] || cp $config $1
    config=$1
  }
  unset -f misc_stuff
}


notif() {
  # rc21 SECURITY: the message used to be interpolated into this `su -c` string inside DOUBLE
  # quotes, so the shell that su starts parsed it: `acc -n '$(cmd)'` ran cmd (as uid 2000). The
  # daemon also feeds switch names and limits through here, so a hostile value in a config or a
  # node name reached a shell too. Embed it SINGLE-quoted instead, escaping any single quote the
  # message contains -- the same idiom write-config.sh already uses for stored strings. Nothing
  # inside single quotes is expanded, so no message can become code.
  _nmsg="${*:-:)}"
  _nmsg=$(printf %s "$_nmsg" | sed "s/'/'\\\\''/g")
  su -lp 2000 -c "/system/bin/cmd notification post -S bigtext -t \"🔋ACC | $(date +%H:%M)\" \"Tag$(date +%s)\" '$_nmsg'" < /dev/null > /dev/null 2>&1 || :
}


warn_once_per() {
  # rc15: rate-limited notification that SURVIVES daemon restarts + reboots. Stores the last-warn epoch
  # in $dataDir/.warn-<key> (persistent) instead of a 0-byte $TMPDIR sentinel that the pause/resume loop
  # wiped every non-breach tick -- which turned a flapping/leaky switch's "warn once" into a per-loop
  # spam. Now a problem warns at most once per <window> seconds no matter how often the loop sees it.
  # $1=key  $2=min-seconds-between  $3=message
  local _wf=$dataDir/.warn-$1 _now _last
  _now=$(date +%s 2>/dev/null) || _now=0
  _last=$(cat "$_wf" 2>/dev/null || echo 0); case "$_last" in ''|*[!0-9]*) _last=0;; esac
  if [ "$_now" = 0 ] || [ $(( _now - _last )) -ge "$2" ]; then
    echo "$_now" > "$_wf" 2>/dev/null || :
    # rc15: warnings are SILENT by default -- the user asked to remove the popups ("user is not
    # stupid"). The protective capping + auto-select still run; the message is only LOGGED, never shown.
    # Power users can opt the notifications back in with `acc -s warnings=on` (still rate-limited above).
    case ${warnings:-off} in
      on|true|1) notif "$3";;
      *) echo "$(date '+%m-%d %H:%M') $3" >> $dataDir/warnings.log 2>/dev/null || :;;
    esac
  fi
}


parse_value() {
  if [ -f "$1" ]; then
    chmod a+r $1 && cat $1 || echo 20
  else
    echo "$1" | sed 's/::/ /g'
  fi 2>/dev/null
}


print_header() {
  echo "Advanced Charging Controller (ACC) $accVer ($accVerCode)
(C) 2017-2024, VR25
GPLv3+"
}


resetbs() {
  is_android || return 0
  set +e
  dumpsys batterystats --reset
  rm -rf /data/system/battery*stats*
  dsys_batt set ac 1
  dsys_batt set level 100
  sleep 2
  dsys_batt reset
  set -e
} &>/dev/null


sdp() {
  # rc22: count a polarity CHANGE here, not only where the coulomb counter proves one.
  # .dpol_unstable is what stops accd's re-latch loop on mode-dependent-sign hardware, but the only
  # thing that used to set it was the arbitration in idle_discharging, which needs a fresh window
  # AND a >=150 uAh move. A pack holding at taper moves less than that, and taper is exactly when
  # the current sign oscillates around zero and the re-latch fires hardest. So the guard could
  # never arm in the case it exists for. Measured on a Mi A3 holding at 74%: charge_counter flat
  # over 31s, current swinging +34mA to -13mA, 15 latches recorded and 0 flips counted.
  if [ -n "${_DPOL-}" ] && [ "${_DPOL}" != "$1" ]; then
    _dfl=$(cat $TMPDIR/.dpol_flips 2>/dev/null || echo 0)
    case "$_dfl" in ''|*[!0-9]*) _dfl=0;; esac
    _dfl=$((_dfl + 1))
    echo $_dfl > $TMPDIR/.dpol_flips 2>/dev/null || :
    [ $_dfl -lt 2 ] || touch $TMPDIR/.dpol_unstable 2>/dev/null || :
  fi
  _DPOL=$1
  # Keep the value in its own file too, the way the flip counter already is. The daemon's main
  # shell does not always hold _DPOL, so a cache republished from the variable alone dropped the
  # learned polarity and forced a re-derivation. Measured on a Pixel: '-' before, empty after.
  echo "$1" > $TMPDIR/.dpol 2>/dev/null || :
  # rc22: REPLACE the cached polarity instead of appending one more line. Appending left the file
  # holding every latch this boot -- the A3 above had 15 _DPOL= lines, two of them contradicting the
  # rest -- and since the daemon SOURCES this file, whichever line happened to be written last
  # silently won. Written to a temp and moved into place: the file must never be observed
  # half-written by a daemon sourcing it, which is why the original appended rather than truncating.
  _dpt=$TMPDIR/.batt-interface.sh.$$
  if { grep -v '^_DPOL=' $TMPDIR/.batt-interface.sh 2>/dev/null; echo "_DPOL=$1"; } > $_dpt 2>/dev/null \
     && [ -s $_dpt ]; then
    mv -f $_dpt $TMPDIR/.batt-interface.sh 2>/dev/null || rm -f $_dpt 2>/dev/null
  else
    rm -f $_dpt 2>/dev/null
    echo _DPOL=$1 >> $TMPDIR/.batt-interface.sh   # last resort: the old behaviour beats no record
  fi
}


unset_switch() {
  charging_switch=
  . $execDir/write-config.sh
}


wait_plug() {
  $isAccd || {
    echo "ghostCharging=true"
    print_unplugged
  }
  while ! online; do
    sleep ${loopDelay[1]}
    ! $isAccd || mask_capacity 2>/dev/null || :
    set +x
  done
  eval "${_logOn:-:}"
  enable_charging "$@"
}


_wlog() {
  # rc20-alpha: write ledger. Every ACTUAL node write the daemon performs lands here with a
  # timestamp, so a fast-charge drop can be correlated to the exact write that preceded it
  # ("what did ACC touch at 20:31:04?" answered from the phone, no reproduction needed).
  # Healthy charging writes nothing (rc14/rc19 idempotency), so this stays tiny; trimmed lazily.
  echo "$(date '+%m-%d %H:%M:%S' 2>/dev/null || date +%s) $*" >> $TMPDIR/.write-ledger 2>/dev/null || :
  if [ "$(wc -l < $TMPDIR/.write-ledger 2>/dev/null || echo 0)" -gt 400 ]; then
    tail -n 200 $TMPDIR/.write-ledger > $TMPDIR/.write-ledger.t 2>/dev/null \
      && mv -f $TMPDIR/.write-ledger.t $TMPDIR/.write-ledger 2>/dev/null || :
  fi
}


write() {

  # rc21: the blacklist is enforced HERE, at ACC's one write choke point, for the same reason
  # AMPS enforces it in wr(). Filtering switch CANDIDATES was not enough: the charging-current
  # machinery writes nodes (usb/current_max, pc_port/current_max, input_current_settled) through
  # a completely separate path, so a node blocked in the app was refused 12 times by AMPS and
  # then written anyway by the daemon -- proven from ACC's own write ledger on a Mi A3.
  # A node reaches this list only by taking a phone down, so nothing is worth writing it for.
  # The trade-off is deliberate: if you block the node ACC is holding the limit with, ACC stops
  # holding the limit and the breach monitor says so, rather than silently writing it anyway.
  # _BLRELEASE is the one exemption, and it exists because refusing every write can strand a
  # phone NOT CHARGING: block the node ACC is currently holding the limit with and it can no
  # longer write the value that RELEASES the cut either (measured: input_suspend stuck at 1 at
  # 71% with the limit at 75%). The daemon therefore releases the node once, then stops using
  # it. A release restores charging; it is the cut that carries the risk.
  if [ "${_BLRELEASE:-0}" != 1 ] && [ -n "${2-}" ] \
    && command -v sw_blacklisted >/dev/null 2>&1 && sw_blacklisted "$2"
  then
    ${isAccd:-false} && command -v _wlog >/dev/null 2>&1 && _wlog "blocked $2 (on the blocked list, not written)" || :
    return 1
  fi

  local i=y
  local seq=5
  local one="$(eval echo $1)"
  local f=$dataDir/logs/write.log
  local _cur _tgt _unverified
  blacklisted=false

  # 6.5.1-rc14 DEEP FIX (fast charge): IDEMPOTENT write. If the node already holds the target
  # value, do NOTHING -- no chmod, no echo, no 5x retry below. ACC re-asserts the switch EVERY
  # daemon loop while charging; re-writing the same value (and the chmod) re-triggers AICL / the
  # charge-pump FSM on fast-charge phones (PPS/PD/VOOC/QC-CP), which drops fast charge to the main
  # buck charger and never lets it re-engage -> the "only slow/normal after ACC, even charge-once
  # cannot fast-charge" reports. Reading ground truth first is STRICTLY safer than a blind write:
  # a node the firmware drifted OFF target (actual != target) is still written, so pause
  # enforcement and cut re-arm are unchanged -- only redundant same-value pokes are skipped. Never
  # skipped during a switch test/scan (exitCode_ set), which must write to measure. Write-only or
  # value-transforming nodes (read-back != written, e.g. HyperOS smart_chg) never match here, so
  # they behave exactly as before.
  if [ -z "${exitCode_-}" ] && [ -f "$2" ]; then
    _cur="$(cat "$2" 2>/dev/null)"
    _tgt="$one"; [[ "$one" != */* ]] || _tgt="$(cat "$one" 2>/dev/null)"
    if [ -n "$_cur" ] && [ "$_cur" = "$_tgt" ]; then
      rm $TMPDIR/.nowrite 2>/dev/null || :
      return 0
    fi
  fi
  # rc20-alpha: only reached when a REAL value change is about to be written (the idempotent
  # gate above returned for same-value pokes) -- exactly the writes worth ledgering.
  _wlog "write $2 <- $one (was ${_cur:-?})"

  # rc15 REGRESSION FIX (vs VR-25): use `chmod a+w` as the writability gate, NOT `[ -w ]`.
  # As root `[ -w "$2" ]` is ALWAYS true (CAP_DAC_OVERRIDE bypasses the mode bits), so the rc14
  # `[ -w "$2" ] || chmod` NEVER chmodded and went straight to the echo -- on a read-only sysfs
  # attribute (no store() method) the redirection open() then fails with EACCES and the shell
  # prints "acc: can't create <node>: Permission denied" for every such node in the mcc/mcv
  # sweep. VR-25's plain `chmod a+w` fails on exactly those nodes, so its `&&` short-circuits and
  # the echo is never attempted -> clean. Restored here; the rc14 idempotent read-before-write
  # above still runs first, so chmod only fires on a genuine value change (fast charge undisturbed).
  # `2>/dev/null` on both chmod and echo silences the residual case (chmod succeeds but the driver
  # still rejects the write, e.g. a value-clamping node) so no denial ever leaks to the user.
  if [ -f "$2" ] && chmod a+w $2 2>/dev/null; then
    case "$(grep -E "^(#$2|$2)$" $f 2>/dev/null || :)" in
      \#*) [ -z "${lastNode-}" ] && { blacklisted=true; i=x; } || { eval "echo $1 > $2" 2>/dev/null || { i=x; _unverified=1; }; };;
      */*) eval "echo $1 > $2" 2>/dev/null || { i=x; _unverified=1; };;
      *) echo $2 >> $f
         eval "echo $1 > $2" 2>/dev/null || { i=x; _unverified=1; };;
    esac
  else
    i=x
  fi

  [ $i = x ] || {
    f="$(cat $2)" 2>/dev/null || :
    rm $TMPDIR/.nowrite 2>/dev/null || :
    [[ "$one" != */* ]] || one="$(cat $one)"
    ! [[ -n "$f" && "$f" != "$one" ]] || {
      touch $TMPDIR/.nowrite
      i=x
      _unverified=1
    }
    if [ -n "${exitCode_-}" ]; then
      [ -n "${swValue-}" ] && swValue="$swValue, $f" || swValue="$f"
    fi
  }

  # rc24 (B8): the retry belongs to a write that was ATTEMPTED and did NOT verify -- a readback
  # mismatch, or the echo itself failing ($_unverified). It does not belong to every i=x: a chmod
  # failure (the node was never opened) and the blacklist marker (deliberately never echoed, see
  # the rc21 comment above) both set i=x without setting $_unverified and must fast-fail here
  # exactly as before rc24 -- retrying or echoing into either case defeats the write-blacklist
  # ACC's own ledger depends on, and turns a fast daemon-loop bail into five slow ones. Only the
  # unverified case gets the retry budget below; a value that already verified never reaches here.
  [ "${_unverified-}" = 1 ] && {
    for i in $(seq $seq); do
      eval "echo $1 > $2" 2>/dev/null || { [ $i -eq $seq ] && return ${3-1} || : ; }
      f="$(cat $2 2>/dev/null)" || :
      [ "$f" = "$one" ] && return 0
      usleep $((1000000 / $seq))
    done
    return ${3-1}
  }
  [ $i = x ] && return ${3-1}
  return 0
}


# environment

id=acc
domain=vr25
: ${isAccd:=false}
loopDelay=(3 9)
execDir=/data/adb/$domain/acc
export TMPDIR=/dev/.vr25/acc
mkdir -p $TMPDIR 2>/dev/null || :   # rc21 (tmpfs): front-end guard -- see acquire-lock.sh. $TMPDIR is tmpfs; if a boot never recreated it, a cold front-end (`acc`, AccA) would die at batt-interface.sh's `touch $TMPDIR/.batt-interface.sh`. Self-create so it degrades to a direct battery read instead of crashing.
dataDir=/data/adb/$domain/${id}-data
: ${config:=$dataDir/config.txt}
config_=$config

# rc21: parse-safe config load, shared by the daemon and the front-end. Sourcing a config with a
# SYNTAX error is fatal in mksh: the parse error aborts the shell and fires the exit trap BEFORE
# `2>/dev/null || :` can act, because a redirect and a guard only catch RUNTIME failures. Test
# that the file PARSES in a throwaway subshell first (exit trap cleared, so the subshell's own
# abort has no side effects and never runs exxit), and source it for real only once it is known
# well-formed. Returns 0 when the live shell now holds a parsed config, 1 when the file is
# unusable and the caller should fall back.
#
# accd has had this since rc21 as _srccfg, which also maintains the known-good copy. The
# front-end had nothing: `acc -i`, `acc -s` and `acc -D` all died on the very file a user would
# run acc to repair. Deliberately NOT folded into accd's _srccfg -- that one is on the per-loop
# hot path and is already tested; this is the same three lines without its bookkeeping.
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
  cfg_srcsafe() { . "$1" 2>/dev/null || :; }
  cfg_check_kv() { return 0; }
fi



# `pgrep -f accd.sh` IS NOT A DAEMON CHECK. release-lock.sh runs `pkill -f <execDir>/accd.sh` and
# service.sh runs `start-stop-daemon -bx <execDir>/accd.sh -S`; both carry that path in their own
# argv, so the pattern matches the machinery that tears the daemon DOWN and the launcher that has
# not brought it up yet. acc-switch-scan.sh measured the consequence: a scan reported "daemon
# restarted, charging is back under ACC control" and there was no daemon 45 seconds later.
#
# That file grew a correct test and kept it to itself, so `acc -t` and diag-collect.sh went on
# using the broken one -- acc -t could suppress its own "the daemon did not come back" warning, and
# diagnostics could call an unmanaged phone healthy. One definition, here, where both can reach it.
#
# The test is positive, not a blacklist: the daemon is a SHELL whose script argument is accd.sh,
# which no helper merely naming the path ever is. Excluding known helpers by name would just wait
# for the next helper.
_is_accd() {   # $1 = pid
  local _pid=${1:-} _c=
  case "$_pid" in ''|*[!0-9]*) return 1;; esac
  [ -r "/proc/$_pid/cmdline" ] || return 1
  _c=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
  [ -n "$_c" ] || return 1
  set -f; set -- $_c; set +f
  case "${1:-}" in sh|*/sh|mksh|*/mksh|bash|*/bash|busybox|*/busybox) ;; *) return 1;; esac
  [ "${1##*/}" = busybox ] && shift
  case "${2:-}" in */accd.sh|accd.sh) return 0;; esac
  return 1
}

daemon_alive() {
  local _p=
  for _p in $(pgrep -f "accd.sh" 2>/dev/null); do
    _is_accd "$_p" && return 0
  done
  return 1
}

srccfg_try() {
  _sctf=${1:-$config}
  [ -f "$_sctf" ] || return 1
  # Judge PARSEABILITY, not the config's exit status. The previous form was
  #   ( trap - EXIT; . "$_sctf" ) || return 1
  #   . "$_sctf" || return 1
  # which had two defects, both measured on a Mi A3 and a Pixel 6a:
  #  1. It returned 1 whenever the LAST command in the config exited non-zero. Config rules are
  #     ordinary shell (applyOnBoot / applyOnPlug routinely end in a failing test, and ACC's own
  #     `acc -e ... auto` appends ":; online || exec $TMPDIR/accd"), so a perfectly valid config
  #     was declared malformed. acc.sh's chain then fell through to .config-good and finally
  #     default-config.txt, silently replacing the user's pause/resume with different values.
  #     The A3's own live config was judged malformed by this.
  #  2. It sourced the file TWICE, so every side-effecting rule ran twice per invocation, and
  #     the validation subshell could itself run an `exec` rule.
  # sh -n is parse-only: it catches the real malformed case (a truncated "capacity=(") without
  # executing anything. The single source that follows is then allowed to have any exit status.
  # The interpreter MUST be an absolute path. acc.sh runs with a PATH that does not always
  # resolve a bare `sh` (ACC's own early-cap.log records "sh: sh: No such file or directory"),
  # and a bare `sh -n` that fails to EXEC is indistinguishable from a parse error, so every
  # config was declared malformed and every acc invocation printed
  #   "Warning: ... is malformed and no known-good copy exists; using defaults."
  # while the file parsed perfectly. Measured on both a Magisk and a KernelSU phone.
  # If no interpreter can be found at all, skip validation and source anyway: wrongly rejecting
  # a good config is worse than not catching a bad one, and the caller already tolerates a
  # failed source.
  # Degrade to "source it" if the parse test is unavailable, never to "reject it". This function's
  # own rule is that wrongly rejecting a good config is worse than not catching a bad one -- it
  # already says so about a missing interpreter -- and a hard call here inverted that: with
  # cfg_parses out of scope, srccfg_try returned 1 for EVERY config, including valid ones.
  if command -v cfg_parses >/dev/null 2>&1; then
    cfg_parses "$_sctf" || return 1
  else
    # cfg_parses out of scope: do the parse test inline rather than skip it. Skipping would accept
    # a TRUNCATED config, and a truncated config is precisely the fatal case -- a parse error in
    # mksh aborts the shell before any `||` can act. Same three-line test, same fail-open ending:
    # no usable interpreter means source it anyway.
    for _sctsh in /system/bin/sh /system/xbin/sh /bin/sh; do
      [ -x "$_sctsh" ] || continue
      "$_sctsh" -n "$_sctf" 2>/dev/null || return 1
      break
    done
  fi
  # mksh does NOT honour `|| :` for a failure INSIDE a dot-sourced file: under set -e a config
  # whose last command exits non-zero (applyOnBoot/applyOnPlug rules routinely end in a failing
  # test, and `acc -e ... auto` appends ":; online || exec $TMPDIR/accd") aborted the whole
  # front-end right here, so `acc -v` exited 1 having printed no version and no warning. Drop
  # errexit only across the source and restore it exactly as it was, so a caller that never
  # enabled it (acca.sh / set-prop.sh) is left unchanged.
  case $- in
    *e*) set +e; . "$_sctf" 2>/dev/null; set -e;;
    *) . "$_sctf" 2>/dev/null || :;;
  esac
  return 0
}

# rc21: is this node one that already took the phone down? Two lists feed it: AMPS's crash
# blacklist (survivor_check writes it after a scan that never returned) and ACC's own probe
# blacklist. Both record a node that panicked mid-write, so nothing may write one again without
# the owner clearing it via `acc -sb rm`. Accepts a bare node path; the AMPS list stores full
# paths and the probe list stores "dir/node on off" rows, so match on the leading field of both.
#
# The leading field is the whole point. AMPS 7.2.1 changed its list from a bare path per line to
# "path<TAB>value<TAB>when" so a crash record also says what was being written. The first version
# of this function matched with `grep -qxF`, i.e. WHOLE LINE, which cannot match a tab-suffixed
# row -- so every entry the shipping engine actually writes was invisible here, and the three
# call sites that depend on it (write(), filter_sw, the configured-switch release) all failed
# open and wrote the node that had already crashed the phone. Read the first field, not the line.
#
# No awk, no grep, no fork. Not for speed (though this runs on every write): awk is absent on
# some vendor ROMs and toybox only grew it recently, and setup-busybox.sh may now legitimately
# continue without busybox (BB_OPTIONAL). A blacklist that silently fails open on those phones
# is precisely the boot loop it exists to prevent, so it must not depend on an external binary.
# `while read` with a redirect (not a pipe) runs in this shell, so `return` inside it works.
sw_blacklisted() {
  [ -n "${1:-}" ] || return 1
  _swbn=${1##*/sys/class/power_supply/}
  _swfp=/sys/class/power_supply/$_swbn
  _swcr=$(printf '\r')
  if [ -s $dataDir/.acc-compat-blacklist ]; then
    while IFS="$(printf '\t')" read -r _swl _swrest || [ -n "$_swl" ]; do
      _swl=${_swl%"$_swcr"}
      case "$_swl" in ''|'#'*) continue;; esac
      [ "$_swl" = "$1" ] || [ "$_swl" = "$_swfp" ] || [ "$_swl" = "$_swbn" ] || continue
      return 0
    done < $dataDir/.acc-compat-blacklist
  fi
  if [ -s $dataDir/.probe-blacklist ]; then
    while IFS=' ' read -r _swl _swrest || [ -n "$_swl" ]; do
      _swl=${_swl%"$_swcr"}
      case "$_swl" in ''|'#'*) continue;; esac
      [ "$_swl" = "$_swbn" ] || [ "$_swl" = "$1" ] || [ "$_swl" = "$_swfp" ] || continue
      return 0
    done < $dataDir/.probe-blacklist
  fi
  return 1
}

[ -f $TMPDIR/.ghost-charging ] \
  && ghostCharging=true \
  || ghostCharging=false

trap exxit EXIT
. $execDir/setup-busybox.sh
. $execDir/set-ch-curr.sh
. $execDir/set-ch-volt.sh
. $execDir/state-export.sh
. $execDir/probe-journal.sh

# wait for accd initialization
if ! ${isAccd:-false} && [ ! -f $TMPDIR/.batt-interface.sh ]; then
  printf "⏳ accd --init\n\n"
  for i in $(seq 35); do
    [ -f $TMPDIR/.batt-interface.sh ] && break || sleep 2
  done
  unset i
fi

device=$(getprop ro.product.device | grep .. || getprop ro.build.product)
cd /sys/class/power_supply/
. $execDir/batt-interface.sh
. $execDir/android.sh

# load plugins
mkdir -p ${execDir}-data/plugins $TMPDIR/plugins
for f in ${execDir}-data/plugins/*.sh $TMPDIR/plugins/*.sh; do
  if [ -f "$f" ] && [ ${f##*/} != ctrl-files.sh ]; then
    . "$f"
  fi
done
unset f
