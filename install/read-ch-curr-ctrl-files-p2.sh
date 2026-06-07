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
    sort -u ${currCtrl}_ \
      | grep -Eiv 'parallel|::-|bq[0-9].*/current_max' > $TMPDIR/.ctrl

    # exclude non-batt control files
    $currentWorkaround \
      && grep -i batt $TMPDIR/.ctrl > ${currCtrl} \
      || cat $TMPDIR/.ctrl > ${currCtrl}

    # add curr and volt ctrl files to charging switches list
    sed -e 's/::.*::/ /' -e 's/$/ 0/' $TMPDIR/.ctrl >> $TMPDIR/ch-switches
    sed -E 's/(.*)(::v.*::)(.*)/\1 \3 \2/; s/::v/10/; s/:://' $TMPDIR/.ctrl >> $TMPDIR/ch-switches
    sed -Ee 's/::.*::/ /' -e 's/([0-9])$/\1 3600mV/' $TMPDIR/ch-volt-ctrl-files >> $TMPDIR/ch-switches

    cat $TMPDIR/ch-switches > $TMPDIR/.ctrl
    grep / $TMPDIR/.ctrl | awk '!seen[$0]++' > $TMPDIR/ch-switches
  fi
fi

rm ${currCtrl}_ $TMPDIR/.ctrl 2>/dev/null
touch $TMPDIR/.mcc-read) || :
