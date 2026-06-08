_grep() { grep -Eq "$1" ${2:-$config}; }
_set_prop() { sed -i "\|^${1}=|s|=.*|=$2|" ${3:-$config}; }
_get_prop() { sed -n "\|^$1=|s|.*=||p" ${2:-$config} 2>/dev/null || :; }
_is_board() { getprop ro.product.board | grep -Eiq "$1"; }

# patch/reset [broken/obsolete] config
if (set +x; . $config) >/dev/null 2>&1; then
  configVer=0$(_get_prop configVerCode)
  defaultConfVer=0$(cat $TMPDIR/.config-ver)
  [ $configVer -eq $defaultConfVer ] || {
    # if [ $configVer -lt 202404070 ]; then
    #   $TMPDIR/acca $config --set thermal_suspend=
    # else
      $TMPDIR/acca $config --set dummy=
    # fi
  }
else
  cat $execDir/default-config.txt > $config
fi

# battery idle mode for OnePlus devices
! _grep '^chargingSwitch=.battery/op_disable_charge 0 1 battery/input_suspend 0 0.$' \
  || loopCmd='[ $(cat battery/input_suspend) != 1 ] || echo 0 > battery/input_suspend'

# battery idle mode for Google Pixel 2/XL and devices with similar hardware
! _grep '^chargingSwitch=./sys/module/lge_battery/parameters/charge_stop_level' \
  || loopCmd='[ $(cat battery/input_suspend) != 1 ] || echo 0 > battery/input_suspend'

# idle mode - sony xperia: enable the firmware smart-charging gate ONLY when the Sony
# charge-interruption node actually exists (rc(6.4): was unconditional every accd init, which
# could enable a competing firmware charge manager on any non-Sony device exposing the node).
[ -e battery_ext/smart_charging_interruption ] && echo 1 > battery_ext/smart_charging_activation 2>/dev/null || :

# mt6795, exclude ChargerEnable switches (troublesome)
! getprop | grep '\[mt6795\]' > /dev/null || {
  ! _grep ChargerEnable $execDir/ctrl-files.sh || {
    sed -i /ChargerEnable/d $TMPDIR/ch-switches
    sed -i /ChargerEnable/d $execDir/ctrl-files.sh
  }
}

# prevent "ghost charging" (MSM8916)
! _is_board '^MSM8916$' || touch $TMPDIR/.ghost-charging

# devices that report wrong current; disable current-based status detection
! _is_board '^(msm8937|CRO-L03)$' || {
  [ .$(_get_prop battStatusWorkaround) = .false ] \
    || $TMPDIR/acca $config --set batt_status_workaround=false
}

# avoid unexpected reboots
! _is_board '^CRO-L03$' || sed -i /current_cmd/d $TMPDIR/ch-switches

# msm8953 (e.g., Moto Z Play)
! _is_board msm8953 || {
  _get_prop chargingSwitch | grep 'battery/charging_enabled 1 0 \-\-' >/dev/null \
    || $TMPDIR/acca $config --set charging_switch="battery/charging_enabled 1 0 --"
}

unset -f _grep _get_prop _is_board _set_prop
unset configVer defaultConfVer
