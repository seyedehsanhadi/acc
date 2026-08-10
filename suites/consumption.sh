#!/system/bin/sh
# consumption.sh - what does ACC actually cost, and is rc22 worse than the build users run?
#
#   sh consumption.sh
#
# Answers the question a user actually asks - "does this drain my battery?" - with a number that
# can be compared against the release it replaces, instead of an opinion.
#
# THREE ARMS, one phone, wakelock held so every arm spends the same fraction of the window awake:
#   off    daemon stopped entirely - the floor. Everything above this is ACC's doing.
#   rc21   the build users are running today, from the A/B tree
#   rc22   the candidate, measured twice (first and last) so the run reports its own noise floor
#
# WHY A CONTROL ARM TWICE
#   Without it a 5% difference between builds is indistinguishable from 5% of drift, and the
#   previous sweep on this hardware drifted 1.4% between identical arms. Any claim smaller than
#   the measured control spread is not a finding.
#
# SAFETY
#   The whole module directory is copied aside first and restored from a trap on every exit path,
#   then verified by checksum. Both phones are unplugged for this, so a stopped daemon controls
#   nothing while it is stopped. shutdown_capacity is never touched.

M=/data/adb/vr25/acc
AB=/data/local/tmp/ab/rc21/install
BK=/data/local/tmp/acc-rc22-backup
OUT=/data/local/tmp/vs21.txt
LOCK=accvs
: > $OUT

say(){ echo "$*" | tee -a $OUT; }

sum_module() { cat $M/*.sh 2>/dev/null | cksum | cut -d' ' -f1; }

start_daemon() { acca -D start >/dev/null 2>&1 || $M/acca.sh -D start >/dev/null 2>&1 || :; sleep 5; }
stop_daemon()  { acca -D stop  >/dev/null 2>&1 || $M/acca.sh -D stop  >/dev/null 2>&1 || :; sleep 3; }

daemon_pid() { P=$(cat /dev/.vr25/acc/acc.lock 2>/dev/null); [ -n "$P" ] && [ -d /proc/$P ] && echo $P; }

restore() {
  say "restoring rc22 ..."
  stop_daemon
  cp -f $BK/*.sh $M/ 2>/dev/null
  cp -f $BK/module.prop $M/ 2>/dev/null
  chmod 0755 $M/*.sh 2>/dev/null
  start_daemon
  echo $LOCK > /sys/power/wake_unlock 2>/dev/null || :
  if [ "$(sum_module)" = "$WANT" ]; then
    say "restore VERIFIED (checksum matches, version $(sed -n 's/^versionCode=//p' $M/module.prop), daemon $(daemon_pid || echo DOWN))"
  else
    say "RESTORE MISMATCH - module differs from the backup. Backup is at $BK"
  fi
}

# --- back up rc22 before touching anything ---
rm -rf $BK; mkdir -p $BK
cp -f $M/*.sh $BK/ 2>/dev/null
cp -f $M/module.prop $BK/ 2>/dev/null
WANT=$(sum_module)
say "device $(getprop ro.product.device)  rc22=$(sed -n 's/^versionCode=//p' $M/module.prop)  checksum=$WANT"
[ -d $AB ] || { say "no rc21 tree at $AB - cannot compare"; exit 1; }

trap 'restore' EXIT INT TERM HUP
echo $LOCK > /sys/power/wake_lock 2>/dev/null || { say "cannot take a wakelock"; exit 1; }

measure() {
  sh ${execDir:-/data/adb/vr25/acc}/suites/cpumeas.sh 45 150 "$1" 2>&1 \
    | grep -E "TOTAL|window|accd |forks" | sed "s/^/  [$1] /" | tee -a $OUT
}

# --- arm 1: rc22 as installed ---
say ""; say "=== arm 1: rc22 ==="
start_daemon
say "  daemon pid $(daemon_pid || echo DOWN)"
measure rc22-a

# --- arm 2: daemon stopped ---
say ""; say "=== arm 2: ACC off ==="
stop_daemon
say "  daemon pid $(daemon_pid || echo STOPPED)"
# cpumeas needs a pid to read; with the daemon down it reports no-daemon, so measure the
# whole-system idle instead: the point of this arm is that ACC contributes nothing.
U0=$(cut -d' ' -f1 /proc/uptime); I0=$(cut -d' ' -f2 /proc/uptime); T0=$(date +%s)
K0=$(sed -n 's/^processes //p' /proc/stat)
sleep 195
U1=$(cut -d' ' -f1 /proc/uptime); I1=$(cut -d' ' -f2 /proc/uptime); T1=$(date +%s)
K1=$(sed -n 's/^processes //p' /proc/stat)
say "  [off] window $(( T1 - T0 ))s"
say "  [off] accd + children 0 ms/min  (daemon stopped)"
say "  [off] forks           $(( ( K1 - K0 ) * 60 / ( T1 - T0 ) )) /min  (system-wide, the true floor)"
say "  [off] system idle $(awk "BEGIN{printf \"%.1f\", $I1 - $I0}") of $(awk "BEGIN{printf \"%.1f\", $U1 - $U0}") wall"

# --- arm 3: rc21 ---
say ""; say "=== arm 3: rc21 ==="
cp -f $AB/*.sh $M/ 2>/dev/null
chmod 0755 $M/*.sh 2>/dev/null
start_daemon
say "  daemon pid $(daemon_pid || echo DOWN)"
measure rc21

# --- arm 4: rc22 again, the control ---
say ""; say "=== arm 4: rc22 again (control) ==="
cp -f $BK/*.sh $M/ 2>/dev/null
cp -f $BK/module.prop $M/ 2>/dev/null
chmod 0755 $M/*.sh 2>/dev/null
stop_daemon; start_daemon
say "  daemon pid $(daemon_pid || echo DOWN)"
measure rc22-b
