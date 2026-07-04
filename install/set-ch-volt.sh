set_ch_volt() {

  local f=$TMPDIR/.volt-custom
  local isAccd=${isAccd:-false}

  # Same reboot hole as set-ch-curr: the tmpfs marker alone must not gate a restore, or clearing
  # the voltage limit after a reboot silently keeps the old value in the config and on the nodes.
  [[ ! -f $f && .${1-} = .- ]] && [ -z "${maxChargingVoltage[0]-}" ] \
    && ! grep -q / $TMPDIR/ch-volt-ctrl-files 2>/dev/null && return 0 || :

  if [ -n "${1-}" ]; then

    set -- $*

    apply_on_boot_() {
      (applyOnBoot=()
      apply_on_boot ${*-})
    }

    # A clear (-) must succeed even when the control files were never resolved this boot (phone
    # not charged since reboot): drop the config value unconditionally and restore the stored node
    # defaults only when they are known. Mirrors set-ch-curr's not-charging clear so a disabled
    # voltage limit can never linger on the config (resurrected by the editor on reload) or on the
    # nodes until the next reboot.
    if [ $1 = - ]; then
      grep -q / $TMPDIR/ch-volt-ctrl-files 2>/dev/null && apply_on_boot_ default force || :
      max_charging_voltage=
      maxChargingVoltage=()
      unset mcv
      $isAccd || print_volt_restored
      rm $f 2>/dev/null || :
      return 0
    fi

    # A numeric SET needs the resolved control files to know which nodes to write.
    grep -q / $TMPDIR/ch-volt-ctrl-files 2>/dev/null || {
      $isAccd || print_no_ctrl_file v
      return 0
    }

    apply_voltage() {
      eval "maxChargingVoltage=($1 $(sed "s|::v|::$1|" $TMPDIR/ch-volt-ctrl-files) ${2-})" \
        && unset max_charging_voltage mcv \
        && apply_on_boot_ \
        && {
          $isAccd || print_volt_set $1
        } || return 1
    }

    # = [3700-4300] millivolts
    if [ $1 -ge 3700 -a $1 -le 4300 ]; then
      apply_voltage $1 ${2-} || return 1

    # < 3700 millivolts
    elif [ $1 -lt 3700 ]; then
      $isAccd || echo "[3700-4300]$(print_mV; print_only)"
      apply_voltage 3700 ${2-} || return 1

    # > 4300 millivolts
    elif [ $1 -gt 4300 ]; then
      $isAccd || echo "[3700-4300]$(print_mV; print_only)"
      apply_voltage 4300 ${2-} || return 1
    fi
    touch $f

  else
    # print current value
    $isAccd && echo ${maxChargingVoltage[0]-} \
      || echo "${maxChargingVoltage[0]:-$(print_default)}$(print_mV)"
    return 0
  fi
}
