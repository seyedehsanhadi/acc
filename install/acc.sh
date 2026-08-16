#!/system/bin/sh
# Advanced Charging Controller
# Copyright 2017-2024, VR25
# License: GPLv3+


# $TMPDIR (/dev/<domain>/<id>) is tmpfs: wiped every reboot and rebuilt only by accd.sh's own
# init, which creates these launcher symlinks. That is circular -- every start path below runs
# `exec $TMPDIR/accd`, and $TMPDIR/accd is a symlink to service.sh created BY the daemon it
# launches. Lose the dir while the phone is up (a boot where service.sh never ran, a cleanup
# that removed it) and `acc -D start` prints "accd started" and then dies with
# "/dev/.vr25/acc/accd: inaccessible or not found", with no supported way back short of a
# reboot. Measured on both Magisk and KernelSU. execDir is on persistent storage and always
# present, so rebuild the links from there. Idempotent: a no-op on every normal boot.
ensure_tmpdir_links() {
  local _i="${id:-acc}"
  [ -e "$TMPDIR/${_i}d" ] && [ -d "$TMPDIR" ] && return 0
  mkdir -p "$TMPDIR" 2>/dev/null || :
  ln -fs "$execDir/service.sh" "$TMPDIR/${_i}d" 2>/dev/null || :
  ln -fs "$execDir/${_i}.sh" "$TMPDIR/$_i" 2>/dev/null || :
  ln -fs "$execDir/${_i}.sh" "$TMPDIR/${_i}d," 2>/dev/null || :
  ln -fs "$execDir/${_i}.sh" "$TMPDIR/${_i}d." 2>/dev/null || :
  ln -fs "$execDir/${_i}a.sh" "$TMPDIR/${_i}a" 2>/dev/null || :
}

daemon_ctrl() {

  local isRunning=false

  ensure_tmpdir_links

  flock -n 0 <>$TMPDIR/acc.lock || isRunning=true

  case "${1-}" in

    start)
      if $isRunning; then
        print_already_running
        return 8
      else
        print_started
        echo
        exec $TMPDIR/accd $config
      fi
    ;;

    stop)
      if $isRunning; then
        . $execDir/release-lock.sh
        print_stopped
        return 0
      else
        print_not_running
        return 9
      fi
    ;;

    restart)
      if $isRunning; then
        # release the running daemon's lock FIRST: exec'ing accd without this leaves the old
        # daemon holding acc.lock, so the new accd hits `flock -n 0 || exit 13` in acquire-lock
        # and dies instantly while the stale daemon keeps running (restart silently no-op'd).
        . $execDir/release-lock.sh
        print_restarted
      else
        print_started
      fi
      echo
      exec $TMPDIR/accd $config
    ;;

    *)
      if $isRunning; then
        print_is_running "$accVer ($accVerCode)" "(PID $(cat $TMPDIR/acc.lock))"
        return 0
      else
        print_not_running
        return 9
      fi
    ;;
  esac
}


edit() {
  local file="$1"
  shift
  case "${1-}" in
    a) echo >> $file
       shift
       two=($*)
       # The scratch file MUST NOT be able to be the file being edited. It was
       # $TMPDIR/.tmp, and set-prop.sh's config-import path builds the incoming
       # config in exactly that path and then calls this function on it:
       #     acca $TMPDIR/.tmp --config a "$line"
       # so $file and the scratch became the same file. The redirect truncates
       # the target before grep opens it, grep then reads nothing and exits
       # non-zero, the restore below is skipped, and the rule is appended to an
       # empty file - the user's whole config replaced by its rule lines, with a
       # tick printed. Measured on a Mi A3: a 3-line config came back 1 line.
       # A name per process cannot collide with the caller's file or with a
       # concurrent acc.
       # Stage NEXT TO the target, not in $TMPDIR, and publish by rename.
       # Two reasons. A rename is only atomic within one filesystem, and $TMPDIR
       # is tmpfs while the config lives on /data - so a temp there could never
       # be renamed into place and the code had to `cat` over the original,
       # truncating it. The daemon sources the config on every loop, and under
       # `set -u` a half-written one aborts it, which fires the exit trap and
       # re-enables charging. write-config.sh already publishes this way
       # ($config.tmp then mv -f), so `acc -s` was safe while `acc -c` was not.
       # Staging beside the target also keeps this correct when $file is itself
       # the import staging file in tmpfs, since that is one filesystem too.
       _et=$file.edit.$$.tmp
       if grep -iv "^: ${two[1]%?};" $file > $_et; then
         mv -f $_et $file 2>/dev/null || cat $_et > $file
       fi
       rm -f $_et
       unset two _et
       echo "$@" | sed 's/,/;/g' >> $file;;

    d) shift; sed -Ei "\#$*#d" $file;;

    g) [ "$file" = "$config" ] || {
         install -m 666 $file /data/local/tmp/
         file=/data/local/tmp/${file##*/}
       }
       shift
       ext_app $file "$@";;

    h) [ -n "${2-}" ] || exit 0
       if grep -q "# $2 (.*) #" $file; then
         sed -n "/# $2 (.*) #/,/^$/p" $file | filter
       elif grep -q "# .* ($2) #" $file; then
         sed -n "/# .* ($2) #/,/^$/p" $file | filter
       fi;;

    "") case $file in
          *.log|*.md|*.help) less $file;;
          *) nano -$ $file || vim $file || vi $file || ext_app $file;;
        esac 2>/dev/null;;
    *) IFS="$(printf ' \t\n')" eval "$* $file";;
  esac
}


ext_app() {
  am start -a android.intent.action.${2:-EDIT} \
           -t "text/${3:-plain}" \
           -d file://$1 \
           --grant-read-uri-permission &>/dev/null || :
}


filter() {
  sed '/^$/d; s/ # /, /; s/ #//; s/^# //; s/#//'
}


get_prop() { sed -n "s|^$1=||p" ${2:-$config}; }


switch_fails() {
  print_switch_fails
  ! not_charging >/dev/null || {
    print_resume
    while not_charging; do
      sleep 1
    done
  }
  return 10
}


test_charging_switch_() {

  local idleMode=false
  local failed=false
  local acc_t=true
  chargingSwitch=($@)

  echo

  [ -n "${swCount-}" ] \
    && echo "$swCount/$swTotal: ${chargingSwitch[@]-}" \
    || echo "${chargingSwitch[@]-}"

  echo "chargingSwitch=($*)" > $TMPDIR/.sw
  flip_sw off

  [ $? -eq 2 ] && {
    flip_sw on
    switch_fails
    return 10
  }

  ${blacklisted:-false} && {
    # rc23c: put the switch BACK before bailing out. This returned with the OFF value still applied,
    # and for a voltage switch that is not a slow charge, it is no charge at all.
    #
    # Field fault on a Mi A3: hours after an acc -t run the phone was plugged in and dead flat-lining
    #   pmi632_charger: battery over-voltage vbat_fg = 3905196uV, fv = 3600000uV
    # battery/voltage_max had been left at 3600000 against a 3.9V pack, so the charger refused to
    # charge at all. acc -t had tested `battery/voltage_max 4400000 3600mV` and never wrote the
    # 4400000 back. Nothing else ever would: the daemon did not set that node, so the daemon does not
    # restore it, and the value simply persists. Writing 4400000 by hand brought charging back at
    # 2.27A immediately.
    flip_sw on 2>/dev/null || :
    print_blacklisted
    return 10
  }

  ! not_charging && failed=true || {
    [ $_status = Idle ] && idleMode=true
  }

  flip_sw on 2>/dev/null

  if ! $failed && ! not_charging; then
    print_switch_works
    echo "  battIdleMode=$idleMode"
    $idleMode && return 15 || return 0
  else
    switch_fails
  fi
}


test_charging_switch() {
  local ret=
  lastNode=
  grep -Eq "^(#$1|$1)$" $writeLog 2>/dev/null || { echo "#$1" >> $writeLog; lastNode=$1; }
  test_charging_switch_ "$@"; ret=$?
  [ -n "${lastNode-}" ] && { sed -i "\|^#${lastNode}$|s|^#||" $writeLog; lastNode=; }
  return $ret
}


exxit() {
  local exitCode=$?
  set +eux
  ! ${noEcho:-false} && ${verbose:-true} && echo
  [[ "$exitCode" = [05689] ]] || {
    # Upstream wrote "[127]|10" -- a character class meaning 1, 2, 7 or 10 --
    # and rc15 dropped the brackets, leaving the literal 127 and killing the
    # auto-export almost entirely. Restoring the class verbatim is wrong now
    # that a mistyped command exits 2: every typo would drop a tarball in
    # Downloads, which is the exact confusion this was reported for. Export on
    # the codes that mean charge control actually failed.
    eq "$exitCode" "7|10" && logf --export
    echo
  }
  cd /
  exit $exitCode
}


parse_switches() {

  # Per-process scratch name. A single shared path is the same defect that made
  # write_state publish half-built JSON: a second caller truncates the first
  # one's file mid-read and both get garbage. Only the deliberate -t scan
  # reaches this, so overlap is far less likely than it was for state.json, but
  # the cost of not sharing the name is nil.
  # Deliberately no trap here: the -t path installs its own EXIT/INT/TERM/HUP
  # trap (exxit) and setting one in this function would replace it, so the
  # scanner would stop restoring the daemon and the charging switch.
  local f=$TMPDIR/.parse_switches.$$.tmp
  local i=
  local n=

  [ -n "${2-}" ] || set -- $TMPDIR/ch-switches "${1-}"

  if [ -z "${2-}" ]; then
    set -- $1 $(echo $dataDir/logs/power_supply-${device}.log)
    [ -f $2 ] || $execDir/power-supply-logger.sh
  fi

  cat -v "$2" > $f

  for i in $(grep -Ein '^  ((1|0)$|.*able.*)' $f | cut -d: -f1); do

    n=$i
    i="$(sed -n "$(($n - 1))p" "$f")"
    n=$(sed -n ${n}p $f | sed 's/^  //')

    case $n in
      0) n="$n 1";;
      1) n="$n 0";;
      disable) n="$n enable";;
      disabled) n="$n enabled";;
      enable) n="$n disable";;
      enabled) n="$n disabled";;
      DISABLE) n="$n ENABLE";;
      DISABLED) n="$n ENABLED";;
      ENABLE) n="$n DISABLE";;
      ENABLED) n="$n DISABLED";;
      *) continue;;
    esac

    i=${i#*/power_supply/}

    # exclude all known switches
    ! grep -q "$i " $1 || continue

    # blacklist
    i="$(echo "$i $n" | grep -Eiv 'authentic|brightness|calibrat|capacitance|count|curr|cycle|daemon|demo|design|detect|disk|empty|factory|fast|fcc|flash|full|info|init|learn|mask|moist|nvram|online|otg|parallel|present|priority|protect|reboot|refcnt|report|resistance|reset|reverse|scale|time|rx_|ship|shutdown|state|status|step|sync|temp|timer|tx_|type|update|user|vbus|verif|volt|wait|wake')" || :

    # rc21: never SUGGEST a node that already crashed this phone. -p is where an owner goes
    # looking for a switch after the scan came up empty, which is exactly the phone where the
    # blacklist is non-empty, so offering the killer node back is the worst possible advice.
    [ -z "$i" ] || ! sw_blacklisted "${i%% *}" || continue

    [ -z "$i" ] || echo "$i"

  done

  # -f so a run that never got as far as creating the file cannot abort the
  # scan here under set -e
  rm -f $f
}


rollback() {
  if [[ ".${*-}" != *v* ]]; then
    print_wait
    for i in $execDir/*; do
      [[ $i = */system ]] || rm -rf $i
    done
    rm -rf $dataDir/backup/system
    cp -a $dataDir/backup/* $execDir/
    if [[ ".${*-}" = *n* ]]; then
      rm $execDir/config.txt
    else
      mv -f $execDir/config.txt $config
    fi
    $execDir/service.sh --init
    printf "✅ "
  fi
  i=$dataDir/backup/module.prop
  [ -f $i ] || i=$execDir/module.prop
  sed -n 's/^versionCode=//p' $i
}


set_prop_() {
  . $execDir/set-prop.sh
  set_prop "$@"
}


# Cosmetic blank line before human-facing output. It must NOT precede a machine-readable
# stream: `acc -j` / `--state` is JSON that AccA parses, and this spacer made every reply start
# with an empty line (measured: `acc -j | od -c` began "\n{"), which a strict parser rejects.
# `-sp` is a key=value read the app also consumes, so it is excluded too. Same guard style as
# the verbose-log exclusion below.
case "${1-}" in
  # Machine-readable arms: suppress BOTH spacers. The leading one is this echo; the trailing one
  # comes from exxit()'s `! ${noEcho:-false} && ${verbose:-true} && echo` on the EXIT trap, which
  # already has a noEcho flag for exactly this purpose. Together they made `acc -j` emit a blank
  # line before AND after the JSON.
  # -ss: and -ss:: are the switch listings AccA reads to build its picker, one switch per line.
  # The spacer put an empty first line in front of both, so the app saw a blank entry and every
  # line count was one too high (`acc -ss:` on a 3-switch list reported 4).
  -j|--state|-sp|-sp:|-ss:|-ss::|--print*|--charging*witch:|--charging*witch::) noEcho=true;;
  # Same arms reached the long way round: `acc -s --charging_switch:` is `acc -ss:`, so it has to
  # suppress the spacer too or the two forms disagree on their first line.
  -s|--set)
    case "${2-}" in
      --charging*witch:|--charging*witch::|--print*) noEcho=true;;
      *) ! ${verbose:-true} || echo;;
    esac
  ;;
  *) ! ${verbose:-true} || echo;;
esac
execDir=/data/adb/vr25/acc
defaultConfig=$execDir/default-config.txt

# load generic functions
. $execDir/logf.sh
. $execDir/misc-functions.sh

if eq "${1-}" "--test*|-t*|-x"; then
  log=/sdcard/Download/acc-${device}.log
  [ $1 != -x ] || shift
else
  log=$TMPDIR/acc-${device}.log
fi

# verbose
if ${verbose:-true} && !  eq "${1-}" "-l*|--log*|-w*|--watch*"; then
  [ -z "${LINENO-}" ] || export PS4='$LINENO: '
  touch $log
  [ $(du -k $log | cut -f 1) -ge 256 ] && : > $log
  echo "###$(date)###" >> $log
  echo "versionCode=$(sed -n s/versionCode=//p $execDir/module.prop 2>/dev/null)" >> $log
  set -x 2>>$log
fi


accVer=$(get_prop version $execDir/module.prop)
accVerCode=$(get_prop versionCode $execDir/module.prop)

unset -f get_prop

misc_stuff "${1-}"
[[ "${1-}" != */* ]] || shift

# rc21: this was a bare `. $config`, and a truncated config killed the front-end here. The daemon
# survives one (accd's _srccfg), so the phone kept its limit while `acc -i`, `acc -s`, `acc -D`
# and every AccA call died -- on exactly the file the user would run acc to repair. Same guard,
# then the daemon's last known-good copy, then the shipped defaults, and say which happened.
if ! srccfg_try "$config"; then
  if srccfg_try $dataDir/.config-good; then
    echo "Warning: $config is malformed; using the last known-good settings." >&2
  else
    . $defaultConfig 2>/dev/null || :
    echo "Warning: $config is malformed and no known-good copy exists; using defaults." >&2
  fi
  echo "Repair it with: acc -s --reset" >&2
fi


# load default language (English)
. $execDir/strings.sh

# load translations
: ${language:=en}
if ${verbose:-true} && [ -f $execDir/translations/$language/strings.sh ]; then
  . $execDir/translations/$language/strings.sh
fi

grep -q .. $execDir/translations/$language/README.html 2>/dev/null \
  && readMe=$execDir/translations/$language/README.html \
  || readMe=$dataDir/README.html


# aliases/shortcuts
# daemon_ctrl status (acc -D|--daemon): "accd,"
# daemon_ctrl stop (acc -D|--daemon stop): "accd."
[[ "$0" != *accd* ]] || {
  case $0 in
    *accd.) daemon_ctrl stop;;
    *) daemon_ctrl;;
  esac
  exit $?
}


case "${1-}" in

  "")
    . $execDir/wizard.sh
    wizard
  ;;

  [0-9]*)
    # rc21 (A1): this pattern matches anything merely STARTING with a digit, so
    # "12abc" arrived here as a capacity. write-config.sh then blanks it as
    # non-numeric and ": ${pc:=75}" substitutes the default, so `acc 12abc`
    # produced byte-identical output to `acc 75` and still printed the success
    # tick. Reject a malformed capacity instead of silently guessing one.
    # Digits and spaces only; "75", "75 70" and "3900" are unaffected.
    case "$1${2+ $2}" in
      *[!0-9\ ]*)
        echo "Invalid capacity: $1${2+ $2}" >&2
        echo "Expected 0-100 (percent) or 3001-5000 (mV), e.g. acc 75 70" >&2
        exit 2
      ;;
    esac
    # rc21: rc21 rejected non-numeric input but a numeric value OUT OF RANGE still slipped
    # through: `acc 999` was accepted with a success tick and silently stored 80/75 instead,
    # which is the same "success tick over a value you did not ask for" this arm exists to stop.
    # It fails safe rather than dangerously (a limit is still applied, never removed), but the
    # user is told nothing. Ranges are the documented ones: percent, or millivolts.
    for _cv in $1 ${2-}; do
      if [ "$_cv" -le 100 ] 2>/dev/null; then :
      elif [ "$_cv" -ge 3001 ] 2>/dev/null && [ "$_cv" -le 5000 ] 2>/dev/null; then :
      else
        echo "Capacity out of range: $_cv" >&2
        echo "Expected 0-100 (percent) or 3001-5000 (mV), e.g. acc 75 70" >&2
        exit 2
      fi
    done
    pause_capacity=$1
    resume_capacity=${2:-5000}
    . $execDir/write-config.sh
    echo "✅"
  ;;

  -b*|--rollback*)
    rollback "${*-}"
  ;;

  -sk|--rekick)
    # The charger re-kick re-runs input detection when charging looks stalled. It is what
    # recovers a stuck charger, and also what can collapse a fast-charge handshake on a phone
    # whose stall check misfires, so it needs an off switch that is not a script edit.
    case "${2-}" in
      off) touch $dataDir/.rekick-off 2>/dev/null || :
           echo "Charger re-kick OFF. ACC will not re-run charger input detection."
           echo "If charging ever stalls and does not resume, turn it back on: acc -sk on";;
      on)  rm -f $dataDir/.rekick-off 2>/dev/null || :
           echo "Charger re-kick ON (the default).";;
      ''|status)
           [ -f $dataDir/.rekick-off ] && echo "off" || echo "on";;
      *)   echo "usage: acc -sk [on|off]   (no argument prints the current setting)" >&2; exit 2;;
    esac
  ;;

  --early-cap)
    # rc21: the boot-gap cap runs at post-fs-data, before Android exists, so it is the one write
    # that can boot-loop a phone. It self-disables by latching $dataDir/.no-early-cap after a
    # crash or 3 bad boots -- but nothing ever removed that latch, it was undocumented, and it had
    # no CLI. A user who tripped it once lost boot-gap overcharge protection permanently with no
    # way back short of deleting a hidden file they had no way to learn about.
    case "${2-}" in
      off) touch $dataDir/.no-early-cap 2>/dev/null || :
           echo "Boot-gap cap OFF. ACC will not touch the charging switch before Android starts."
           echo "The daemon still enforces your limit a few seconds into the boot.";;
      on)  rm -f $dataDir/.no-early-cap 2>/dev/null || :
           echo "Boot-gap cap ON (the default)."
           echo "If the phone ever fails to boot after this, it self-disables again on the next boot.";;
      ''|status)
           if [ -f $dataDir/.no-early-cap ]; then
             echo "off"
             echo "It was either turned off by hand, or latched off automatically after a boot" >&2
             echo "that did not complete. Re-enable with: acc --early-cap on" >&2
           else echo "on"; fi;;
      *)   echo "usage: acc --early-cap [on|off]   (no argument prints the current setting)" >&2; exit 2;;
    esac
  ;;

  -sb|--blacklist)
    # rc21: reach AMPS's crash blacklist from the `acc` command. The engine already owned
    # this (it has to: it runs on a phone that is currently unsafe to scan), but it was only
    # reachable by calling acc-compat.sh at its full path, which nobody can be expected to
    # remember. Router only; the engine stays the single implementation. Resolved by search so
    # it works whichever root manager mounts the module.
    shift
    _amps=
    for _a in $execDir/acc-compat.sh /data/adb/vr25/acc/acc-compat.sh \
              /data/adb/modules/acc/acc-compat.sh; do
      [ -f "$_a" ] && { _amps=$_a; break; }
    done
    [ -n "$_amps" ] || { echo "AMPS engine not found (looked in $execDir and the module dir)" >&2; exit 3; }
    # rc21: "clear" must also release ACC's OWN crash state, not just the engine's list. The probe
    # journal (.probe-blacklist) and the global probe latch (.no-probe) are written by accd, not by
    # AMPS, so an exec straight into the engine left a latched phone with no way back short of
    # deleting files by hand. Done before the exec, which replaces this process.
    case ${1-} in
      clear)
        rm -f "$dataDir/.probe-blacklist" "$dataDir/.no-probe" 2>/dev/null || :
        sync 2>/dev/null || :
        echo "Cleared ACC's crash blacklist and re-enabled automatic switch searching."
      ;;
      ''|list)
        # A latched phone stops looking for a switch, which otherwise looks like ACC has simply
        # stopped working. Say so here, where the user is already looking.
        [ ! -f "$dataDir/.no-probe" ] || {
          echo "Automatic switch searching is OFF."
          # .no-probe and .probe-blacklist are written independently by accd, so the latch can
          # exist with no blacklist file yet. The `2>/dev/null` on the `done` line does NOT
          # suppress the shell's own failed-open diagnostic for an input redirect, so `acc -sb
          # list` aborted with "can't open .../.probe-blacklist: No such file or directory" and
          # rc=1 (reproduced on both Magisk and KernelSU). Only read it if it is there.
          _nbl=0
          if [ -f "$dataDir/.probe-blacklist" ]; then
            while IFS= read -r _bll || [ -n "${_bll:-}" ]; do
              case ${_bll} in ''|'#'*) continue;; esac
              _nbl=$(( _nbl + 1 ))
            done < "$dataDir/.probe-blacklist"
          fi
          echo "  $_nbl switch(es) crash-rebooted this phone, so ACC stopped trying to find one."
          echo "  Pick one by hand:  acc -ss"
          echo "  Or start over:     acc -sb clear"
          echo ""
        }
      ;;
    esac
    exec sh "$_amps" --blacklist "$@"
  ;;

  -c|--config)
    shift; edit $config "$@"
  ;;

  -d|--disable)
    shift
    ${verbose:-true} || exec > /dev/null
    ! daemon_ctrl stop > /dev/null || print_stopped
   . $execDir/acquire-lock.sh
    disable_charging "$@"
  ;;

  -D|--daemon)
    shift; daemon_ctrl "$@"
  ;;

  -e|--enable)
    shift
    ${verbose:-true} || exec > /dev/null
    ! daemon_ctrl stop > /dev/null || print_stopped
    . $execDir/acquire-lock.sh
    enable_charging "$@"
  ;;


  -f|--force|--full)

    auto=false
    cap=100
    shift

    # rc21: an argument that was neither a number nor -a used to be silently DISCARDED, leaving
    # the default cap=100 -- so `acc -f 8O` (letter O for zero), or any typo, force-charged the
    # phone to FULL. That is the most aggressive possible outcome of a typo, on a tool whose
    # entire purpose is not charging to full. Same class as `acc 999` and `acc 12abc`, which are
    # already refused; -f was missed. AccA passes a plain number here (charge-once), so a valid
    # limit is unaffected, and `acc -f` with no argument still means 100 as documented.
    for i in ${1-} ${2-}; do
      [ -n "$i" ] || continue
      case "$i" in
        -a) auto=true; shift;;
        *[!0-9]*)
          echo "Invalid argument for -f: $i" >&2
          echo "Usage: acc -f [capacity] [-a]     e.g. acc -f 90" >&2
          exit 2
        ;;
        *) cap=$i; shift;;
      esac
    done
    case ${cap:-100} in ''|*[!0-9]*) cap=100;; esac
    { [ "$cap" -ge 1 ] && [ "$cap" -le 100 ]; } 2>/dev/null || {
      echo "Capacity out of range for -f: $cap (expected 1-100)" >&2
      exit 2
    }

    cp -f $config $TMPDIR/.acc-f-config
    config=$TMPDIR/.acc-f-config
    sed -i '/^:/d' $config

    (allow_idle_above_pcap=
    cooldown_capacity=
    cooldown_charge=
    cooldown_current=
    cooldown_pause=
    cooldown_temp=
    idle_apps=
    max_charging_current=
    max_charging_voltage=
    max_temp=
    off_mid=false
    pause_capacity=$cap
    resume_capacity=$((cap - 2))
    resume_temp=
    temp_level=
    . $execDir/write-config.sh)

    ! $auto || print '\n:; online || exec $TMPDIR/accd' >> $config
    # rc21 SECURITY: was `eval $TMPDIR/acca $config "$@"`. The pass-through options of
    # `acc -f 90 -s mcc=500` are already separate words by the time they reach here, so eval
    # bought nothing and handed the caller's argument to the shell: `acc -f '$(cmd)'` ran cmd
    # AS ROOT. Same class as the rc21 eq() fix, in a path that fix did not cover. Calling the
    # helper directly passes the identical words without a round trip through the parser.
    [ -z "${1-}" ] || "$TMPDIR/acca" "$config" "$@"

    print_charging_enabled_until ${cap}%
    $auto || print_restart_accd
    ! ${verbose:-true} || {
      notif "$(print_charging_enabled_until ${cap}%; $auto || print_restart_accd)"
      echo
    }
    unset auto cap i
    ensure_tmpdir_links
    exec $TMPDIR/accd $config
  ;;


  -F|--flash)
    shift
    set +eux
    trap - EXIT
    $execDir/flash-zips.sh "$@"
  ;;


  -H|--health)

    counter=$(set +e; grep -E '[1-9]+' */charge_counter 2>/dev/null | head -n 1 | sed 's/.*://' || :)
    health=
    level=$(batt_cap)
    mAh=${2-}

    [ -n "$mAh" ] || { echo "${0##*/} $1 <mAh>"; exit; }
    [ -n "$counter" ] || { echo "!"; exit; }
    [ "${level:-0}" -ge 1 ] 2>/dev/null || { echo "!"; exit; }

    [ $counter -lt 10000 ] || counter=$(calc $counter / 1000)
    health=$(calc "$counter * 100 / $level * 100 / $mAh" | xargs printf %.1f)
    [ ${health%.*} -le 99 ] && echo ${health}% || echo "!"
  ;;

  -i|--info)
    . $execDir/batt-info.sh
    batt_info "${2-}" | more
  ;;

  -j|--state)
    # publish/print the machine-readable state export (subsystem A): cats the daemon's
    # tmpfs snapshot, or generates one on demand if the daemon is not running.
    # Emit EXACTLY one line. state.json is a single line ending in one newline, but something
    # on the exit path appended a second, so `acc -j` returned two lines where AccA expects
    # one. Command substitution strips every trailing newline; printf puts back exactly one.
    printf '%s\n' "$(print_state)"
  ;;

  -la)
    shift
    logf --acc "$@"
  ;;

  -le)
    logf --export
  ;;

  -l|--log)
    shift
    logf "$@"
  ;;

  -n|--notif)
    shift
    notif "${@-}"
  ;;

  -p|--parse)
    shift
    parse_switches "$@"
  ;;

  -r|--readme)
    if [ .${2-} = .g ]; then
      edit $readMe g VIEW html
    else
      edit ${readMe%html}md
    fi
  ;;

  -R|--resetbs)
    resetbs
    echo "✅"
  ;;

  -sc)
    set_prop_ --current ${2-}
  ;;

  -sd)
    set_prop_ --print-default "${2-.*}"
  ;;

  -sl)
    set_prop_ --lang
  ;;

  -sp)
    set_prop_ --print "${2-.*}"
  ;;

  -sr)
    set_prop_ --reset "$@"
  ;;

  -ss)
    shift
    # rc21: two shorthands people kept asking for, both resolving to things ACC already does
    # but only through the app or a full path. Anything else falls through to the old behaviour
    # unchanged, so `acc -ss` and `acc -ss <switch spec>` are exactly what they were.
    case "${1-}" in
      f|find)
        # run the switch finder (AMPS), the same engine AccA's "Find my switch" calls
        shift
        _amps=
        for _a in $execDir/acc-compat.sh /data/adb/vr25/acc/acc-compat.sh \
                  /data/adb/modules/acc/acc-compat.sh; do
          [ -f "$_a" ] && { _amps=$_a; break; }
        done
        [ -n "$_amps" ] || { echo "AMPS engine not found (looked in $execDir and the module dir)" >&2; exit 3; }
        exec sh "$_amps" "$@"
      ;;
      # Match ANY digit-led argument, not just 1-2 digits. The old [0-9]|[0-9][0-9] pattern let a
      # 3+ digit index fall through to the *) arm below, which opens the interactive picker: on
      # both a Magisk and a KernelSU phone `acc -ss 111` and `acc -ss 1000` returned rc=0 having
      # silently taken that branch, so the out-of-range guard inside this arm was never reached.
      # Non-numeric input is still rejected by the guard immediately below.
      [0-9]*)
        # pick switch number N straight from the list `acc -ss::` prints. Same file, same sort,
        # same numbering, so what the user reads is what they can select. Setting it goes through
        # charging_switch=, not --charging_switch: the latter always opens the interactive picker
        # and ignores arguments, so it cannot be driven from a script.
        _swn=$1
        # Reject a selection that cannot exist BEFORE using it as a sed address. toybox sed
        # folds address 0 into 1, so `acc -ss 0` silently selected the FIRST switch and applied
        # it (measured on both Magisk and KernelSU: it wrote a real switch, and on Tensor it
        # also carried the " --" user-lock marker). The numbering the user reads from `acc -ss::`
        # starts at 1, so anything below that is a typo, not a choice.
        case "$_swn" in ''|*[!0-9]*) echo "Switch number must be a positive integer. 'acc -ss::' lists them." >&2; exit 3;; esac
        [ "$_swn" -ge 1 ] 2>/dev/null || { echo "No switch number $_swn. Numbering starts at 1; 'acc -ss::' lists them." >&2; exit 3; }
        _swf=$dataDir/logs/working-switches.log
        [ -s "$_swf" ] || { echo "No working switches recorded yet. Run 'acc -t' or Find my switch first." >&2; exit 3; }
        # Strip the class marker AND the {mcc}/{mcv}/{tl} support annotations that -ss:: shows.
        # Those are display only; leaving one in put "main/current_max 3000000 0 {mcc} --" into
        # the config, which the daemon cannot parse, so every cut failed with a total-switch
        # error. Removing braces rather than truncating to three fields keeps multi-node group
        # switches (the Pixel/Tensor multi-path cut is one entry listing several nodes) intact.
        _swline=$(sort "$_swf" 2>/dev/null | sed -n "${_swn}p" | sed -e 's/^\[.\] *//' -e 's/ *{[^}]*}//g' -e 's/ *$//')
        [ -n "$_swline" ] || { echo "No switch number $_swn. 'acc -ss::' lists them." >&2; exit 3; }
        if sw_blacklisted "${_swline%% *}"; then
          echo "Switch $_swn (${_swline%% *}) crashed this phone before and is blocked." >&2
          echo "Allow it again with: acc -sb rm ${_swline%% *}" >&2
          exit 3
        fi
        echo "Setting switch $_swn: $_swline"
        set_prop_ "charging_switch=$_swline --"
      ;;
      *)
        set_prop_ --charging_switch
      ;;
    esac
  ;;

  -ss:)
    set_prop_ --charging_switch:
  ;;

  -ss::)
    set_prop_ $1
  ;;

  -sv)
    shift
    set_prop_ --voltage "$@"
  ;;

  -s|--set)
    shift
    set_prop_ "$@"
  ;;


  -t*|--test*)

    # rc23: ignore SIGPIPE for the whole of `acc -t`, FIRST, before a single line is printed.
    # `acc -t | head`, or `acc -t | less` and pressing q, closes the pipe under us. Measured on a
    # Pixel 6a: the shell is killed outright and no trap runs at all. It has to be ignored here
    # rather than trapped later, because the killing write lands between stopping the daemon and
    # arming the restore -- see the trap below.
    # Ignored, not handled: a handler fires on EVERY failed write (measured at 120-164 times in one
    # run), where ignoring lets the script run to its end and fire the EXIT trap exactly once.
    trap '' PIPE

    parsed=
    daemonWasUp=false
    exitCode_=10
    exitCode=$exitCode_
    writeLog=$dataDir/logs/write.log
    logF_=$dataDir/logs/acc-t_output-${device}.log
    : ${logF:=/sdcard/Download/acc-t_output-${device}_$(date +%Y-%m-%d_%H-%M-%S).log}

    __STI=${1#-t}
    __STI=${__STI#--test}
    [ -z "$__STI" ] || _STI=$__STI

    shift
    [ "${1:-x}" != q ] || shift
    print_wait
    # rc23: only say this when it is true. It was printed unconditionally, so `acc -t` opened by
    # telling every user to plug in a charger that, in the overwhelming majority of runs, was
    # already plugged in -- and then the wait below could sit silently for minutes. Together that is
    # what "acc -t doesn't auto-advance" looked like from the outside: one piece of wrong advice,
    # then nothing. The check is the same absolute-path probe the wait uses, defined just below.
    _t_plugged() {
      local _pf= _pv=
      for _pf in /sys/class/power_supply/*/online /sys/class/power_supply/*/present; do
        [ -f "$_pf" ] || continue
        case "$_pf" in */battery/*|*/bms/*|*maxfg*|*fuelgauge*) continue;; esac
        _pv=; { read -r _pv < "$_pf"; } 2>/dev/null || continue
        [ "$_pv" = 1 ] && return 0
      done
      return 1
    }
    _t_plugged || print_unplugged

    # rc23: the restore is armed BEFORE the daemon is stopped, not after the test is set up.
    # It used to be armed about sixty lines later, so everything between `daemon_ctrl stop` and the
    # trap ran with the daemon already down and nothing registered to bring it back. `acc -t | head`
    # dies exactly in that window -- head takes its three lines, closes, and the next write kills a
    # shell that has stopped the daemon and armed nothing. Never stop the daemon without the way
    # back already in place.
    exxit() {
      trap - EXIT INT TERM HUP
      rm $TMPDIR/.testingsw 2>/dev/null || :
      if [ -n "$parsed" ]; then
        cat $TMPDIR/ch-switches $_parsed 2>/dev/null > $parsed \
          && awk '!seen[$0]++' $parsed | sed 's/ $//; /^$/d' > $TMPDIR/ch-switches
      fi
      cp -f $logF $logF_ 2>/dev/null
      # rc23: start-stop-daemon DOES NOT EXIST on Android. It is a Debian/busybox tool, and this
      # line returned 127 on both test phones -- so `acc -t` has never restored the daemon it
      # stopped, on any phone lacking it. The script then exits and the user is left uncapped with
      # no message. customize.sh and acca.sh already guard this call and fall back to a detached
      # setsid launch; this was the one place that called it bare.
      # Detached on purpose: a daemon left in this script's session dies when the script exits,
      # which is the same trap acca.sh documents for the switch scanner.
      if $daemonWasUp; then
        if command -v setsid >/dev/null 2>&1; then
          setsid $TMPDIR/.accdt </dev/null >/dev/null 2>&1 &
        elif command -v start-stop-daemon >/dev/null 2>&1; then
          start-stop-daemon -bx $TMPDIR/.accdt -S --
        else
          nohup $TMPDIR/.accdt </dev/null >/dev/null 2>&1 &
        fi
        # verify, because a silent failure here IS the bug
        _dw=0
        while [ $_dw -lt 15 ]; do
          pgrep -f accd.sh >/dev/null 2>&1 && break
          sleep 1; _dw=$((_dw+1))
        done
        pgrep -f accd.sh >/dev/null 2>&1           || printf '
! The ACC daemon did not come back -- charging is currently UNCAPPED.
  Run: acc -D restart
' >&2
      fi
      [ -n "${lastNode-}" ] && sed -i "\|^#${lastNode}$|s|^#||" $writeLog
      exit $exitCode
    }
    trap exxit EXIT INT TERM HUP

    ! daemon_ctrl stop > /dev/null && daemonWasUp=false || {
      daemonWasUp=true
      echo "#!/system/bin/sh
        sleep 2
        exec $TMPDIR/accd $config" > $TMPDIR/.accdt
      chmod 0755 $TMPDIR/.accdt
    }

    . $execDir/acquire-lock.sh

    grep -Ev '^$|^#' $config > $TMPDIR/.config
    config=$TMPDIR/.config


    set +e
    echo $$ > $TMPDIR/.testingsw 2>/dev/null || touch $TMPDIR/.testingsw
    not_charging && enable_charging > /dev/null

    not_charging && {
      # rc23: this printed "Ensure the charger is plugged" once and then spun on not_charging every
      # second, forever -- no timeout, no further output, no way out but Ctrl-C. Reported as
      # "acc -t doesn't auto-advance".
      #
      # not_charging is status-based, and a phone sitting AT its charge limit reads "Not charging"
      # and keeps reading it until the pack drains to the resume level. On a firmware-limit phone
      # that is hours. So the user got one line of advice that was also wrong -- the charger IS
      # plugged in -- from a command that then looked hung.
      #
      # Say which of the two situations it actually is, keep saying it, and stop eventually.
      # _t_plugged is defined above, next to the opening message it also gates. Absolute paths on
      # purpose: present() resolves its node list against the daemon's working directory, and
      # `acc -t` does not set one, so calling it here reported "not plugged" on a phone that was
      # plugged in -- printing the one message this fix exists to stop printing.
      _tw=0; _twmax=${ACC_T_WAIT:-180}
      # rc23e: ask with the kernel-status tie-break SUPPRESSED, or this guard does not hold.
      #
      # `acc -t` stops the daemon before it gets here, so in this process chDisabledByAcc is false and
      # $flip is empty - both suppressors of the promotion in idle_discharging are off. A phone whose
      # status node still reads "Charging" after its input collapsed (they do not follow a collapsed
      # contract) therefore gets promoted to Charging, not_charging answers "it is charging", and this
      # loop never runs.
      #
      # What that costs, measured on a Mi A3 whose contract had dropped to the 500mA SDP floor:
      #     4b ran 26s: works 3 rejected 0 ... voltage_max left at 3600000 ... daemon DEAD
      # Every candidate "works" because the test asks whether charging STOPPED, and it had already
      # stopped - so a voltage node was recorded as working and left applied at 3600mV, which does not
      # pause charging, it ends it, at every level and across reboots.
      #
      # `flip=off` makes not_charging judge on the current sign alone, which is the honest question
      # here: is this pack actually taking current. Same idiom, and same reason, as the confirmation
      # in disable_charging. A phone that IS charging still reads Charging from its sign and falls
      # straight through, so nothing is slower for the case that works.
      while { flip=off; not_charging; }; do
        if [ "$_tw" = 0 ]; then
          if _t_plugged; then
            printf "Charger is plugged in, but the battery is not taking charge.\n"
            printf "If you are at or above your charge limit, raise it (or let the battery drain a little) so the test has something to measure.\n\n"
          else
            print_unplugged
          fi
        elif [ "$(( _tw % 15 ))" = 0 ]; then
          printf "  still waiting for charging to start (%ss of %ss)... Ctrl-C to abort.\n" "$_tw" "$_twmax"
        fi
        if [ "$_tw" -ge "$_twmax" ] 2>/dev/null; then
          printf "\nGiving up after %ss: charging never started, so there is nothing to test.\n" "$_tw"
          printf "Raise your charge limit above the current level, or plug in a working charger, then run this again.\n"
          exit $exitCode_
        fi
        sleep 1
        _tw=$(( _tw + 1 ))
        set +x
      done
      eval "${_logOn:-:}"
    }

    . $execDir/read-ch-curr-ctrl-files-p2.sh
    echo
    echo _STI=$_STI
    { echo versionCode=$(sed -n s/versionCode=//p $execDir/module.prop 2>/dev/null || :)
    echo
    grep . */online
    echo
    grep '^chargingSwitch=' $config; } | tee $logF

    if [ -z "${2-}" ]; then
      !  eq "${1-}" "p|parse" || parsed=$TMPDIR/.parsed
      if [ -z "$parsed" ]; then
        rm $dataDir/logs/working-switches.log 2>/dev/null || :
      else
        _parsed=$dataDir/logs/parsed.log
        if parse_switches > $parsed; then
          set -- $parsed
          ! ${verbose:-true} || {
            print_panic
            read -n 1 a
            echo
            case "$a" in
              ""|y) edit $parsed;;
              a) exit;;
            esac
          }
        else
          echo
          exit
        fi
      fi
      swCount=1
      swTotal=$(wc -l ${1-$TMPDIR/ch-switches} | cut -d ' ' -f 1)
      awk '!seen[$0]++' $TMPDIR/ch-switches > $TMPDIR/ch-switches_
      mv -f $TMPDIR/ch-switches_ $TMPDIR/ch-switches
      while read _chargingSwitch; do
        echo "x$_chargingSwitch" | grep -Eq '^x$|^x#' && continue
        # rc21: honour the crash blacklist. -t WRITES every candidate to see which one holds,
        # so without this it re-tests the exact node that already took the phone down, on a list
        # AMPS refuses to touch for that reason. Skipped loudly, and `acc -sb rm <node>` re-allows.
        if sw_blacklisted "$(echo "$_chargingSwitch" | cut -d ' ' -f 1)"; then
          echo "skipped (crashed this phone before): $_chargingSwitch" | tee -a $logF
          continue
        fi
        [ -f "$(echo "$_chargingSwitch" | cut -d ' ' -f 1)" ] && {
          { test_charging_switch $_chargingSwitch; echo $? > $TMPDIR/.exitCode; } | tee -a $logF
          rm $TMPDIR/.sw 2>/dev/null || :
          swCount=$((swCount + 1))
          exitCode_=$(cat $TMPDIR/.exitCode)
          if [ -n "$parsed" ] && [ $exitCode_ -ne 10 ]; then
            grep -q "^$_chargingSwitch$" $_parsed 2>/dev/null \
              || echo "$_chargingSwitch" >> $_parsed
          fi
          case $exitCode in
            15) ;;
            0) [ $exitCode_ -eq 15 ] && exitCode=15;;
            *) exitCode=$exitCode_;;
          esac
        }
      done < ${1-$TMPDIR/ch-switches}
      echo
    else
      { test_charging_switch "$@"; echo $? > $TMPDIR/.exitCode; } | tee -a $logF
      rm $TMPDIR/.sw 2>/dev/null || :
      exitCode=$(cat $TMPDIR/.exitCode)
      echo
    fi

    print_acct_info
    echo
    exit $exitCode
  ;;


  -T|--logtail)
    arg="${2-}"
    arg="${arg//,/|}"
    tail -F $TMPDIR/accd-*.log | grep -E "${arg:-.}"
  ;;

  -u|--upgrade)
    shift
    array[0]=
    reference=

    for i; do
      array+=("$i")
      case "$i" in
        -c|--changelog)
        ;;
        -f|--force)
        ;;
        -n|--non-interactive)
        ;;
        *)
          unset array[$((${#array[@]}-1))]
          reference="$i"
        ;;
      esac
    done
    test ${#array[@]} -lt 2 || unset array[0]

    test -n "$reference" || {
      grep -Eq '^version=.*-(beta|dev|rc)' $execDir/module.prop \
        && reference=dev \
        || reference=master
    }

    ! test -f /data/adb/vr25/bin/curl || {
      test -x /data/adb/vr25/bin/curl \
        || chmod -R 0755 /data/adb/vr25/bin
    }

    dl() {
      if [ ".${1-}" != .wget ] && i=$(which curl) && [ ".$(head -n 1 ${i:-//} 2>/dev/null || :)" != ".#!/system/bin/sh" ]; then
        curl --help | grep '\-\-dns\-servers' >/dev/null && dns="--dns-servers 9.9.9.9,1.1.1.1" || dns=
        curl $dns --progress-bar --insecure -Lo \
          $TMPDIR/install-online.sh https://raw.githubusercontent.com/seyedehsanhadi/acc/dev/install-online.sh || dl wget
      else
        PATH=${PATH#*/busybox:} /dev/.vr25/busybox/wget -O $TMPDIR/install-online.sh --no-check-certificate \
          https://raw.githubusercontent.com/seyedehsanhadi/acc/dev/install-online.sh
      fi
    }

    dl
    trap - EXIT
    set +eu
    installDir=$(readlink -f $execDir)
    installDir=${installDir%/*}
    . $TMPDIR/install-online.sh "${array[@]}" %$installDir% $reference
  ;;

  -U|--uninstall)
    set +eu
    # rc21: "a" answers the prompt up front, for a phone with no usable console. The prompt
    # reads from stdin, so over `su -c` or from a front-end with nothing attached it sees EOF,
    # takes that as "not yes", and exits 0 having removed nothing while looking like it worked.
    [ ".${2-}" = .a ] && verbose=false || :
    ! ${verbose:-true} || {
      print_uninstall
      echo yes/no
      read ans
      [ .$ans = .yes ] || exit 0
    }
    /system/bin/sh $execDir/uninstall.sh
    echo "✅"
  ;;

  -v|--version)
    echo "$accVer ($accVerCode)"
  ;;

  -w*|--watch*)
    two="${2//,/|}"
    sleepSeconds=${1#*h}
    sleepSeconds=${sleepSeconds#*w}
    : ${sleepSeconds:=1}
    . $execDir/batt-info.sh
    while :; do
      clear
      if ${verbose:-true}; then
        batt_info "${two-}"
      else
        batt_info "${two-}" | grep -v '^$' 2>/dev/null || :
      fi
      sleep $sleepSeconds
      set +x
    done
  ;;

  -E|--export)
    [ -n "${2-}" ] || { echo "Usage: acc --export <file>"; exit 2; }
    cat $config > "$2" 2>/dev/null \
      && echo "✅ $2" \
      || { echo "Could not write $2"; exit 1; }
  ;;

  # rc21: the ONE diagnostic. Passive, read-only collector -> a single shareable .tgz with everything
  # needed to debug any problem (identity, config, live state, ACC's own logs, plus Android's own free
  # 24/7 logs: logcat, pstore/panic, DropBox crash/anr, tombstones, ANR, thermal, bootreason) + a
  # manifest of what was/wasn't captured. Nothing runs in the background; this only executes on demand.
  # `--diag --sample` adds a 20s live read. Both CLI users and AccA call the same collector.
  --diag|--diagnostics|-G)
    shift
    /system/bin/sh $execDir/diag-collect.sh "$@"
  ;;

  # rc21: opt-in verbose capture, for the rare intermittent bug a single snapshot misses. DEFAULT is
  # off (fully zero-background). Arming does NOT touch the daemon loop -- that would cost idle battery,
  # which we refuse -- it only tells the next on-demand `acc --diag` to include a live sample. It
  # auto-expires so it can never be left on by accident.
  --diag-verbose)
    shift
    _vf=$dataDir/.diag-verbose-armed
    case "${1:-}" in
      on|On|ON)
        _hrs=${2:-24}; case "$_hrs" in ''|*[!0-9]*) _hrs=24 ;; esac
        echo "$(date +%s 2>/dev/null || echo 0) $_hrs armed $(date 2>/dev/null)" > $_vf 2>/dev/null
        echo "verbose capture ARMED for ${_hrs}h. The next 'acc --diag' will include a live sample."
        echo "(daemon unchanged -- zero extra battery; this only affects the on-demand collect.)"
      ;;
      off|Off|OFF)
        rm -f $_vf 2>/dev/null; echo "verbose capture disarmed."
      ;;
      *)
        [ -f $_vf ] && echo "verbose capture: ARMED ($(cat $_vf 2>/dev/null))" || echo "verbose capture: off"
        echo "usage: acc --diag-verbose on [hours] | off"
      ;;
    esac
  ;;

  # Line 346 shifts a leading config path away before this case runs, so */* is
  # not normally reachable; it is kept so that any path-shaped argument which
  # does reach here prints help rather than being called a typo.
  -h|--help|help|*/*)
    . $execDir/print-help.sh
    shift
    print_help_ "$@"
  ;;

  # Anything else is a typo. rc20 and earlier printed help and still exited 0,
  # so a front-end or macro could not tell a mistyped command from a successful
  # one; that is how "acca config --export" looked like it had worked. The
  # message goes to stderr because help floods stdout right after it.
  *)
    _bad=$1
    echo "Unknown command: $_bad" >&2
    . $execDir/print-help.sh
    shift
    print_help_ "$@"
    echo "Unknown command: $_bad. Run 'acc --help' for the command list." >&2
    exit 2
  ;;

esac

exit 0
