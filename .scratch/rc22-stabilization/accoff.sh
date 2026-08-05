#!/system/bin/sh
# Is ACC responsible for this phone sitting at 5V? Stop it and see.
U=/sys/class/power_supply/usb
B=/sys/class/power_supply/battery
row(){ printf '%-12s vbus=%-8s icl=%-9s cur=%-10s type=%-14s level=%s temp=%s\n' "$1" \
  "$(cat $U/voltage_now)" "$(cat $U/current_max)" "$(cat $B/current_now)" \
  "$(cat $U/real_type)" "$(cat $B/capacity)" "$(cat $B/temp)"; }
echo "=== ACC RUNNING ==="
i=0; while [ $i -lt 60 ]; do row "acc-on+${i}s"; i=$((i+20)); sleep 20; done
echo "=== stopping ACC ==="
acc -D stop >/dev/null 2>&1
sleep 5
echo "daemon: $(cat /dev/.vr25/acc/acc.lock 2>/dev/null) alive=$([ -d /proc/$(cat /dev/.vr25/acc/acc.lock 2>/dev/null) ] && echo yes || echo NO)"
i=0; while [ $i -lt 120 ]; do row "acc-off+${i}s"; i=$((i+20)); sleep 20; done
echo "=== dmesg during the ACC-off window ==="
dmesg 2>/dev/null | grep -iE "USB_ICL|hvdcp|dp_dm|thermal" | tail -10
echo "=== restarting ACC ==="
acc -D restart >/dev/null 2>&1 &
sleep 40
row "acc-back"
echo "daemon alive=$([ -d /proc/$(cat /dev/.vr25/acc/acc.lock 2>/dev/null) ] && echo yes || echo NO)"
