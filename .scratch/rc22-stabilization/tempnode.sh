#!/system/bin/sh
IF=/dev/.vr25/acc/.batt-interface.sh
echo "ACC's resolved temp node : $(sed -n 's/^temp=//p' $IF 2>/dev/null)"
echo "ACC's resolved gauge     : $(sed -n 's/^battCapacity=//p' $IF 2>/dev/null)"
for n in /sys/class/power_supply/battery/temp /sys/class/power_supply/maxfg/temp; do
  [ -r "$n" ] && echo "  $n = $(cat $n) ($(( $(cat $n) / 10 ))C)" || echo "  $n = unreadable"
done
echo "kernel status(battery) = $(cat /sys/class/power_supply/battery/status)"
echo "kernel status(maxfg)   = $(cat /sys/class/power_supply/maxfg/status 2>/dev/null)"
echo "level(battery)=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null) level(maxfg)=$(cat /sys/class/power_supply/maxfg/capacity 2>/dev/null)"
echo "ibat=$(cat /sys/class/power_supply/battery/current_now) icl=$(cat /sys/class/power_supply/usb/current_max)"
echo "acc -i status=[$(acc -i 2>/dev/null | sed -n 's/^status //p' | head -1)]"
