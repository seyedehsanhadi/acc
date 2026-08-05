#!/system/bin/sh
D=/data/adb/vr25/acc-data
echo "no-native-limit marker : $([ -f $D/.no-native-limit ] && echo PRESENT || echo absent)"
echo "google,charger dir     : $(ls -d /sys/devices/platform/google,charger 2>/dev/null || echo MISSING)"
echo "stop node writable     : $([ -w /sys/devices/platform/google,charger/charge_stop_level ] && echo yes || echo NO)"
echo "sw-blacklist (tmp)     : $(cat /dev/.vr25/acc/.sw-blacklist 2>/dev/null | tr '\n' ' ')"
echo "sw-blacklist (data)    : $(cat $D/.sw-blacklist 2>/dev/null | tr '\n' ' ')"
echo "journal blacklist      : $(cat $D/.journal-blacklist 2>/dev/null | tr '\n' ' ')"
echo "chargingSwitch cfg     : $(sed -n 's/^chargingSwitch=//p' $D/config.txt)"
echo "capacity cfg           : $(sed -n 's/^capacity=//p' $D/config.txt)"
echo "--- can we write the node by hand? ---"
before=$(cat /sys/devices/platform/google,charger/charge_stop_level)
echo 77 > /sys/devices/platform/google,charger/charge_stop_level 2>/dev/null
after=$(cat /sys/devices/platform/google,charger/charge_stop_level)
echo "manual write 77: before=$before after=$after $([ "$after" = 77 ] && echo WRITABLE || echo REJECTED)"
sleep 25
echo "25s later      : stop=$(cat /sys/devices/platform/google,charger/charge_stop_level) (daemon should have re-synced it to the config's 74)"
echo "--- acc -i native section ---"
acc -i 2>/dev/null | head -30
