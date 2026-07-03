set_ch_curr() {

  local f=$TMPDIR/.mcc-custom
  local isAccd=${isAccd:-false}

  [[ ! -f $f && .${1-} = .- ]] && return 0 || :

  [[ .${1-} != .*% ]] || {
    set_temp_level ${1%\%}
    return
  }

  # check support
  # The support probe needs live charging current to identify the control files, and it used
  # to WAIT for charging here (sleep loop). With the daemon holding the battery at the pause
  # limit the phone spends its life Not-charging, so a set from AccA blocked forever inside
  # the app's root shell and the value was never written to config ("the limit won't stick",
  # 4a 5G field report). A numeric set now persists the intent immediately and returns; accd
  # re-runs set_ch_curr from the config at the next charging tick, when the probe can succeed,
  # and completes the node resolution on its own.
  [ -f $TMPDIR/.mcc-read ] || {
    if not_charging; then
      case "${1-}" in
        '')
          $isAccd && echo ${maxChargingCurrent[0]-} \
            || echo "${maxChargingCurrent[0]:-$(print_default)}$(print_mA)"
          return 0
        ;;
        -)
          maxChargingCurrent=()
          max_charging_current=
          unset mcc
          rm $f 2>/dev/null || :
          $isAccd || print_curr_restored
          return 0
        ;;
        *)
          if [ "$1" -ge 0 ] 2>/dev/null && [ "$1" -le 9999 ] 2>/dev/null; then
            maxChargingCurrent=($1)
            unset max_charging_current mcc
            touch $f
            $isAccd || print_curr_set $1
            return 0
          fi
          $isAccd || echo "[0-9999]$(print_mA; print_only)"
          return 11
        ;;
      esac
    fi
    . $execDir/read-ch-curr-ctrl-files-p2.sh
  }
  grep -q / $TMPDIR/ch-curr-ctrl-files 2>/dev/null || {
    $isAccd || print_no_ctrl_file
    return 0
  }

  if [ -n "${1-}" ]; then

    apply_on_plug_() {
      (applyOnPlug=()
      maxChargingVoltage=()
      apply_on_plug ${1-})
    }

    # restore
    if [ $1 = - ]; then
      apply_on_plug_ default
      max_charging_current=
      $isAccd || print_curr_restored
      rm $f 2>/dev/null || :

    else

      apply_current() {
        eval "
          if [ $1 -ne 0 ]; then
            maxChargingCurrent=($1 $(sed "s|::v|::$1|" $TMPDIR/ch-curr-ctrl-files))
          else
            maxChargingCurrent=($1 $(sed "s|::v.*::|::$1::|" $TMPDIR/ch-curr-ctrl-files))
          fi
        " \
          && unset max_charging_current mcc \
          && apply_on_plug_ \
          && {
            $isAccd || print_curr_set $1
          } || return 1
      }

      # [0-9999] milliamps range
      if [ $1 -ge 0 -a $1 -le 9999 ]; then
        apply_current $1 || return 1
      else
        $isAccd || echo "[0-9999]$(print_mA; print_only)"
        return 11
      fi
      touch $f
    fi

  else
    # print current value
    $isAccd && echo ${maxChargingCurrent[0]-} \
      || echo "${maxChargingCurrent[0]:-$(print_default)}$(print_mA)"
    return 0
  fi
}
