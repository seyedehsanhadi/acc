print_ss_() {
  local IFS=$' \t\n'
  local csw="charging_switch=\"${chargingSwitch[*]-}\""
  case "$csw" in
    *\ --*) echo "$csw";;
    *) printf "%s" "$csw"; echo " ($(print_auto))";;
  esac
  echo
}


set_prop() {

  local restartDaemon=false
  local line=
  local two=

  case ${1-} in

    # set multiple properties
    *=*)
      . $defaultConfig
      # rc21: parse-safe, same reason as acc.sh. The defaults are already loaded above, so a
      # malformed config leaves those in place and the write below REPAIRS the file rather than
      # the whole command dying on it.
      #
      # MUST stay guarded. set-prop.sh is shared by two front-ends: acc.sh, which sources
      # misc-functions.sh (where srccfg_try lives), and acca.sh, the minimal front-end used by
      # AccA and by the daemon itself, which sources neither. Calling srccfg_try unguarded here
      # made `$TMPDIR/acca $config --set charging_switch=` fail silently under acca.sh, so the
      # daemon could no longer clear a blocked charging switch -- device-proven on a Mi A3.
      if command -v srccfg_try >/dev/null 2>&1; then
        srccfg_try "$config" || :
      else
        . $config 2>/dev/null || :
      fi

      # rc21: these keys are ARRAYS in the config. Exporting one as a scalar (which is exactly
      # what `acc -s capacity="5 101 70 75 true"` does) leaves write-config reading ${capacity[0]}
      # as the whole string and ${capacity[4]} as empty, so every field silently falls back to its
      # default and the command reports success while changing nothing. The config header
      # documents the array shape, so users type this. charging_switch is NOT listed: it is a
      # scalar setter and the daemon itself uses it.
      for _spk in "$@"; do
        case "$_spk" in
          capacity=*|temperature=*|cooldownRatio=*|cooldown_ratio=*|loopDelay=*|loop_delay=*)
            echo "Cannot set ${_spk%%=*} directly: it is an array in the config." >&2
            echo "Use the individual settings, for example:" >&2
            echo "  acc -s shutdown_capacity=5 cooldown_capacity=60 resume_capacity=70 pause_capacity=75 capacity_mask=false" >&2
            echo "  acc -s cooldown_temp=45 max_temp=50 resume_temp=40 shutdown_temp=55" >&2
            echo "  acc 75 70    (shortcut for pause and resume capacity)" >&2
            return 2
          ;;

          # rc22: REFUSE an out-of-range capacity here, the way the shorthand already does.
          #
          # rc21 added this check to `acc 999` only. The -s form never got it, so it stayed the
          # "success tick over a value you did not ask for" that the shorthand fix exists to stop:
          #
          #     acc -s pause_capacity=999  ->  exit 0, prints the tick, stores 80
          #     acc -s pause_capacity=101  ->  exit 0, prints the tick, stores 80
          #     acc -s pause_capacity=abc  ->  exit 0, prints the tick, stores 75
          #
          # write-config clamps anything outside the documented ranges to 80 and drops a
          # non-numeric value entirely, so the number on screen is not the number in force and
          # nothing says so. Measured on a Mi A3 running rc22; a non-numeric pause capacity also
          # moved shutdown_capacity to 0, so garbage in one field disabled protection in another.
          #
          # This is the more important of the two paths: `-s key=value` is what AccA sends for
          # every setting the app writes, and what the daemon uses internally.
          #
          # Ranges are the documented ones and match acc.sh exactly: percent, or millivolts. An
          # EMPTY value is allowed through untouched - clearing a key is a legitimate operation and
          # the daemon relies on it. cooldown_capacity is deliberately NOT checked here: it uses
          # 101 to mean "disabled", a different domain that this rule would wrongly reject.
          # write-config's own clamp stays exactly as it is, as the backstop for a corrupt config
          # file rather than for a user command.
          pause_capacity=*|resume_capacity=*|shutdown_capacity=*)
            _spv=${_spk#*=}
            if [ -n "${_spv:-}" ]; then
              case "$_spv" in
                *[!0-9]*)
                  echo "Invalid ${_spk%%=*}: $_spv" >&2
                  echo "Expected a number: 0-100 (percent) or 3001-5000 (mV)" >&2
                  return 2
                ;;
                *)
                  if [ "$_spv" -le 100 ] 2>/dev/null; then :
                  elif [ "$_spv" -ge 3001 ] 2>/dev/null && [ "$_spv" -le 5000 ] 2>/dev/null; then :
                  else
                    echo "Capacity out of range: $_spv" >&2
                    echo "Expected 0-100 (percent) or 3001-5000 (mV)" >&2
                    return 2
                  fi
                ;;
              esac
            fi
          ;;
        esac
      done

      export "$@"

      # set_ch_curr REFUSES an out-of-range milliamp value (prints "[0-9999] mA only", returns
      # 11) - it never clamps. `|| :` swallowed that and left the refused scalar exported, so
      # write-config.sh's own clamp (`[ $mcc -le 9999 ] || mcc=9999`) then PERSISTED it: the
      # command told the user the value was refused and still wrote a 9999 mA cap nobody asked
      # for. Drop the key on a refusal so write-config falls back to ${maxChargingCurrent[@]}
      # and the stored value is left exactly as it was. Only exit 11 (the range refusal) is
      # treated this way; the documented no-control-file exit (0) still persists the intent for
      # the daemon to re-apply, and a failed apply (1) is unchanged.
      [ .${mcc-${max_charging_current-x}} = .x ] \
        || { : > $TMPDIR/.mcc-settling 2>/dev/null; set_ch_curr ${mcc:-${max_charging_current:--}}; } \
        || { [ $? -ne 11 ] || unset mcc max_charging_current; }

      [ ".${mcv-${max_charging_voltage-x}}" = .x ] \
        || set_ch_volt "${mcv:-${max_charging_voltage:--}}" || :

      [ -z "${tl-}${temp_level-}" ] || set_temp_level ${tl:-$temp_level}
      echo "✅"
    ;;

    # reset config
    r|--reset)
      ! daemon_ctrl stop > /dev/null || restartDaemon=true
      cat $defaultConfig > $config
      [ .${2-} = .a ] && rm $dataDir/logs/write.log $dataDir/logs/ps-blacklist.log 2>/dev/null || :
      print_config_reset
      ! $restartDaemon || $TMPDIR/accd --init $config
      return 0
    ;;

    # print default config
    d|--print-default)
      . $defaultConfig
      # $2 is UNSET for the long forms (`acc -s --print`, `acc -s --print-default`), and acc.sh
      # is under `set -eu` from misc_stuff by the time it dispatches here, so a bare
      # "${2//,/|}" aborts the command with "parameter not set" instead of printing anything.
      # acc.sh's own -sp/-sd wrappers hide it by passing "${2-.*}"; the long forms pass nothing.
      # Same guard acca.sh already carries (rc7/F7). Empty still falls back to "." below.
      two="${2-}"; two="${two//,/|}"
      . $execDir/print-config.sh ns | { grep -E "${two:-.}" | more; } || :
      return 0
    ;;

    # print current config
    p|--print)
      two="${2-}"; two="${two//,/|}"   # unset $2 under set -u: see --print-default above
      . $execDir/print-config.sh | { grep -E "${two:-.}" | more; } || :
      return 0
    ;;

    # set charging switch
    s|--charging*witch)
      IFS=$'\n'
      PS3="$(print_choice_prompt)"
      print_ss_
      . $execDir/select.sh
      select_ charging_switch $(print_auto; sort -u $TMPDIR/ch-switches; print_exit)
      [ ${charging_switch:-x} != $(print_exit) ] || exit 0
      [ ${charging_switch:-x} != $(print_auto) ] || charging_switch=
      case "${charging_switch:-x}" in
        "$(print_exit)") exit 0;;
        "$(print_auto)") charging_switch=;;
        */*)
          case "$charging_switch" in
            */*) charging_switch="$charging_switch --";;
          esac
        ;;
      esac
      unset IFS
    ;;

    # print switches
    s:|--charging*witch:)
      sort -u $TMPDIR/ch-switches 2>/dev/null || :
      return 0
    ;;

    -ss::|--charging*witch::)
      sort $dataDir/logs/working-switches.log 2>/dev/null | nl -s ") " -w 2 -v 1 || :
      return 0
    ;;

    # set charging current
    c|--current)
      # Reject a non-numeric milliamp value BEFORE it reaches the config. `acc -sc abc` stored
      # cooldownCurrent=(abc) verbatim: the setter's own range check only guards numbers, and
      # nothing downstream re-validates, so a typo became a live setting that the daemon then
      # fed to raw arithmetic. Empty and "-" are the documented "unset" forms and still pass.
      case "${2-}" in
        ''|-) ;;
        *[!0-9]*) echo "Charging current must be a whole number of mA (or '-' to unset)." >&2; return 3;;
      esac
      set_ch_curr ${2-}
    ;;

    # set charging voltage
    v|--voltage)
      shift
      # Same guard for voltage. `acc -sv abc` stored maxChargingVoltage=(3700 abc...) and a
      # typo'd voltage becomes a value ACC writes to a real charge node. The accepted forms are
      # a bare mV number, "-", empty, or a node spec (path::min::max), so require that the
      # argument contain at least one digit rather than demanding all-digits.
      case "${1-}" in
        ''|-) ;;
        *[0-9]*) ;;
        *) echo "Charging voltage must contain a number (mV, a node spec, or '-' to unset)." >&2; return 3;;
      esac
      set_ch_volt "$@"
    ;;

    # set language
    l|--lang)
      IFS=$'\n'
      PS3="$(print_choice_prompt)"
      . $execDir/select.sh
      eval 'select_ _lang \
        $(for file in $(ls -1 $execDir/strings.sh $execDir/translations/*/strings.sh); do \
          sed -n 1p $file | sed "'s/# /- /p'" | grep -v "' .$language.'" | sort -u; \
        done; \
        print_exit)'
      lang=${_lang#*\(}
      [ $lang != $(print_exit) ] || exit 0
      lang=${lang%\)*}
      unset IFS
    ;;

    *)
      if [ -f "${1:-//}" ]; then
        # import config
        # Per-process staging file. $TMPDIR/.tmp is a generic name that acc.sh's
        # edit() also used as its own scratch, and this path hands that very file
        # to edit() - so the import destroyed the config it was building. Keeping
        # a distinct name here means the two can never be the same file even if
        # one of them is changed again later.
        _imp=$TMPDIR/.import.$$.tmp
        cat $config > $_imp
        dos2unix < "$1" | grep -Ev '^:|=""$' >> $_imp || :
        dos2unix < "$1" | grep '^:' | while IFS= read -r line; do
          $TMPDIR/acca $_imp --config a "$line"
        done
        $TMPDIR/acca $_imp --set dummy=
        # only overwrite the live config if the staged one actually has content;
        # an empty staging file must never be allowed to become the config
        if [ -s "$_imp" ]; then
          cat $_imp > $config
          rm -f $_imp
          echo "✅"
        else
          rm -f $_imp
          echo "Import produced an empty config - your existing settings were left alone."
          return 1
        fi
        return 0
      else
        # A path that does not exist is a typo, not a request to print the
        # config. rc20 and earlier dumped the config and returned 0, so a
        # mistyped restore looked exactly like a successful one.
        case "${1-}" in
          */*)
            echo "No such config file: $1"
            return 1
          ;;
        esac
        # print current config (full)
        . $execDir/print-config.sh | more
        return 0
      fi
    ;;

  esac

  # check whether a daemon restart is required (to restore defaults)
  if { [ ".${chargingSwitch[0]-x}" != .x ] \
    && [ ".${s-${charging_switch-x}}" != .x ]; } \
    || [ ".${cw-${current_workaround-x}}" != .x ]
  then
    ! daemon_ctrl stop || restartDaemon=true
  fi > /dev/null

  # update config.txt
  . $execDir/write-config.sh
  # The set is now COMPLETE: nodes written and the config published. Until this point a daemon tick
  # could see the marker already up while still holding the pre-set config, conclude the user had
  # cleared a cap, and run the release path - deleting the marker mid-apply and restoring every node
  # it had just capped. That is why a cap could land in config, read as active in AccA, and throttle
  # nothing. `acc -s` takes no lock, so the daemon needs an explicit signal that a set is in flight.
  # RE-ASSERT the marker now that the config is published, then drop the mutex.
  #
  # Checking the mutex before the destructive rm was not enough, and could never have been: a daemon
  # tick that entered its release branch BEFORE the mutex existed is already committed, and no test
  # placed later in that path can un-commit it. Measured 3 losses in 30 cycles with the guard in
  # place, against 1 in 6 without it - narrower, not closed.
  #
  # What IS final is the config. Until write-config publishes, the daemon holds a config with no cap
  # and its release branch is live; once the cap is in the config that branch can never run again,
  # because it is gated on maxChargingCurrent[0] being empty. So re-asserting the marker here, after
  # publish, is the first moment the assertion cannot be undone. It is idempotent, it only ever runs
  # when the config actually carries a cap, and it costs one touch.
  _rcfg=$(sed -n 's/^maxChargingCurrent=(//p' ${config:-/data/adb/vr25/acc-data/config.txt} 2>/dev/null | cut -d' ' -f1 | tr -d ')')
  if [ -n "$_rcfg" ]; then
    touch $TMPDIR/.mcc-custom 2>/dev/null || :
  fi
  rm -f $TMPDIR/.mcc-settling 2>/dev/null || :

  if $restartDaemon; then
    if [ ".${cw-${current_workaround-x}}" != .x ]; then
      $TMPDIR/accd --init $config
    else
      $TMPDIR/accd $config
    fi
  fi
}
