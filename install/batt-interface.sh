idle_discharging() {
  if [ ${curNow#-} -le $idleThreshold ]; then
    _status=Idle
    return 0
  fi
  case "${_DPOL-}" in
    +) [ $curNow -ge 0 ] && _status=Discharging || _status=Charging;;
    -) [ $curNow -lt 0 ] && _status=Discharging || _status=Charging;;
    *) [ "${curThen:-null}" = null ] || {
          eq "$curThen,$curNow" "-*,[0-9]*|[0-9]*,-*" && _status=Discharging || _status=Charging
       };;
  esac
  # rc13: COULOMB ARBITRATION. The sign verdict above assumes ONE polarity per device, but on
  # dual-path PMICs the current sign FLIPS with the charge mode (curtana / Redmi Note 9S: the
  # master-only 5V trickle path reads POSITIVE while charging, the parallel 9V fast path reads
  # NEGATIVE while charging - field-verified in back-to-back forensics runs). Whatever single
  # _DPOL is latched is then wrong in the other mode: the daemon believed Discharging while the
  # pack was filling, the resume watchdog churned good switches, and acca -i showed "Draining"
  # with the cable in. The fuel gauge's charge_counter (uAh) is sign-convention-free ground
  # truth: if it ROSE beyond noise across the sample window the pack IS charging, if it FELL the
  # pack IS discharging, no matter what the signed current claims. Only a fresh (3-90s) window
  # arbitrates; a flat counter (idle hold, or too slow to tell) leaves the sign verdict alone,
  # so bypass/idle behavior is unchanged. When the counter contradicts the sign twice, the
  # polarity is provably mode-dependent -> drop a marker so set_dp stops re-latch churn.
  local _cc=$(cc_now) _ccp= _ccts= _ccnow=$(date +%s 2>/dev/null) _ccd= _sv=$_status
  if [ "${_cc:-0}" -gt 0 ] 2>/dev/null && [ -n "$_ccnow" ]; then
    [ ! -f $TMPDIR/.cc_then ] || read -r _ccp _ccts < $TMPDIR/.cc_then 2>/dev/null || :
    if [ "${_ccp:-0}" -gt 0 ] 2>/dev/null && [ $(( _ccnow - ${_ccts:-0} )) -ge 3 ] 2>/dev/null \
      && [ $(( _ccnow - ${_ccts:-0} )) -le 90 ] 2>/dev/null; then
      _ccd=$(( _cc - _ccp ))
      if [ $_ccd -ge 150 ]; then _status=Charging
      elif [ $_ccd -le -150 ]; then _status=Discharging; fi
      [ "$_sv" = "$_status" ] || {
        local _fl=$(cat $TMPDIR/.dpol_flips 2>/dev/null || echo 0)
        case "$_fl" in ''|*[!0-9]*) _fl=0;; esac
        _fl=$((_fl + 1)); echo $_fl > $TMPDIR/.dpol_flips 2>/dev/null || :
        [ $_fl -lt 2 ] || touch $TMPDIR/.dpol_unstable 2>/dev/null || :
      }
    fi
    echo "$_cc $_ccnow" > $TMPDIR/.cc_then 2>/dev/null || :
  fi
}


not_charging() {

  local i=
  local j=
  local sw=
  local _STI=${_STI:-35} # switch test iterations
  local switch=${flip-}; flip=
  local curThen=$(cat $curThen)
  local chargingSwitch="${chargingSwitch[*]-}"
  local idleThreshold=${idleThreshold:-10}
  local battStatusOverride="${battStatusOverride-}"
  local battStatusWorkaround=${battStatusWorkaround-}
  local wsLog=$dataDir/logs/working-switches.log

  [[ "$chargingSwitch" = *\ -- ]] && chargingSwitch="${chargingSwitch% --}" || battStatusOverride=

  case "$currFile" in
    */current_now|*/?attery?verage?urrent) [ ${ampFactor:-$ampFactor_} -eq 1000 ] || idleThreshold=${idleThreshold}000;;
    *) battStatusWorkaround=false;;
  esac

  if [ -z "${battStatusOverride-}" ] && [ -n "$switch" ]; then
    for i in $(seq $_STI); do
      if [ "$switch" = off ]; then
        ! status ${1-} || {
          sw=$(grep "\[[id]\] $chargingSwitch" $wsLog 2>/dev/null || :)
          while :; do
            j=$(echo $_status | sed -E 's/^(.).*/\1/; s/I/i/; s/D/d/')
            if [ -n "$sw" ]; then
              [[ "$sw" = \[$j\]* ]] || { sed -i "\|$chargingSwitch|d" $wsLog; sw=; continue; }
            else
              printf "[$j] $chargingSwitch" >> $wsLog
              case "$chargingSwitch" in
                *current*) [[ "$chargingSwitch" = *current_cmd* ]] || echo " {mcc}";;
                *control_limit_max*|*siop_level*|*temp_level*) echo " {tl}";;
                *voltage*) echo " {mcv}";;
                *) echo;;
              esac >> $wsLog
            fi
            break
          done
          return 0
        }
      else
        status ${1-} || return 1
      fi
      [ ! -f $TMPDIR/.nowrite ] || { rm $TMPDIR/.nowrite 2>/dev/null || :; break; }
      [ $i = $_STI ] || sleep 1
    done
    [ "$switch" = on ] || return 1
  else
    status ${1-}
  fi
}


online() {
  local i= seen=false
  for i in $(online_f); do
    seen=true
    grep -q 0 $i || return 0
  done
  # rc5 (#6): if NO */online node matched the regex (a device with an unlisted charger-node
  # name), do NOT blindly report offline -- that silently breaks generic_rearm/native_unlatch,
  # the resume flip-ON gate, and enters idle-nap while plugged. Defer to the charge status.
  $seen && return 1 || [ "$(read_status)" = Charging ]
}


online_f() {
  ls -1 */online | grep -Ei '^ac/|^dc/|^mains/|^main-?charger/|^mtk\-.*(chg|charger)/|^pc_port/|^smb[0-9]{3}\-usb/|^usb/|ucsi.*pmic|oplus.*chg|.*glink.*charg|^wireless/' || :
}


# rc(6.4): "is the cable physically attached" -- distinct from online() ("is the
# charge path energized"). An input-cut switch (input_suspend / current_max 0)
# drives */online to 0 WHILE the cable is still plugged, which blinded the breach
# watchdog (it read online=0 -> "unplugged" -> cleared the breach). POWER_SUPPLY_PRESENT
# stays 1 across an input cut. Falls back to online() on kernels with no present node.
present_f() {
  ls -1 */present 2>/dev/null | grep -Ei '^ac/|^dc/|^mains/|^main-?charger/|^mtk\-.*(chg|charger)/|^pc_port/|^smb[0-9]{3}\-usb/|^usb/|ucsi.*pmic|oplus.*chg|.*glink.*charg|^wireless/' || :
}

present() {
  local i= seen=false
  for i in $(present_f); do
    seen=true
    case "$(cat $i 2>/dev/null)" in 1) return 0;; esac
  done
  # no usable present node -> defer to online (a path that is energized is plugged)
  $seen && return 1 || online
}


read_status() {
  local status="$(cat $battStatus)"
  case "$status" in
    Cmd*discharging) printf Discharging;;
    Charging|Discharging) printf %s $status;;
    Not?charging) printf Idle;;
    *) printf Discharging;;
  esac
}


set_temp_level() {
  local f=$TMPDIR/.tl-custom
  local a=
  local b=battery/siop_level
  local l=${1:-${tempLevel-}}
  local _t=
  [ -n "$l" ] || return 0
  [[ $l -eq 0 && ! -f $f ]] && return 0 || :
  # IDEMPOTENT (fast charge): write a level/limit node ONLY when its value must change. These are
  # raw writes (not via write()), and charge_control_limit_max / siop_level re-trigger AICL / the
  # charge FSM on every write, so re-asserting the same value each loop while warm throttles fast
  # charge continuously. Read-before-write leaves a healthy charge undisturbed and still re-arms
  # the instant the firmware drifts the node off target.
  if [ -f $b ]; then
    _t=$((100 - $l)); [ "$(cat $b 2>/dev/null)" = "$_t" ] || { chmod a+w $b && echo $_t > $b; } || :
  else
    for a in */num_system_temp*levels; do
      b=$(echo $a | sed 's/\/num_/\//; s/s$//')
      if [ ! -f $a ] || [ ! -f $b ]; then
        continue
      fi
      _t=$(( ($(cat $a) * l) / 100 )); [ "$(cat $b 2>/dev/null)" = "$_t" ] || { chmod a+w $b && echo $_t > $b; } || :
    done
  fi
  for a in */charge_control_limit_max; do
    b=${a%_max}
    if [ ! -f $a ] || [ ! -f $b ]; then
      continue
    fi
    _t=$(( ($(cat $a) * l) / 100 )); [ "$(cat $b 2>/dev/null)" = "$_t" ] || { chmod a+w $b && echo $_t > $b; } || :
  done
  [ $l -ne 0 ] && touch $f || rm $f 2>/dev/null || :
}


status() {

  local i=0
  local return1=false
  local csw2=${chargingSwitch[2]-}
  local curNow=$(cat $currFile)
  # N1 (coerce): a transient empty/garbage current_now read (common on some fuel gauges during a
  # mode switch) would make idle_discharging's "[ ${curNow#-} -le N ]" and the calc below a 2-arg
  # test / arithmetic error, aborting this hot loop under set -eu (charging limit lost). Same
  # hardening the sibling volt_now/batt_cap/temp_now reads already carry; curNow was the gap.
  case ${curNow#-} in ''|*[!0-9]*) curNow=0;; esac

  _status=$(read_status)

  if [ -n "${battStatusOverride-}" ]; then
    [[ .${chargingSwitch[2]-} != */* ]] || csw2="$(cat ${chargingSwitch[2]})"
    if  eq "$battStatusOverride" "Discharging|Idle"; then
      [ "$(cat ${chargingSwitch[0]})" != "$csw2" ] || _status=$battStatusOverride
    else
      _status=$(set -eu; eval '$battStatusOverride') || :
    fi
  elif $battStatusWorkaround; then
    idle_discharging
  fi

  [ -z "${exitCode_-}" ] || echo -e "  ${switch:--} (${swValue:-N/A})\t$(calc $curNow \* 1000 / ${ampFactor:-$ampFactor_} | xargs printf %.f)mA\t$_status"

  for i in Discharging DischargingDischarging Idle IdleIdle; do
    [ $i != ${1-}$_status ] || return 0
  done

  return 1
}


volt_now() {
  # N1: a transiently-empty/garbage voltage_now read used to emit nothing -> "[ -ge NN ]" syntax
  # error -> daemon abort under set -eu (charging limit lost). Coerce an unreadable node to a
  # fail-safe HIGH value (forces a pause, never a false shutdown) so the loop survives.
  local v=$(grep -o '^....' $voltNow 2>/dev/null)
  case $v in ''|*[!0-9]*) v=9999;; esac
  echo $v
}


if ${_INIT:-false}; then


  # Nexus 10 (manta)
  f1=smb???-battery/status
  f2=ds????-fuelgauge/capacity


  if ls $f1 $f2 >/dev/null 2>&1; then
    batt=${f2%/*}
  else
    for batt in maxfg/capacity */capacity; do
      if [ -f ${batt%/*}/status ]; then
        batt=${batt%/*}
        break
      fi
    done
  fi

  [[ $batt != */capacity ]] || exit 1


  for battStatus in sm????_bms/status $batt/status $f1; do
    [ ! -f $battStatus ] || break
  done

  [ -f $battStatus ] || exit 1
  unset f1 f2


  echo 250 > $TMPDIR/.dummy-temp

  for temp in $batt/temp $batt/batt_temp bms/temp ${battStatus%/*}/temp $TMPDIR/.dummy-temp; do
    [ ! -f $temp ] || break
  done


  echo 0 > $TMPDIR/.dummy-mcc

  for currFile in rt*-charger/current_now battery/current_now $batt/current_now bms/current_now battery/?attery?verage?urrent \
    /sys/devices/platform/battery/power_supply/battery/?attery?verage?urrent \
    ${battStatus%/*}/current_now $TMPDIR/.dummy-mcc
  do
    [ ! -f $currFile ] || break
  done


  voltNow=$batt/voltage_now
  [ -f $voltNow ] || voltNow=$batt/batt_vol
  [ -f $voltNow ] || {
    echo 3900 > $TMPDIR/.voltage_now
    voltNow=$TMPDIR/.voltage_now
  }


  ampFactor=$(sed -n 's/^ampFactor=//p' $dataDir/config.txt 2>/dev/null || :)
  ampFactor_=${ampFactor:-1000}

  # uA-vs-mA: a current >= 16000 (raw) means a microamp sensor (no cell charges at 16+ amps).
  # This is read from whatever the live current is now; amp_recheck (accd) re-latches it the
  # moment a CHARGING current appears and PERSISTS it, so an init while idling at the cap can
  # self-heal. A true milliamp device (e.g. OnePlus 8 Pro: mA current_now but uV/uAh voltage and
  # charge -- a MIXED-unit phone) stays under 16000 even when charging, so it stays mA. (An
  # earlier charge_full_design/voltage anchor mis-detected those mixed-unit phones and is removed:
  # only the current_now magnitude reflects the current_now unit.)
  if [ $ampFactor_ -eq 1000000 ] || [ $(sed s/-// $currFile) -ge 16000 ]; then
    ampFactor_=1000000
  fi

  curThen=$TMPDIR/.mcc
  rm $curThen 2>/dev/null || :


  echo "ampFactor_=$ampFactor_
batt=$batt
battCapacity=$batt/capacity
battStatus=$battStatus
currFile=$currFile
curThen=$curThen
idleThreshold=${idleThreshold:-10}
_STI=\${_STI:-35}
temp=$temp
voltNow=$voltNow" > $TMPDIR/.batt-interface.sh

  _INIT=false


else
  touch $TMPDIR/.batt-interface.sh
  . $TMPDIR/.batt-interface.sh
fi

[ -f $curThen ] || echo null > $curThen

batt_cap() {
  local l=$(dsys_batt get level)
  local l2=$(cat $battCapacity)
  local r=
  # N1: never emit empty/garbage -- a blank capacity makes "[ -ge NN ]" a syntax error and aborts
  # the loop under set -eu (limit lost). capacity_mask(=[4]) -> kernel level; else prefer Android's
  # level, fall back to kernel; coerce an unreadable result to 100 (fail-safe pause, never overcharge).
  ${capacity[4]:-false} && r=$l2 || { [ -n "$l" ] && r=$l || r=$l2; }
  case $r in ''|*[!0-9]*) r=100;; esac
  echo $r
}


cc_now() {
  # charge_counter (uAh remaining) -- a POLARITY-INDEPENDENT "is the cell actually gaining charge?" signal.
  # The resume watchdog uses it to tell a real stall apart from a status node that lies under a bypass/idle
  # switch (OnePlus/OPLUS) or a mis-latched polarity. 0 = node absent or non-numeric (signed coulomb-counter
  # devices) -> callers fall back to the status-only path, so this never regresses a phone without it.
  local _c=$(cat ${battCapacity%capacity}charge_counter 2>/dev/null)
  case "$_c" in ''|*[!0-9]*) echo 0;; *) echo "$_c";; esac
}
