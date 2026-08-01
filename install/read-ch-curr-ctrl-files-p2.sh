# read charging current control files (part 2)
#   once and while charging only
#   otherwise, most values would be zero (wrong)

(set +e

currCtrl=$TMPDIR/ch-curr-ctrl-files

if [ ! -f $TMPDIR/.mcc-read ]; then

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
