set_ch_curr() {

  local f=$TMPDIR/.mcc-custom
  local isAccd=${isAccd:-false}

  # Fast no-op on restore ONLY when there is truly nothing to clear: no tmpfs marker (no limit
  # applied this boot) AND no value anywhere in the config (array or scalar). The marker is gone
  # every reboot, so the config-value check is what lets a post-reboot clear still proceed (field
  # video: AccA showed "Disabled" while the editor resurrected the stored milliamps). The gate
  # must NOT depend on the resolved control files: the daemon calls `set_ch_curr -` every loop
  # when no limit is set, and a ctrl-files clause turned that into a full default rewrite + USB
  # re-kick (apsd_rerun/rerun_aicl) every 3-9s on every phone with current control nodes -
  # constant AICL renegotiation while charging (A3-reproduced: 3 restores in 3 ticks).
  [[ ! -f $f && .${1-} = .- ]] \
    && [ -z "${maxChargingCurrent[0]-}${max_charging_current-}${mcc-}" ] && return 0 || :

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
          # Also restore the control nodes when they were already resolved this boot: writing the
          # stored defaults is a plain file write (no live-charging probe needed). Returning without
          # it left the caps applied with a clean config - the phone stayed current-limited until
          # reboot, and the daemon's own later `set_ch_curr -` no-ops once the marker is gone
          # (field report: disabled Charging power control, UI clean, still capped at 1100 mA).
          grep -q / $TMPDIR/ch-curr-ctrl-files 2>/dev/null \
            && (applyOnPlug=(); maxChargingVoltage=(); maxChargingCurrent=(); apply_on_plug default) || :
          for _rr in /sys/class/power_supply/usb/apsd_rerun /sys/class/power_supply/battery/rerun_aicl; do
            [ -w "$_rr" ] && echo 1 > "$_rr" 2>/dev/null || :
          done
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
  if [ -n "${1-}" ]; then

    apply_on_plug_() {
      (applyOnPlug=()
      maxChargingVoltage=()
      apply_on_plug ${1-})
    }

    # A clear (-) must succeed even when the control files were not resolved this boot, or on a
    # device that probed them but found none (current control effectively unsupported): drop the
    # config value unconditionally and only touch the nodes / re-kick USB when the control files
    # are known. Previously a clear hit the "no ctrl file" bail below and returned WITHOUT
    # clearing, so write-config re-persisted the old milliamps and the editor kept resurrecting the
    # value the dashboard had already cleared (field video: disabled Charging power control, still
    # showed 1100 mA). The not-charging clear above only covers the no-.mcc-read case; this covers
    # the .mcc-read-set-but-unresolved case. Mirrors set-ch-volt's clear.
    if [ $1 = - ]; then
      grep -q / $TMPDIR/ch-curr-ctrl-files 2>/dev/null && {
        apply_on_plug_ default
        # The stored "defaults" are snapshots from probe time, and negotiation-owned input nodes
        # (usb/current_max) may have been probed on a weak source - restoring 500000 from a PC-USB
        # probe leaves a wall charger crawling at 500 mA. Re-kick USB source detection / input
        # arbitration so those re-settle to the live charger's real capability (same pattern as the
        # uninstaller's un-cap path; harmless no-op when already correct).
        for _rr in /sys/class/power_supply/usb/apsd_rerun /sys/class/power_supply/battery/rerun_aicl; do
          [ -w "$_rr" ] && echo 1 > "$_rr" 2>/dev/null || :
        done
      } || :
      maxChargingCurrent=()
      max_charging_current=
      unset mcc
      $isAccd || print_curr_restored
      rm $f 2>/dev/null || :
      return 0
    fi

    # A numeric SET needs the resolved control files to know which nodes to write.
    grep -q / $TMPDIR/ch-curr-ctrl-files 2>/dev/null || {
      $isAccd || print_no_ctrl_file
      return 0
    }

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

    # [0-9999] milliamps range. Guard the numeric test (2>/dev/null + quoted) exactly like the
    # not-charging path above: a non-numeric mcc that slipped through write-config's scalar gate
    # would make "[ abc -ge 0 ]" error out every daemon tick.
    if [ "$1" -ge 0 ] 2>/dev/null && [ "$1" -le 9999 ] 2>/dev/null; then
      apply_current $1 || return 1
    else
      $isAccd || echo "[0-9999]$(print_mA; print_only)"
      return 11
    fi
    touch $f

  else
    # print current value
    $isAccd && echo ${maxChargingCurrent[0]-} \
      || echo "${maxChargingCurrent[0]:-$(print_default)}$(print_mA)"
    return 0
  fi
}
