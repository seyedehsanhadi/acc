logf() {

  local date=$(date +%Y-%m-%d_%H-%M-%S)

  if [[ "${1:-x}" = -*e* ]]; then

    mkdir -p $dataDir/logs

    exec 2>> ${log:-/dev/null}
    mkdir -p $TMPDIR/.logf
    cd $TMPDIR/.logf
    set +e

    dmesg > dmesg.log
    logcat -d *:D > logcat.log
    $execDir/power-supply-logger.sh
    { parse_switches 2>/dev/null || $TMPDIR/acca $config --parse; } > acc-p.txt

    { ln -f ../ch-switches charging-switches.txt
    ln -f ../oem-custom oem-custom.txt
    ln -f ../ch-curr-ctrl-files charging-current-ctrl-files.txt
    ln -f ../ch-volt-ctrl-files charging-voltage-ctrl-files.txt; } 2>/dev/null

    for file in /cache/magisk.log /data/cache/magisk.log; do
      [ -f $file ] && ln -sf $file ./ && break
    done

    ln -sf $dataDir/logs/* ./ 2>/dev/null
    cat $config_ > ./config.txt
    set +x

    . $execDir/batt-info.sh
    (cd /sys/class/power_supply/
    batt_info > $TMPDIR/.logf/acc-i.txt)
    dsys_batt > dumpsys-battery.txt
    ln -f ../*.txt ../*.log ./ 2>/dev/null

    tar -hc *.log *.txt | gzip -9 > $dataDir/logs/acc-logs-$device.tgz
    rm -rf $TMPDIR/.logf 2>/dev/null

    cp -f $dataDir/logs/acc-logs-$device.tgz /sdcard/Download/acc-logs-${device}_${date}.tgz 2>/dev/null \
      && echo /sdcard/Download/acc-logs-${device}_${date}.tgz \
      || echo $dataDir/logs/acc-logs-$device.tgz

  else
    if [[ "${1:-x}" = -*a* ]]; then
      shift
      edit $log "$@"
    else
      edit $TMPDIR/accd-*.log "$@"
    fi
  fi
}
