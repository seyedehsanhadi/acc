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

  for entry in ${applyOnBoot[@]-} ${maxChargingVoltage[@]-}; do
    set -- ${entry//::/ }
    [ -f ${1-//} ] || continue
    file=${1-}
    value=${2-}
    if $exitCmd && ! $force; then
      default=${2-}
    else
      default=${3:-${2-}}
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
  local _rk= _rv= _rc= _lv=

  for entry in ${applyOnPlug[@]-} ${maxChargingVoltage[@]-} \
    ${maxChargingCurrent[@]:-$([ .$arg != .default ] || cat $TMPDIR/ch-curr-ctrl-files 2>/dev/null || :)}
  do
    set -- ${entry//::/ }
    [ -f ${1-//} ] || continue
    file=${1-}
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
        */current_max|*/input_current|*/input_current_limit|*/input_current_settled)
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
          _lv=; { read -r _lv < "$file"; } 2>/dev/null || _lv=
          case "${_lv:-x}" in
            ''|*[!0-9]*) : ;;
            *) [ "$_lv" -le 100000 ] 2>/dev/null || continue;;
          esac
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
    [ -f ${1-//} ] || continue
    file=${1-}
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


cycle_switches() {

  local on=
  local off=
  local strict=${3:-false}
  local _cc= _cbase= _thr= _mag= _bs= _cs= _rej= _chg_n= _chg_last= _this= _s=

  touch $TMPDIR/.testingsw

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
              # resumed on its own -> flicker; keep charging OFF (never pulse it
              # back on while we are trying to pause at/above the limit), then
              # reject the switch and move it to the end like a failure
              flip_sw off 2>/dev/null || :
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
          _suppress_on=false
          case "${capacity[3]-}" in
            ''|*[!0-9]*) : ;;
            *)
              if [ "${capacity[3]}" -gt 3000 ] 2>/dev/null && [ "${capacity[3]}" -le 5000 ] 2>/dev/null; then
                _vn=$(volt_now 2>/dev/null)
                case "${_vn:-x}" in ''|x|*[!0-9-]*) : ;; *) [ "$_vn" -ge "${capacity[3]}" ] 2>/dev/null && _suppress_on=true ;; esac
                unset _vn
              elif [ "${capacity[3]}" -le 100 ] 2>/dev/null; then
                _bc=$(batt_cap 2>/dev/null)
                case "${_bc:-x}" in ''|x|*[!0-9-]*) : ;; *) [ "$_bc" -ge "${capacity[3]}" ] 2>/dev/null && _suppress_on=true ;; esac
                unset _bc
              fi
              ;;
          esac
          $_suppress_on || flip_sw on 2>/dev/null || :
          unset _suppress_on
          if ! ${acc_t:-false}; then
            sed -i "\|^${chargingSwitch[*]}$|d" $TMPDIR/ch-switches
            echo "${chargingSwitch[*]}" >> $TMPDIR/ch-switches
          fi
        fi
      fi
    }
  done < $TMPDIR/ch-switches

  rm $TMPDIR/.testingsw
}


cycle_switches_off() {
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
  local _now= _then= _min=${_rekickMinInterval:-30}
  _now=$(date +%s 2>/dev/null) || return 0
  case ${_now:-x} in ''|*[!0-9]*) return 0;; esac
  _then=$(cat "$TMPDIR/.rekick" 2>/dev/null || echo 0)
  case ${_then:-x} in ''|*[!0-9]*) _then=0;; esac
  [ $(( _now - _then )) -ge "$_min" ] || return 1
  echo "$_now" > "$TMPDIR/.rekick" 2>/dev/null || :
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
  for _rn in */apsd_rerun */rerun_aicl; do
    [ -w "$_rn" ] || continue
    command -v _wlog >/dev/null 2>&1 && _wlog "rekick $_rn <- 1 ($_reason)" || :
    echo 1 > "$_rn" 2>/dev/null || :
  done
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
      if present; then   # rc7 (U5): gate resume on PRESENT (cable attached), not online+name-allowlist. Many input-cut switches (charging_enabled/charge_disable/slate_mode/force_*_suspend/mmi/night_charging...) drive */online to 0 while latched, and were NOT in the allowlist -> never re-armed -> stuck not-charging till reboot. present stays 1 whenever plugged, covers EVERY cut class, and still skips the flip when truly unplugged (no phantom-charging blip).
        flip_sw on 2>/dev/null || :
      fi
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
      # flip ON regardless:
      # writing the resume value (input_suspend=0) is harmless when truly unplugged (no VBUS =
      # no current = no phantom "Charging") and un-masks online when actually plugged. The
      # pause path still enforces the limit, so this can never overcharge. All OTHER switch
      # types keep the online gate (avoids the cosmetic unplug blip).
      if present; then   # rc7 (U5): gate resume on PRESENT (cable attached), not online+name-allowlist. Many input-cut switches (charging_enabled/charge_disable/slate_mode/force_*_suspend/mmi/night_charging...) drive */online to 0 while latched, and were NOT in the allowlist -> never re-armed -> stuck not-charging till reboot. present stays 1 whenever plugged, covers EVERY cut class, and still skips the flip when truly unplugged (no phantom-charging blip).
        flip_sw on || cycle_switches on
        # D8 (rc5: extended to current-cap classes): after un-cutting, re-run APSD/AICL so the
        # charger re-negotiates. Input-cut switches (input_suspend/bypass/vbus) mask */online to 0
        # -> fire when present && !online. CURRENT-CAP switches (constant_charge_current[_max],
        # */current_max, */input_current) keep */online=1 but the CHARGE CURRENT can stay 0 after
        # the cap is restored -> fire while the cable is present and charging has NOT actually
        # resumed (not_charging), regardless of online. Harmless when already charging (no-op
        # re-detect); self-limits once current flows. (rc4 D8 missed both: the *constant_charge_
        # current* (no _max) name, and the !online gate that a current-cap never satisfies.)
        case "${chargingSwitch[*]-}" in
          *current_max*|*input_current*|*constant_charge_current*)
            if present && not_charging && _rekick_due; then
              for _rn in */apsd_rerun */rerun_aicl; do
                [ -w "$_rn" ] && { _wlog "rekick $_rn <- 1" 2>/dev/null; echo 1 > "$_rn" 2>/dev/null; } || :
              done
            fi ;;
          *suspend*|*bypass*|*vbus*)
            if present && ! online && _rekick_due; then
              for _rn in */apsd_rerun */rerun_aicl; do
                [ -w "$_rn" ] && { _wlog "rekick $_rn <- 1" 2>/dev/null; echo 1 > "$_rn" 2>/dev/null; } || :
              done
            fi ;;
        esac
      fi

    else
      wait_plug
      return 0
    fi

    chDisabledByAcc=false

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
  local _cur _tgt
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
      \#*) [ -z "${lastNode-}" ] && { blacklisted=true; i=x; } || { eval "echo $1 > $2" 2>/dev/null || i=x; };;
      */*) eval "echo $1 > $2" 2>/dev/null || i=x;;
      *) echo $2 >> $f
         eval "echo $1 > $2" 2>/dev/null || i=x;;
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
    }
    if [ -n "${exitCode_-}" ]; then
      [ -n "${swValue-}" ] && swValue="$swValue, $f" || swValue="$f"
    fi
  }

  [ $i = x ] && return ${3-1} || {
    for i in $(seq $seq); do
      if eval "echo $1 > $2" 2>/dev/null; then
        [ $i -eq $seq ] || usleep $((1000000 / $seq))
      else
        return 1
      fi
    done
  }
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
  for _sctsh in /system/bin/sh /system/xbin/sh /bin/sh; do
    [ -x "$_sctsh" ] || continue
    "$_sctsh" -n "$_sctf" 2>/dev/null || return 1
    break
  done
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
