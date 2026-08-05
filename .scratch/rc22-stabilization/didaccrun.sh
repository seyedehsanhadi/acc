#!/system/bin/sh
# Did ANY ACC code run this boot, despite the module being disabled?
D=/data/adb/vr25/acc-data
UP=$(cut -d" " -f1 /proc/uptime); UP=${UP%.*}
BOOT=$(( $(date +%s) - UP ))
echo "boot epoch  : $BOOT   ($(date -d @$BOOT 2>/dev/null || echo '?'))"
echo "now         : $(date +%s)  uptime=$(cut -d' ' -f1 /proc/uptime)s"
echo
echo "--- ACC log/marker mtimes; anything at or after boot means ACC ran ---"
for f in $D/logs/early-cap.log $D/logs/init.log $D/logs/flight.log $D/logs/write.log \
         /dev/.vr25/acc/.write-ledger /dev/.vr25/acc/.batt-interface.sh /dev/.vr25/acc/acc.lock; do
  if [ -e "$f" ]; then
    m=$(stat -c %Y "$f" 2>/dev/null)
    if [ -n "$m" ] && [ "$m" -ge "$BOOT" ] 2>/dev/null; then tag="*** WROTE THIS BOOT ***"; else tag="(stale, pre-boot)"; fi
    printf '  %-46s %s  %s\n' "${f##*/}" "$m" "$tag"
  else
    printf '  %-46s (absent)\n' "${f##*/}"
  fi
done
echo
echo "--- does /dev/.vr25 even exist this boot? (tmpfs: recreated only if ACC ran) ---"
ls -ld /dev/.vr25 /dev/.vr25/acc 2>/dev/null || echo "  /dev/.vr25 ABSENT -> no ACC code ran"
echo
echo "--- is the module mounted? ---"
grep -c "modules/acc" /proc/mounts 2>/dev/null
ls -l /data/adb/modules/acc/disable 2>/dev/null
echo
echo "--- current charge state ---"
U=/sys/class/power_supply/usb; B=/sys/class/power_supply/battery
printf '  vbus=%s icl=%s online=%s ibat=%s status=%s level=%s\n' \
  "$(cat $U/voltage_now)" "$(cat $U/current_max)" "$(cat $U/online)" \
  "$(cat $B/current_now)" "$(cat $B/status)" "$(cat $B/capacity)"
echo
echo "--- kernel view of who last voted the input down ---"
dmesg 2>/dev/null | grep -E "USB_ICL|AICL|SW_QC3|SUSPEND_VOTER" | tail -12
