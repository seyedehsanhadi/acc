batt_info() {

  local i=
  local info=
  local voltNow_=
  local currNow=
  local powerNow=
  local factor=
  local one="${1//,/|}"
  set +eu


  # calculator
  calc2() {
    awk "BEGIN {print $*}" | tr , . | xargs printf %.2f
  }


  dtr_conv_factor() {
    factor=${2-}
    if [ -z "$factor" ]; then
      case $1 in
        0) factor=1;;
        *) [ $1 -lt 16000 ] && factor=1000 || factor=1000000;;
      esac
    fi
  }


  not_charging || :


  # raw battery info from the kernel's battery interface
  info="$(
    { grep . $battCapacity $battStatus $currFile $temp $voltNow 2>/dev/null || :; } \
      | sed "s|.*/||; s/:/ /; s/^batt_vol/voltage_now/; s/^batt_temp/temp/;
        s/^status .*/status $_status/; s/batteryaveragecurrent/current_now/;
        s/^capacity .*/level $(capacity[4]=false batt_cap)%/; s/^temp .*/temp $(($(cat $temp) / 10))℃/" | sort
  )"


  # parse CURRENT_NOW & convert to Amps
  currNow=$(echo "$info" | sed -n "s/^current_now //p")
  dtr_conv_factor ${currNow#-} ${ampFactor:-$ampFactor_}
  currNow=$(calc2 ${currNow:-0} / $factor)


  # parse VOLTAGE_NOW & convert to Volts
  voltNow_=$(echo "$info" | sed -n "s/^voltage_now //p")
  dtr_conv_factor $voltNow_ ${voltFactor-}
  voltNow_=$(calc2 ${voltNow_:-0} / $factor)


  # calculate POWER_NOW (Watts)
  powerNow=$(calc2 $currNow \* $voltNow_)


  {
    # print raw battery info
    echo "$info" | grep -Ev '^(current|voltage)_now '

    # print current_now, voltage_now and power_now
    echo "
current_now ${currNow}A
voltage_now ${voltNow_}V
power_now ${powerNow}W"


  # power supply info
  for i in $(online_f); do
    if [ -f $i ] && [ $(cat $i) -eq 1 ]; then
      i=${i%/*}
      power_supply_type=$(cat $i/real_type 2>/dev/null || echo $i)

      echo "
charge_type $power_supply_type"

      psaRaw=$(cat $i/*current_now 2>/dev/null | tail -n 1)
      dtr_conv_factor ${psaRaw#-} ${ampFactor:-$ampFactor_}
      power_supply_amps=$(calc2 ${psaRaw:-0} / $factor)

      if [ 0${power_supply_amps%.*} -gt 0 ]; then
        psvRaw=$(cat $i/voltage_now 2>/dev/null)
        dtr_conv_factor ${psvRaw:-0} ${voltFactor-}
        power_supply_volts=$(calc2 ${psvRaw:-0} / $factor)
        power_supply_watts=$(calc2 $power_supply_amps \* $power_supply_volts)
        consumed_watts=$(calc2 $power_supply_watts - $powerNow)

        echo "power_supply_amps $power_supply_amps
power_supply_volts $power_supply_volts
power_supply_watts $power_supply_watts
consumed_watts $consumed_watts"
      fi

      break
    fi
  done 2>/dev/null || :


  # online status (for debugging)
  echo
  grep . */online | sed -E 's/:(.)$/ \1/'

  ! ${capacity[4]} || {
    echo
    echo real_level $(cat $battCapacity)%
  }

  } | grep -Ei "${one:-.*}" || :
}
