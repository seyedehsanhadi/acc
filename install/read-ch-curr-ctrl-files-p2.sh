# read charging current control files (part 2)
#   once and while charging only
#   otherwise, most values would be zero (wrong)

(set +e

# ls_curr_ctrl_files is almost entirely RELATIVE globs (*/current_max, */constant_charge_current*),
# so this file only resolves anything when the caller happens to be sitting in power_supply. Every
# current caller does happen to be -- the daemon's cwd is /sys/class/power_supply, verified live on
# two phones -- so this is robustness, not a bug fix: a sourced helper should not depend on where
# its caller stood. Measured from / it finds 0 nodes on a Pixel 6a and 1 on a Mi A3 (that one being
# its single ABSOLUTE candidate, /sys/class/qcom-battery/restrict_cur, which resolves anywhere).
#
# Safe because everything below runs inside this subshell, so the caller's cwd is untouched, and
# every write here targets $TMPDIR by absolute path.
cd /sys/class/power_supply 2>/dev/null || exit 0

currCtrl=$TMPDIR/ch-curr-ctrl-files

# Tensor/Google: prefer the charger's real FCC election over power_supply mirrors that acknowledge
# a write and then snap back. The marker keeps the ordinary mA->uA expansion machinery intact;
# apply_on_plug resolves this synthetic entry through the independent DEBUGFS gvotable ballot.
if command -v msc_fcc_init >/dev/null 2>&1 && msc_fcc_init; then
  echo 'gvotable/MSC_FCC::v000::-1' > "$currCtrl"
  touch "$TMPDIR/.mcc-read"
  exit 0
fi

# ...and never while a CURRENT cap is applied, for the same reason the voltage side now guards:
# every entry ends in the node's DEFAULT, taken as whatever it reads right now. Re-record that while
# a cap is in force and the cap becomes the default, so releasing it writes the cap straight back.
# Measured on a Mi A3 whose voltage snapshot was poisoned exactly this way, leaving two of three
# nodes pinned at the test cap with a config that read "no limit".
#
# Read from the CONFIG FILE, not the in-memory array. This runs at daemon init, before the config is
# sourced, so the array is still empty here and an array test never fires -- measured: the guard was
# in place and the snapshot was poisoned anyway. The file is the authority at this point.
# The CANONICAL config path, not $config. By this point $config can be the daemon's own
  # stripped tmpfs copy from a previous exit, which predates the cap the user just set -- so
  # the guard read an empty value and stood down exactly when it was needed.
  _capcfg=$(sed -n 's/^maxChargingCurrent=(//p' ${config:-} 2>/dev/null | cut -d' ' -f1 | tr -d ')')
  # $config can be the daemon's own stripped tmpfs copy from a previous exit, which predates the
  # cap the user just set -- so fall through to the canonical file rather than read an empty
  # value and stand down exactly when the guard is needed. Trying $config first keeps this
  # drivable from a fixture.
  [ -n "${_capcfg:-}" ] || _capcfg=$(sed -n 's/^maxChargingCurrent=(//p' /data/adb/vr25/acc-data/config.txt 2>/dev/null | cut -d' ' -f1 | tr -d ')')
if [ -n "${_capcfg:-}" ] && [ -s $TMPDIR/ch-curr-ctrl-files ]; then
  :
elif [ ! -f $TMPDIR/.mcc-read ]; then

  # Keep the outgoing snapshot; the merge at the end of this block never lets a default go DOWN.
  [ ! -f $currCtrl ] || cp -f $currCtrl ${currCtrl}.prev 2>/dev/null || :
  rm $currCtrl ${currCtrl}_ 2>/dev/null || :
  . $execDir/ctrl-files.sh
  plugins=/data/adb/vr25/acc-data/plugins
  [ -f $plugins/ctrl-files.sh ] && . $plugins/ctrl-files.sh

  ls -1 $(ls_curr_ctrl_files | grep -Ev '^#|^$') 2>/dev/null | \
    while read file; do
      chmod a+r $file || continue
      defaultValue="$(cat $file 2>/dev/null)" || continue
      case "$defaultValue" in
        ""|-*|*" "*|[01]|*[a-zA-Z]*) continue;;
        [1-9]*)
          # rc(6.4): unit cutoff unified to 16000 to MATCH batt-interface.sh (was 10000 here,
          # 16000 there -> in the 10000-15999 band one read it as uA and the other as mA, a
          # 1000x current misclassification). Real uA charge currents are >=~100000 and real
          # mA are <=~9999, so the 10000-15999 gap is treated as mA everywhere.
          if [ "$defaultValue" -lt 16000 ]; then
            # milliamps
            echo ${file}::v::$defaultValue >> ${currCtrl}_
          else
            # microamps
            echo ${file}::v000::$defaultValue >> ${currCtrl}_
          fi;;
      esac
    done

  if [ -f ${currCtrl}_ ]; then
    # exclude troublesome ctrl files
    #
    # rc21 (field report, Redmi Note 10 Pro / sweet -- "battery is draining rather than
    # charging"): *_now is dropped HERE, not only from the switch list below. Under the
    # power_supply ABI a *_now node is an instantaneous meter reading, never a setting, so the
    # "default" captured for one is just whatever current happened to be flowing when the list
    # was built. Every later apply_on_plug pass writes that stale number back over the live
    # input: the reporter's ledger shows `usb/input_current_now <- 41845 (was 1787735)` next to
    # `usb/current_max <- 50000 (was 1800000)`, i.e. the charger input pinned near 50 mA while
    # plugged in. The phone then draws more than it receives and the battery falls with the
    # cable attached, which is exactly what was reported, and ACC's own sweep spent the next
    # hour re-enabling a charger that its own leftover cap was starving.
    #
    # The earlier fix excluded these from the SWITCH list only and deliberately left the
    # current-control list alone "so the charging-current limit behaves as before". That was
    # the wrong half: a meter node cannot control current on any device, so keeping it here
    # bought no capability and cost this phone its charge. Excluding it costs nothing real --
    # the genuine settables (*current_max, *input_current_settled, *constant_charge_current)
    # are untouched.
    sort -u ${currCtrl}_ \
      | grep -Eiv 'parallel|::-|bq[0-9].*/current_max' \
      | grep -v '_now::' > $TMPDIR/.ctrl

    # exclude non-batt control files
    $currentWorkaround \
      && grep -i batt $TMPDIR/.ctrl > ${currCtrl} \
      || cat $TMPDIR/.ctrl > ${currCtrl}

    # A DEFAULT MUST NEVER GO DOWN.
    #
    # Guarding on "is a cap configured" is not enough, and two runs proved it. The poisoning window
    # is the moment just AFTER a clear: the config already reads () so the guard correctly stands
    # down, the daemon restarts, and discovery reads nodes that are still holding the cap because
    # the release has not landed yet. It records the cap as the default, and from then on "restore
    # to default" writes the cap back forever. Measured on a Mi A3:
    #     battery/constant_charge_current::v000::1260000   <- the test cap
    #     usb/current_max::v000::1450000                   <- a mid-release reading
    #
    # ACC only ever caps DOWNWARD, so for any node the highest value ever observed is the best
    # estimate of its unconstrained ceiling. Merging on max makes the snapshot monotonic: a reading
    # taken while capped can no longer overwrite a good one, and an already-poisoned entry heals the
    # first time that node is seen uncapped.
    if [ -f ${currCtrl}.prev ] && [ -s ${currCtrl} ]; then
      awk -F'::' '
        NR==FNR { if ($1 != "") { if (!($1 in d) || $3+0 > d[$1]+0) d[$1]=$3 } ; next }
        { if ($1 in d && d[$1]+0 > $3+0) print $1"::"$2"::"d[$1]; else print $0 }
      ' ${currCtrl}.prev ${currCtrl} > ${currCtrl}.m 2>/dev/null \
        && [ -s ${currCtrl}.m ] && mv -f ${currCtrl}.m ${currCtrl} 2>/dev/null || :
    fi
    rm -f ${currCtrl}.prev ${currCtrl}.m 2>/dev/null || :

    # add curr and volt ctrl files to charging switches list
    #
    # rc21: a *_now node is a live meter under the power_supply ABI, never a setting, so it
    # must not become a charging-switch candidate. The "on" value recorded for one is just
    # whatever current happened to be flowing when the list was built, and every later sweep
    # re-asserts that stale reading onto the charger input: a reported Redmi Note 9S carried
    # `usb/input_current_now 602075 0` and had 0.6 A pinned back over its live value, which
    # upstream never does because it has no such list. filter_sw refuses these, but this append
    # writes to ch-switches directly and never passes through it.
    # Deliberately scoped to the SWITCH list: ${currCtrl} above keeps exactly what it had, so
    # the charging-current limit and its reject-backoff behave as before on every device.
    grep -v '_now::' $TMPDIR/.ctrl > $TMPDIR/.ctrl-sw 2>/dev/null || :
    sed -e 's/::.*::/ /' -e 's/$/ 0/' $TMPDIR/.ctrl-sw >> $TMPDIR/ch-switches
    sed -E 's/(.*)(::v.*::)(.*)/\1 \3 \2/; s/::v/10/; s/:://' $TMPDIR/.ctrl-sw >> $TMPDIR/ch-switches
    sed -Ee 's/::.*::/ /' -e 's/([0-9])$/\1 3600mV/' $TMPDIR/ch-volt-ctrl-files >> $TMPDIR/ch-switches

    cat $TMPDIR/ch-switches > $TMPDIR/.ctrl
    grep / $TMPDIR/.ctrl | awk '!seen[$0]++' > $TMPDIR/ch-switches
  fi
fi

rm ${currCtrl}_ $TMPDIR/.ctrl 2>/dev/null
touch $TMPDIR/.mcc-read) || :
