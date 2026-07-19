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
      . $config

      export "$@"

      [ .${mcc-${max_charging_current-x}} = .x ] \
        || set_ch_curr ${mcc:-${max_charging_current:--}} || :

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
      two="${2//,/|}"
      . $execDir/print-config.sh ns | { grep -E "${two:-.}" | more; } || :
      return 0
    ;;

    # print current config
    p|--print)
      two="${2//,/|}"
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
      set_ch_curr ${2-}
    ;;

    # set charging voltage
    v|--voltage)
      shift
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

  if $restartDaemon; then
    if [ ".${cw-${current_workaround-x}}" != .x ]; then
      $TMPDIR/accd --init $config
    else
      $TMPDIR/accd $config
    fi
  fi
}
