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
          # rc22: drop the marker FIRST. It is what says "a cap is applied", and the daemon can be
          # mid-loop holding the config it read before the user cleared it. Releasing before the
          # marker goes leaves a window where the daemon re-applies the cap a second later -- and
          # with the marker then gone, every later `set_ch_curr -` no-ops, so the phone stays capped
          # for good. Ledger from a Mi A3, one second apart:
          #   20:43:47 write usb/current_max <- 5000000 (was 1000000)   the release
          #   20:43:48 write usb/current_max <- 1000000 (was 2050000)   the daemon putting it back
          # rc22b: the SAME daemon-release guard as the resolved clear below. This branch had none.
          #
          # There are three sites that remove the marker and only one was covered, which is why two
          # rounds of "fixes" moved the failure rate around without closing it: the guard was on a path
          # the race was not always taking. A daemon-initiated release must back off here too while a CLI
          # set is in flight, or the marker dies and every later apply skips the nodes that throttle.
          #
          # The user's own clear reaches this branch while the CLI legitimately holds the mutex, so the
          # test is on _accdRelease, not on the mutex alone.
          # rc22b: a daemon release must consult the config ON DISK, not the copy it loaded at the top of
          # its loop.
          #
          # Three earlier attempts failed because all of them guarded on a MUTEX, and a mutex cannot cover
          # a decision made from stale data. The daemon reads config once per tick; a tick that read the
          # pre-publish config can arrive here AFTER the CLI has finished and dropped the mutex, so both
          # the check in accd.sh and the mutex check here see nothing and let it through. Instrumentation
          # showed exactly that: 2 losses in 20 cycles and exactly 2 daemon-initiated removals. The
          # daemon was the writer and the guard was in the right branch - it just asked a stale question.
          #
          # The config file IS the authority on whether a cap exists. Reading it at the instant of the
          # decision cannot go stale, and it costs one sed on a path that runs at most once per loop.
          if ${_accdRelease:-false}; then
            [ -f $TMPDIR/.mcc-settling ] && return 0
            _dsk=$(sed -n 's/^maxChargingCurrent=(//p' ${config:-/data/adb/vr25/acc-data/config.txt} 2>/dev/null | cut -d' ' -f1 | tr -d ')')
            case "${_dsk:-}" in
              ''|-) : ;;
              *) return 0 ;;
            esac
          fi
          rm $f 2>/dev/null || :
          grep -q / $TMPDIR/ch-curr-ctrl-files 2>/dev/null \
            && (applyOnPlug=(); maxChargingVoltage=(); maxChargingCurrent=(); apply_on_plug default) || :
          rekick_usb clear-not-charging || :
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
      # rc22b: refuse a DAEMON-initiated release while a CLI set is in flight.
      #
      # The first attempt at this checked the mutex up in accd.sh, before calling here. That leaves
      # the whole function call between the check and the `rm` below, and the CLI can create both
      # the mutex and the marker inside that window - measured at 1 set in 6 still losing the
      # marker, down from about 40% but not gone. The check has to be adjacent to the action.
      #
      # It must also NOT block the user's own clear: `acc -s max_charging_current=` reaches this
      # same branch while the CLI legitimately holds the mutex. Only the daemon sets _accdRelease,
      # so only the daemon backs off.
      # rc22b: a daemon release must consult the config ON DISK, not the copy it loaded at the top of
      # its loop.
      #
      # Three earlier attempts failed because all of them guarded on a MUTEX, and a mutex cannot cover
      # a decision made from stale data. The daemon reads config once per tick; a tick that read the
      # pre-publish config can arrive here AFTER the CLI has finished and dropped the mutex, so both
      # the check in accd.sh and the mutex check here see nothing and let it through. Instrumentation
      # showed exactly that: 2 losses in 20 cycles and exactly 2 daemon-initiated removals. The
      # daemon was the writer and the guard was in the right branch - it just asked a stale question.
      #
      # The config file IS the authority on whether a cap exists. Reading it at the instant of the
      # decision cannot go stale, and it costs one sed on a path that runs at most once per loop.
      if ${_accdRelease:-false}; then
        [ -f $TMPDIR/.mcc-settling ] && return 0
        _dsk=$(sed -n 's/^maxChargingCurrent=(//p' ${config:-/data/adb/vr25/acc-data/config.txt} 2>/dev/null | cut -d' ' -f1 | tr -d ')')
        case "${_dsk:-}" in
          ''|-) : ;;
          *) return 0 ;;
        esac
      fi
      # rc22: marker first, same re-apply race as the clear above.
      rm $f 2>/dev/null || :
      grep -q / $TMPDIR/ch-curr-ctrl-files 2>/dev/null && {
        apply_on_plug_ default
        # The stored "defaults" are snapshots from probe time, and negotiation-owned input nodes
        # (usb/current_max) may have been probed on a weak source - restoring 500000 from a PC-USB
        # probe leaves a wall charger crawling at 500 mA. Re-kick USB source detection / input
        # arbitration so those re-settle to the live charger's real capability (same pattern as the
        # uninstaller's un-cap path; harmless no-op when already correct).
        rekick_usb clear-resolved || :
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
      # The marker goes up BEFORE the write, not after. apply_on_plug refuses to apply a current cap
      # while the marker is absent -- that guard exists so a daemon holding a config it read before
      # the user cleared it cannot put the cap back a second after the release. Creating the marker
      # afterwards meant the very first apply ran with it still missing, so every current node was
      # skipped: the cap landed in config, the marker appeared, and nothing was ever written. The
      # phone reported a limit it was not enforcing, which is the shape of the reports about caps
      # that do nothing.
      #
      # The marker means "a cap is configured", and it is configured the moment this branch is
      # entered. On a failed apply it comes straight back down, so a failure cannot leave the guard
      # believing in a cap that was never applied.
      touch $f
      apply_current $1 || { rm -f $f 2>/dev/null; return 1; }
    else
      $isAccd || echo "[0-9999]$(print_mA; print_only)"
      return 11
    fi

  else
    # print current value
    $isAccd && echo ${maxChargingCurrent[0]-} \
      || echo "${maxChargingCurrent[0]:-$(print_default)}$(print_mA)"
    return 0
  fi
}
