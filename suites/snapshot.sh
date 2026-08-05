#!/system/bin/sh
# snapshot.sh - record this phone's charging state, so a later change has attribution.
#
#   sh snapshot.sh save <tag>     write a snapshot under that tag
#   sh snapshot.sh diff <a> <b>   print only what differs between two snapshots
#   sh snapshot.sh list           list the snapshots on this phone
#
# WHY
#   Plugging a cable in changes a lot at once: the supply negotiates, the kernel re-reads, ACC wakes
#   and starts enforcing. Afterwards it is easy to attribute something to ACC that the charger did,
#   or the reverse. Twice in this campaign a conclusion was drawn from a value nobody had recorded
#   before the event, and both times it was wrong.
#
#   So: take a snapshot before, take one after, and diff. Only lines that actually moved are printed,
#   and every line names where it came from, so "ACC did this" is a claim that can be checked rather
#   than assumed.
#
# WHAT IT DOES NOT DO
#   It writes no charging node and changes no setting. Read-only apart from its own files under
#   $DL/acc-snap. Safe to run at any time, plugged or not.

DL=/sdcard/Download
[ -d "$DL" ] && [ -w "$DL" ] || DL=/data/local/tmp
SNAPDIR=$DL/acc-snap
mkdir -p "$SNAPDIR" 2>/dev/null || :

TD=/dev/.vr25/acc
DD=/data/adb/vr25/acc-data
M=/data/adb/vr25/acc
IF=$TD/.batt-interface.sh

rd(){ _v=; { read -r _v < "$1"; } 2>/dev/null || :; echo "$_v"; }
put(){ printf '%s=%s\n' "$1" "$2"; }

# Resolve the gauge the way ACC does. A hardcoded battery/* path reports 0% on phones where the fuel
# gauge is a different node, which is what made one tester's report look like a dead battery.
G=/sys/class/power_supply/battery
for _c in /sys/class/power_supply/*/capacity; do
  _d=${_c%/capacity}
  [ -n "$(rd "$_c")" ] && [ -n "$(rd "$_d/status")" ] && { G=$_d; break; }
done

snap(){
  put device        "$(getprop ro.product.device 2>/dev/null)"
  put android       "$(getprop ro.build.version.release 2>/dev/null)"
  put acc.build     "$(sed -n 's/^versionCode=//p' $M/module.prop 2>/dev/null)"
  put acc.uptime    "$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"

  # --- ACC daemon ---------------------------------------------------------------------------------
  _p=$(rd $TD/acc.lock)
  put daemon.pid    "$_p"
  put daemon.alive  "$([ -n "$_p" ] && [ -d "/proc/$_p" ] && echo yes || echo no)"
  put daemon.flight "$(wc -l < $DD/logs/flight.log 2>/dev/null)"
  put daemon.ledger "$(wc -l < $TD/.write-ledger 2>/dev/null)"

  # --- what the user asked ACC to do ---------------------------------------------------------------
  for _k in capacity temperature maxChargingCurrent maxChargingVoltage; do
    put "cfg.$_k"   "$(sed -n "s/^$_k=//p" $DD/config.txt 2>/dev/null)"
  done

  # --- what ACC believes ---------------------------------------------------------------------------
  put acc.status    "$(timeout 20 acc -i 2>/dev/null </dev/null | sed -n 's/^status //p' | head -1)"
  put acc.level     "$(timeout 20 acc -i 2>/dev/null </dev/null | sed -n 's/^level //p' | head -1)"
  put cache.bytes   "$(wc -c < $IF 2>/dev/null)"
  put cache.polarity "$(sed -n 's/^_DPOL=//p' $IF 2>/dev/null)"
  put cache.ampFactor "$(sed -n 's/^ampFactor_=//p' $IF 2>/dev/null)"

  # Markers. Each one is a decision ACC has taken and is still holding; a marker appearing across a
  # plug event is the single most useful thing in this file.
  for _m in .mcc-custom .testingsw .temp-blind .dpol_unstable .no-probe .breach .dsys-override \
            .mask-on .statusheal .autolock-tried .rekick-off .nap-ref; do
    put "mark$_m"   "$([ -e "$TD/$_m" ] && echo present || echo -)"
  done

  # --- what the hardware says ----------------------------------------------------------------------
  put batt.gauge    "$G"
  for _n in capacity status health temp voltage_now current_now charge_counter charge_type present; do
    put "batt.$_n"  "$(rd $G/$_n)"
  done
  for _s in /sys/class/power_supply/*; do
    _b=${_s##*/}
    case "$_b" in battery|bms|maxfg|*fuelgauge*) continue;; esac
    [ -f "$_s/online" ] || continue
    put "$_b.online"      "$(rd $_s/online)"
    put "$_b.present"     "$(rd $_s/present)"
    put "$_b.current_max" "$(rd $_s/current_max)"
    put "$_b.voltage_now" "$(rd $_s/voltage_now)"
    put "$_b.current_now" "$(rd $_s/current_now)"
    put "$_b.type"        "$(rd $_s/type)"
    put "$_b.real_type"   "$(rd $_s/real_type)"
  done

  # --- the switch ACC is actually holding ------------------------------------------------------------
  put switch.current "$(sed -n 's/^chargingSwitch=//p' $DD/config.txt 2>/dev/null)"
  for _swf in /sys/class/power_supply/battery/input_suspend \
            /sys/class/power_supply/battery/charging_enabled \
            /sys/class/power_supply/battery/charge_stop_level \
            /sys/class/power_supply/battery/charge_start_level \
            /sys/class/power_supply/main/constant_charge_current_max \
            /sys/class/power_supply/battery/constant_charge_current_max; do
    [ -f "$_swf" ] && put "node.${_swf##*/}" "$(rd "$_swf")"
  done
}

case "${1:-save}" in
  save)
    _tag=${2:-$(date +%H%M%S)}
    _out=$SNAPDIR/$_tag.txt
    snap > "$_out" 2>/dev/null
    sync 2>/dev/null || :
    # Read the path back from a variable snap() cannot touch: it shares this shell, so anything it
    # uses as a loop variable is fair game to be clobbered. That is how this printed a sysfs path.
    echo "saved: $_out  ($(wc -l < "$_out") values)"
    echo "  build=$(sed -n 's/^acc.build=//p' "$_out")  level=$(sed -n 's/^batt.capacity=//p' "$_out")%  status=$(sed -n 's/^batt.status=//p' "$_out")  acc=$(sed -n 's/^acc.status=//p' "$_out")"
    ;;
  diff)
    _a=$SNAPDIR/${2:?need snapshot A}.txt
    _b=$SNAPDIR/${3:?need snapshot B}.txt
    [ -f "$_a" ] || { echo "no snapshot '$2'"; exit 1; }
    [ -f "$_b" ] || { echo "no snapshot '$3'"; exit 1; }
    echo "=== $2 -> $3 : only what changed ==="
    _n=0
    while IFS= read -r _line; do
      _k=${_line%%=*}
      _va=${_line#*=}
      _vb=$(sed -n "s|^$_k=||p" "$_b" | head -1)
      [ "$_va" = "$_vb" ] && continue
      _n=$((_n + 1))
      printf '  %-26s %s  ->  %s\n' "$_k" "${_va:-(empty)}" "${_vb:-(empty)}"
    done < "$_a"
    # Keys that exist only in B are new state, and a marker appearing is exactly what matters most.
    while IFS= read -r _line; do
      _k=${_line%%=*}
      grep -q "^$_k=" "$_a" 2>/dev/null && continue
      _n=$((_n + 1))
      printf '  %-26s (absent)  ->  %s\n' "$_k" "${_line#*=}"
    done < "$_b"
    echo "  --- $_n values moved ---"
    ;;
  list)
    ls -t "$SNAPDIR"/*.txt 2>/dev/null | while read -r _s; do
      echo "  $(basename "$_s" .txt)  $(sed -n 's/^acc.build=//p' "$_s")  level=$(sed -n 's/^batt.capacity=//p' "$_s")%  $(sed -n 's/^batt.status=//p' "$_s")"
    done
    ;;
  *) echo "usage: snapshot.sh save <tag> | diff <a> <b> | list"; exit 1;;
esac
