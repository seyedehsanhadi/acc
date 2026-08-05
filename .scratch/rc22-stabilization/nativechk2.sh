#!/system/bin/sh
G=/sys/devices/platform/google,charger
C=/data/adb/vr25/acc-data/config.txt
L=/sys/class/power_supply/maxfg/capacity
row(){ printf '%-5s stop=%-4s start=%-4s cfg=%-22s level=%-3s kernel=%s\n' "$1" "$(cat $G/charge_stop_level)" "$(cat $G/charge_start_level)" "$(sed -n 's/^capacity=//p' $C)" "$(cat $L)" "$(cat /sys/class/power_supply/battery/status)"; }
echo "=== set 60/65 (target stop=65, level ~36 so it should CHARGE) ==="
acc -s resume_capacity=60 pause_capacity=65 >/dev/null 2>&1
i=0; while [ $i -lt 120 ]; do row "+${i}s"; i=$((i+15)); sleep 15; done
echo "=== restore 70/74 ==="
acc -s resume_capacity=70 pause_capacity=74 >/dev/null 2>&1
i=0; while [ $i -lt 45 ]; do row "+${i}s"; i=$((i+15)); sleep 15; done
