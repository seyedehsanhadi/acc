#!/system/bin/sh
# rc21: reboot archiver. pstore/last_kmsg are single-slot (overwritten every boot) and logcat is wiped
# on reboot, so a reboot's evidence is EPHEMERAL -- gone before the user collects a diagnostic, unless
# they catch it on the very next boot. This copies the PREVIOUS boot's reboot evidence (bootreason +
# pstore/last_kmsg tail + ACC's pre-boot state) into a persistent rolling log, ONCE per boot, so a
# reboot stays debuggable no matter when the user collects or how many times they've rebooted since.
# Passive: one read at boot, bounded, fail-open. Called (backgrounded + timeboxed) from service.sh.
id=acc; domain=vr25
DD=/data/adb/$domain/${id}-data
HIST=$DD/reboot-history.log
MARK=$DD/.reboot-archived-boot

# boot id changes every boot -> archive exactly once per boot even if service.sh runs twice
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || cut -d. -f1 /proc/uptime 2>/dev/null || echo x)
[ "$(cat "$MARK" 2>/dev/null)" = "$BID" ] && exit 0

mkdir -p "$DD" 2>/dev/null || :
{
  echo "==================== boot archived @ $(date 2>/dev/null) (uptime $(cut -d. -f1 /proc/uptime 2>/dev/null)s) ===================="
  echo "reset reason : ro.boot.bootreason=$(getprop ro.boot.bootreason)  sys.boot.reason.last=$(getprop sys.boot.reason.last)"
  echo "reason history: $(getprop persist.sys.boot.reason.history | tr '|' ';' | head -c 240)"
  echo "pstore present: $(ls /sys/fs/pstore/ 2>/dev/null | tr '\n' ' ' || echo none)"
  for p in /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/console-ramoops /sys/fs/pstore/dmesg-ramoops-0 /proc/last_kmsg; do
    [ -f "$p" ] || continue
    echo "---- previous-boot kernel tail: $p ----"
    tail -100 "$p" 2>/dev/null
    break
  done
  echo "---- ACC pre-boot state (did a charge write crash the boot?) ----"
  echo "earlycap-pending: $(cat "$DD/.earlycap-pending" 2>/dev/null || echo none)"
  echo "probe-pending   : $(cat "$DD/.probe-pending" 2>/dev/null || echo none)"
  echo "probe-blacklist : $(cat "$DD/.probe-blacklist" 2>/dev/null | tr '\n' ';' || echo none)"
  echo "early-boot-count: $(cat "$DD/.early-boot-count" 2>/dev/null || echo -)"
  echo "early-cap.log tail: $(tail -4 "$DD/logs/early-cap.log" 2>/dev/null | tr '\n' ';')"
  echo
} >> "$HIST" 2>/dev/null || :

# roll: keep it bounded (~last 5-8 boots). Trim to the last 1500 lines when it grows past 2000.
_n=$(wc -l < "$HIST" 2>/dev/null || echo 0)
case ${_n:-0} in ''|*[!0-9]*) _n=0;; esac
[ "$_n" -gt 2000 ] && { tail -1500 "$HIST" > "$HIST.tmp" 2>/dev/null && mv -f "$HIST.tmp" "$HIST" 2>/dev/null; } || :

echo "$BID" > "$MARK" 2>/dev/null || :
exit 0
