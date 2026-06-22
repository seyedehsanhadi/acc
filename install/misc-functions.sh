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

  for entry in ${applyOnPlug[@]-} ${maxChargingVoltage[@]-} \
    ${maxChargingCurrent[@]:-$([ .$arg != .default ] || cat $TMPDIR/ch-curr-ctrl-files 2>/dev/null || :)}
  do
    set -- ${entry//::/ }
    [ -f ${1-//} ] || continue
    file=${1-}
    value=${2-}
    default=${3:-${2-}}
    set +e
    write \$$arg $file 0 &
    set -e
  done

  wait
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
    echo "$@" | sed 's/,/\;/g; s|^acc|/dev/acc|g; s| acc| /dev/acc|g' > $file
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
          # set working charging switch(es). When strict-verified (current actually dropped),
          # LOCK it with a trailing "--" so the daemon STOPS re-probing switches every _STI
          # loops -- that periodic re-probe was toggling charging back on (the "stopped at the
          # limit, then resumed/reset" sawtooth). A --locked switch that later stops working is
          # still recovered (fix8), so locking is safe.
          $strict && s="${chargingSwitch[*]} --" || s="${chargingSwitch[*]}"
          . $execDir/write-config.sh
          break
        else
          # reset switch/group that fails to comply, and move it to the end of the list
          flip_sw on 2>/dev/null || :
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


disable_charging() {

  local autoMode=true

    [[ "${chargingSwitch[*]-}" != *\ -- ]] || autoMode=false

    if [[ "${chargingSwitch[0]-}" = */* ]]; then
      if [ -f ${chargingSwitch[0]} ]; then
        if ! { flip_sw off && not_charging; }; then
          $isAccd || print_switch_fails "${chargingSwitch[@]-}"
          flip_sw on 2>/dev/null || :
          # fix7 hardening: recover even from a --locked switch that has stopped
          # working. "--" suppresses routine auto-cycling (no churn while it works),
          # but a switch that fails to stop charging AT ALL must still trigger the
          # fallback -- safety outranks the lock. Alert once so a stale lock is seen.
          $autoMode || notif "⚠️ Locked charging switch failed to stop charging; auto-selecting another"
          unset_switch
          cycle_switches_off
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
        log_on
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
        log_on
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


enable_charging() {

    # Same unplug-blip guard as below: restore the saved switch config, but only
    # physically flip it ON when actually plugged in (online); otherwise just clear the
    # saved state so the next plug-in restores cleanly without a phantom "Charging" flash.
    # rc5 (#4/#18): restore the idle-avoidance switch. Source in the CURRENT shell so the parent
    # chargingSwitch is actually updated (the old subshell discarded it), and re-arm input-cut /
    # current-cap switches even while online=0 (same name exception as the resume gate below).
    if [ -f $TMPDIR/.sw ]; then
      . $TMPDIR/.sw 2>/dev/null || :; rm -f $TMPDIR/.sw 2>/dev/null || :
      if online || { case "${chargingSwitch[*]-}" in *suspend*|*bypass*|*vbus*|*current_max*|*input_current*|*constant_charge_current*) true;; *) false;; esac; }; then
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
      if online || { case "${chargingSwitch[*]-}" in *suspend*|*bypass*|*vbus*|*current_max*|*input_current*|*constant_charge_current*) true;; *) false;; esac; }; then
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
            if present && not_charging; then
              for _rn in */apsd_rerun */rerun_aicl; do
                [ -w "$_rn" ] && echo 1 > "$_rn" 2>/dev/null || :
              done
            fi ;;
          *suspend*|*bypass*|*vbus*)
            if present && ! online; then
              for _rn in */apsd_rerun */rerun_aicl; do
                [ -w "$_rn" ] && echo 1 > "$_rn" 2>/dev/null || :
              done
            fi ;;
        esac
      fi

      # detect and block ghost charging
      # if ! $ghostCharging && ! not_charging && ! online \
      #   && sleep ${loopDelay[0]} && ! not_charging && ! online
      # then
      #   ghostCharging=true
      #   disable_charging > /dev/null
      #   touch $TMPDIR/.ghost-charging
      #   wait_plug
      #   return 0
      # fi

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
        log_on
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
        log_on
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
eq() {
  eval "case \"$1\" in
    $2) return 0;;
  esac"
  return 1
}


flip_sw() {

  flip=$1
  local on=
  local off=

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
    if [ $3 = 3600mV ]; then
      off=$(cat $1)
      [ $off -lt 10000 ] && off=3600 || off=3600000
    elif [ $3 = pcap ]; then
      case ${capacity[3]-} in ''|*[!0-9]*) off=60;; *) off=${capacity[3]};; esac
    else
      off="$(parse_value "$3")"
    fi

    [ $flip = on ] || cat $currFile > $curThen
    write \$$flip $1 || return 1

    [ $# -lt 3 ] || shift 3
    [ $# -ge 3 ] || break

  done
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


misc_stuff() {
  set -eu
  mkdir -p $dataDir 2>/dev/null || :
  [ -f $config ] || cat $execDir/default-config.txt > $config

  # custom config path
  ! eq "${1-}" "*/*" || {
    [ -f $1 ] || cp $config $1
    config=$1
  }
  unset -f misc_stuff
}


notif() {
  su -lp 2000 -c "/system/bin/cmd notification post -S bigtext -t \"🔋ACC | $(date +%H:%M)\" "Tag$(date +%s)" \"${*:-:)}\"" < /dev/null > /dev/null 2>&1 || :
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
  _DPOL=$1
  echo _DPOL=$1 >> $TMPDIR/.batt-interface.sh
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
  log_on
  enable_charging "$@"
}


write() {

  local i=y
  local seq=5
  local one="$(eval echo $1)"
  local f=$dataDir/logs/write.log
  blacklisted=false

  if [ -f "$2" ] && chmod a+w $2; then
    case "$(grep -E "^(#$2|$2)$" $f 2>/dev/null || :)" in
      \#*) [ -z "${lastNode-}" ] && { blacklisted=true; i=x; } || { eval "echo $1 > $2" || i=x; };;
      */*) eval "echo $1 > $2" || i=x;;
      *) echo $2 >> $f
         eval "echo $1 > $2" || i=x;;
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
      if eval "echo $1 > $2"; then
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
dataDir=/data/adb/$domain/${id}-data
: ${config:=$dataDir/config.txt}
config_=$config

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
