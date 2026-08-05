#!/system/bin/sh
# Re-test the temperature and capacity limits on a CLEAN daemon, after recovering the charger.
# The stress run's E/F ran against a daemon whose in-memory facts did not match the cache on disk,
# because section C deleted the cache, restarted, and then the file was restored without a second
# restart. This isolates whether E/F are real.
B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
TD=/dev/.vr25/acc
DD=/data/adb/vr25/acc-data
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
kst(){ rd $B/status; }

echo "--- interface cache state ---"
if [ -f $TD/.batt-interface.sh ]; then
  echo "  exists, $(wc -l < $TD/.batt-interface.sh) lines, dpol=[$(sed -n 's/^_DPOL=//p' $TD/.batt-interface.sh | tr '\n' ',')]"
  echo "  battCapacity=$(sed -n 's/^battCapacity=//p' $TD/.batt-interface.sh)"
else
  echo "  MISSING"
fi
echo "  acc -i status=[$(acc -i 2>/dev/null | sed -n 's/^status //p' | head -1)]"

echo "--- recovering the charger ---"
for f in /sys/class/power_supply/*/current_max /sys/class/power_supply/*/input_current_settled; do
  [ -w "$f" ] && echo 5000000 > "$f" 2>/dev/null || :
done
for f in $U/apsd_rerun $B/rerun_aicl; do [ -w "$f" ] && echo 1 > "$f" 2>/dev/null || :; done
sleep 30
echo "  kernel=$(kst) icl=$(rd $U/current_max) ibat=$(rd $B/current_now) level=$(rd $B/capacity)"
[ "$(kst)" = Charging ] || { echo "  cannot test: not charging"; exit 0; }

SC=$(sed -n 's/^capacity=(//p' $DD/config.txt | tr -d ')')
ST=$(sed -n 's/^temperature=(//p' $DD/config.txt | tr -d ')')
trap 'acc -s resume_capacity=$(echo $SC|cut -d" " -f3) pause_capacity=$(echo $SC|cut -d" " -f4) >/dev/null 2>&1; acc -s cooldown_temp=$(echo $ST|cut -d" " -f1) max_temp=$(echo $ST|cut -d" " -f2) resume_temp=$(echo $ST|cut -d" " -f3) >/dev/null 2>&1; echo; echo "$P passed, $F failed"; exit 0' EXIT INT TERM HUP

T=$(( $(rd $B/temp) / 10 ))
echo "--- E: temperature limit 2C BELOW the pack (${T}C) ---"
acc -s cooldown_temp=$((T-4)) max_temp=$((T-2)) resume_temp=$((T-8)) >/dev/null 2>&1
i=0; while [ $i -lt 75 ]; do sleep 25; i=$((i+25)); echo "  +${i}s kernel=$(kst) sw=$(rd $B/input_suspend) cfg_t=$(sed -n 's/^temperature=//p' $DD/config.txt)"; done
if [ "$(kst)" != Charging ] || [ "$(rd $B/input_suspend)" = 1 ]; then ok "E stopped above max_temp"; else no "E STILL CHARGING above max_temp"; fi
acc -s cooldown_temp=$(echo $ST|cut -d' ' -f1) max_temp=$(echo $ST|cut -d' ' -f2) resume_temp=$(echo $ST|cut -d' ' -f3) >/dev/null 2>&1
sleep 40

echo "--- F: capacity pause below the level ---"
LV=$(rd $B/capacity)
acc -s resume_capacity=$((LV-3)) pause_capacity=$((LV-1)) >/dev/null 2>&1
i=0; while [ $i -lt 75 ]; do sleep 25; i=$((i+25)); echo "  +${i}s kernel=$(kst) sw=$(rd $B/input_suspend) level=$(rd $B/capacity) cfg_c=$(sed -n 's/^capacity=//p' $DD/config.txt)"; done
if [ "$(kst)" != Charging ] || [ "$(rd $B/input_suspend)" = 1 ]; then ok "F paused below the level"; else no "F STILL CHARGING with pause below the level"; fi
