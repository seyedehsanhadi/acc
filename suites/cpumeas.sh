#!/system/bin/sh
# cpumeas.sh - idle CPU cost of ACC + AccA, screen off, unplugged.
#
#   sh cpumeas.sh <settle_seconds> <window_seconds> <label>
#
# WHY JIFFIES AND NOT top
#   `top` reports an instantaneous sample of a process that spends most of its life asleep, so a
#   1-second look at accd reads 0% almost always and 40% occasionally. utime+stime out of
#   /proc/<pid>/stat is a monotonic total: the delta across a known window is the real average,
#   and it cannot miss a burst that happened between samples.
#
# WHY SETTLE FIRST
#   Everything is busy for a minute after the screen goes off - deferred jobs, the daemon's own
#   first pass, whatever the shell just did. Measuring immediately reports that, not steady state.
#
# The daemon is a shell script, so its children cost more than the process itself. Counting only
# accd's own stat would undercount by most of the real work, which is why forks are counted too.

S=${1:-90}
W=${2:-180}
L=${3:-run}
HZ=100

G=/sys/class/power_supply/battery
say(){ echo "$*"; }

pid_of_accd() { cat /dev/.vr25/acc/acc.lock 2>/dev/null; }

# utime+stime of a pid, in jiffies; 0 if it is gone
cpu_of() {
  [ -n "$1" ] && [ -d "/proc/$1" ] || { echo 0; return; }
  awk '{print $14 + $15}' /proc/$1/stat 2>/dev/null || echo 0
}

# whole-process-tree cost: the daemon plus anything it spawned that is alive right now.
# cutime+cstime on the parent captures reaped children, which is where a shell daemon's cost is.
cpu_tree() {
  [ -n "$1" ] && [ -d "/proc/$1" ] || { echo 0; return; }
  awk '{print $14 + $15 + $16 + $17}' /proc/$1/stat 2>/dev/null || echo 0
}

uid_of_acca() {
  stat -c %u /data/data/mattecarra.accapp 2>/dev/null
}

acca_pid() { pgrep -f mattecarra.accapp 2>/dev/null | head -1; }

plugged() {
  for f in /sys/class/power_supply/*/present; do
    case $f in */battery/*|*/bms/*|*maxfg*) continue;; esac
    [ "$(cat $f 2>/dev/null)" = 1 ] && return 0
  done
  return 1
}

say "=== $L on $(getprop ro.product.device) ==="
say "ui_refresh=$(sed -n 's/^uiRefresh=//p' /data/adb/vr25/acc-data/config.txt)"
if plugged; then
  say "REFUSING: still plugged. Idle drain is only meaningful on battery."
  echo "result=refused-plugged" > /data/local/tmp/cpumeas.done
  exit 0
fi

# screen off, and keep it off for the whole run
input keyevent 223 2>/dev/null
sleep 2

say "settling ${S}s ..."
sleep $S

A=$(pid_of_accd)
[ -n "$A" ] && [ -d "/proc/$A" ] || { say "accd is not running"; echo "result=no-daemon" > /data/local/tmp/cpumeas.done; exit 1; }

P=$(acca_pid)
c0=$(cpu_tree $A)
p0=$(cpu_of ${P:-0})
# System-wide fork count. On an otherwise idle phone almost every fork is ACC's, and this is the
# number a shell daemon's cost is actually made of - it moves cleanly where CPU ms is noisy.
k0=$(sed -n 's/^processes //p' /proc/stat)
l0=$(cat $G/capacity)
t0=$(date +%s)
# uptime-based idle fraction, as a cross-check that the phone really was asleep
u0=$(cut -d' ' -f1 /proc/uptime)
i0=$(cut -d' ' -f2 /proc/uptime)

say "measuring ${W}s ..."
sleep $W

c1=$(cpu_tree $A)
p1=$(cpu_of ${P:-0})
k1=$(sed -n 's/^processes //p' /proc/stat)
l1=$(cat $G/capacity)
t1=$(date +%s)
u1=$(cut -d' ' -f1 /proc/uptime)
i1=$(cut -d' ' -f2 /proc/uptime)

el=$(( t1 - t0 ))
[ "$el" -gt 0 ] || el=1
dc=$(( c1 - c0 ))
dp=$(( p1 - p0 ))

# jiffies -> ms, then per minute
accd_ms_min=$(( dc * 1000 / HZ * 60 / el ))
acca_ms_min=$(( dp * 1000 / HZ * 60 / el ))
tot=$(( accd_ms_min + acca_ms_min ))
# a core is 60000 ms per minute
pct=$(awk "BEGIN{printf \"%.2f\", $tot * 100 / 60000}")

say ""
say "window          ${el}s"
say "accd + children ${accd_ms_min} ms/min"
say "AccA process    ${acca_ms_min} ms/min  (pid ${P:-none})"
say "TOTAL           ${tot} ms/min  = ${pct}% of one core"
say "forks           $(( ( ${k1:-0} - ${k0:-0} ) * 60 / el )) /min  (system-wide)"
say "battery level   ${l0}% -> ${l1}%"
say "cpu-seconds idle across the window: $(awk "BEGIN{printf \"%.1f\", $i1 - $i0}") of $(awk "BEGIN{printf \"%.1f\", $u1 - $u0}") wall"
printf 'label=%s ui_refresh=%s accd=%s acca=%s total=%s pct=%s secs=%s\n' \
  "$L" "$(sed -n 's/^uiRefresh=//p' /data/adb/vr25/acc-data/config.txt)" \
  "$accd_ms_min" "$acca_ms_min" "$tot" "$pct" "$el" > /data/local/tmp/cpumeas.done
