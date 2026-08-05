#!/system/bin/sh
IF=/dev/.vr25/acc/.batt-interface.sh
U=/sys/class/power_supply/usb
B=/sys/class/power_supply/battery
G=$B; [ -r /sys/class/power_supply/maxfg/capacity ] && G=/sys/class/power_supply/maxfg
# online alone is not "is a cable attached": an input-cut switch, or a charger delivering nothing,
# holds online=0 with the cable still in. present is what says a cable exists, and the unplugged
# gate keys on present -- so report both or the two tools disagree about the same phone.
plug=no; cable=no
for f in /sys/class/power_supply/*/online; do [ "$(cat $f 2>/dev/null)" = 1 ] && plug=yes; done
for f in /sys/class/power_supply/*/present; do
  case "$f" in */battery/*|*/bms/*|*/maxfg/*|*fuelgauge*) continue;; esac
  [ "$(cat $f 2>/dev/null)" = 1 ] && cable=yes
done
icl=$(cat $U/current_max 2>/dev/null); case "${icl:-x}" in ''|*[!0-9]*) icl=0;; esac
if [ "$plug" = no ] && [ "$cable" = no ]; then cond=unplugged
elif [ "$plug" = no ]; then cond=cable-attached-no-power
elif [ "$icl" -ge 1500000 ]; then cond=fast
elif [ "$icl" -gt 0 ]; then cond=slow
else cond=plugged-but-no-input; fi
echo "$(getprop ro.product.device): cond=$cond cache=$([ -f $IF ] && wc -l < $IF || echo 0)lines acc-i=[$(acc -i 2>/dev/null | sed -n 's/^status //p' | head -1)] level=$(cat $G/capacity) kernel=$(cat $B/status) icl=$icl cable=$cable"
