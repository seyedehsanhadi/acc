#!/system/bin/sh
# acc-switch-scan.sh — fast & complete ACC charging-switch scanner
# Community helper for ACC (by VR25). GPLv3. Does NOT modify ACC.
#
# WHY: `acc -t` waits up to _STI (default 35) seconds PER switch to decide if it
# works, so a full scan takes many minutes and AccA's 150s timeout kills it before
# it finishes the list. This polls the real charging current ~3x/second and decides
# each switch in ~1-4s, tests EVERY switch ACC knows for your device, classifies the
# result (clean stop / battery-idle bypass / no effect), ranks them fastest-first,
# and prints the exact command to lock the best one in.
#
# SAFE: it stops the ACC daemon only for the scan and always restarts it afterwards
# (even on Ctrl-C / error), and it restores each switch to "on" right after testing,
# so charging is never left disabled.
#
# RUN (must be plugged in and actively charging):
#   su -c 'sh /sdcard/acc-switch-scan.sh'
# Optional max seconds-per-switch (default 4):   ...acc-switch-scan.sh 6

set -u

domain=vr25
export TMPDIR=/dev/.$domain/acc
execDir=/data/adb/$domain/acc
dataDir=/data/adb/$domain/acc-data
PATH=/data/adb/$domain/bin:$PATH

MAX_S=4                            # max seconds to wait per switch before "no effect"
STEP_MS=300                        # poll interval (ms)
APPLY=0                            # --apply: lock in the best switch automatically
for _a in "$@"; do
  case "$_a" in
    --apply) APPLY=1;;
    [0-9]*)  MAX_S=$_a;;
  esac
done

say()  { echo "$@"; }
warn() { echo "! $*"; }

# ---------- sub-second sleep (busybox usleep; fallback: sleep 1) ----------
BB=
for b in /data/adb/$domain/bin/busybox /data/adb/$domain/busybox \
         /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
         "$(command -v busybox 2>/dev/null)"; do
  [ -n "$b" ] && [ -x "$b" ] && BB=$b && break
done
nap() { if [ -n "$BB" ]; then "$BB" usleep $(( STEP_MS * 1000 )); else sleep 1; fi; }

[ "$(id -u 2>/dev/null)" = 0 ] || { warn "must run as root (su)"; exit 1; }
cd /sys/class/power_supply/ 2>/dev/null || { warn "no /sys/class/power_supply"; exit 1; }

# ---------- low-level switch writers ----------
_write() {  # _write <on|off> <switch line>
  local dir=$1 line=$2 f onv offv v o
  set -f; set -- $line; set +f
  while [ $# -ge 3 ]; do
    f=$1; onv=$2; offv=$3; shift 3
    [ "$f" = "--" ] && continue
    [ -f "$f" ] || continue
    if [ "$dir" = off ]; then v=$offv; else v=$onv; fi
    case "$v" in
      3600mV) o=$(cat "$f" 2>/dev/null || echo 0); [ "$o" -lt 10000 ] 2>/dev/null && v=3600 || v=3600000;;
      */*)    [ -f "$v" ] && v=$(cat "$v" 2>/dev/null);;
    esac
    v=$(echo "$v" | sed 's/::/ /g')
    chmod a+w "$f" 2>/dev/null
    echo "$v" > "$f" 2>/dev/null || :
  done
}
write_off()  { _write off "$1"; }
restore_on() { _write on  "$1"; }

# ---------- daemon control (always restart on exit) ----------
ACCA=
for a in "$TMPDIR/acca" /dev/.$domain/acc/acca "$(command -v acca 2>/dev/null)"; do
  [ -n "$a" ] && [ -e "$a" ] && ACCA=$a && break
done
cur_line=
cleanup() {
  [ -n "$cur_line" ] && restore_on "$cur_line" 2>/dev/null
  [ -n "$ACCA" ] && "$ACCA" -D restart >/dev/null 2>&1 || :
  say ""
  say "ACC daemon restarted; charging is back under ACC control."
}
trap cleanup EXIT INT TERM

# ---------- current source (reuse ACC's own detection if present) ----------
currFile=; battStatus=; ampFactor_=
[ -f "$TMPDIR/.batt-interface.sh" ] && . "$TMPDIR/.batt-interface.sh" 2>/dev/null || :
if [ -z "${currFile:-}" ] || [ ! -f "${currFile:-/x}" ]; then
  for currFile in battery/current_now */current_now bms/current_now; do
    [ -f "$currFile" ] && break
  done
fi
[ -f "${currFile:-/x}" ] || { warn "cannot find a current_now file"; exit 1; }
[ -f "${battStatus:-/x}" ] || battStatus=battery/status
ampFactor_=${ampFactor_:-1000000}
# "charging" threshold ~60 mA, in this device's current units
[ "$ampFactor_" -ge 1000000 ] && THR=60000 || THR=60

raw() { c=$(cat "$currFile" 2>/dev/null); echo "${c:-0}"; }
abs() { a=${1#-}; echo "${a:-0}"; }
to_mA() { awk "BEGIN{printf \"%d\", $1/($ampFactor_/1000)}" 2>/dev/null || echo "?"; }

# ---------- per-switch fast test ----------
# echoes: "ok <ms> <idle|discharging>" | "fail" | "skip"
test_switch() {
  local line=$1 base nr now i ms st mode lim
  base=$(abs "$(raw)")
  [ "$base" -gt "$THR" ] 2>/dev/null || { echo skip; return; }
  cur_line=$line
  write_off "$line"
  lim=$(( MAX_S * 1000 / STEP_MS )); [ "$lim" -lt 1 ] && lim=1
  i=0; ms=0
  while [ "$i" -lt "$lim" ]; do
    nap; i=$((i+1)); ms=$(( i * STEP_MS ))
    nr=$(raw); now=$(abs "$nr")
    # "stopped" = current went negative (discharging) OR magnitude fell under 1/3 baseline
    if [ "$nr" -lt 0 ] 2>/dev/null || [ "$now" -lt $(( base / 3 )) ] 2>/dev/null; then
      mode=idle
      [ "$nr" -lt 0 ] 2>/dev/null && mode=discharging
      restore_on "$line"; cur_line=
      echo "ok $ms $mode"; return
    fi
  done
  restore_on "$line"; cur_line=
  echo fail
}

# ---------- switch list ----------
SW=$TMPDIR/ch-switches
[ -s "$SW" ] || { warn "no switch list at $SW — run 'acc -D restart' once, then retry"; exit 1; }

# ---------- go ----------
say "== ACC fast switch scan =="
say "device : $(getprop ro.product.device 2>/dev/null)"
say "current: $(to_mA "$(raw)") mA  (source: ${currFile})"
[ "$(abs "$(raw)")" -gt "$THR" ] 2>/dev/null || { warn "Not charging now. Plug in the charger and rerun."; exit 1; }

[ -n "$ACCA" ] && "$ACCA" -D stop >/dev/null 2>&1 || :
nap

total=$(grep -cvE '^#|^$' "$SW" 2>/dev/null || echo "?")
say "testing $total switches (max ${MAX_S}s each)..."
say ""

results=
n=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  n=$((n+1))
  printf '  %2d. %-56.56s ' "$n" "$line"
  r=$(test_switch "$line")
  set -- $r
  case "${1:-}" in
    ok)   say "STOPS ${2}ms [${3}]"; results="${results}${2} ${3} ${line}
";;
    skip) say "(not charging — rerun while charging)";;
    *)    say "no effect";;
  esac
done < "$SW"

say ""
say "================ RESULT ================"
if [ -n "$results" ]; then
  say "Working switches (fastest first):"
  printf '%s' "$results" | sort -n | while read ms mode rest; do
    say "  [${ms}ms ${mode}]  $rest"
  done
  best=$(printf '%s' "$results" | sort -n | head -n1 | cut -d' ' -f3-)
  say ""
  say "BEST=${best}"
  if [ "$APPLY" = 1 ] && [ -n "$best" ]; then
    [ -n "$ACCA" ] && "$ACCA" -s "s=${best} --" >/dev/null 2>&1 || :
    say "APPLIED=1   (locked in: acc -s s='${best} --')"
  else
    say "Recommended — lock this one in (stops ACC auto-cycling it):"
    say "  acc -s s='${best} --'"
  fi
  say ""
  say "[idle] = holds the battery flat (bypass);  [discharging] = stops charging,"
  say "phone then runs off the battery until it drops to your resume level."
else
  say "NO switch stopped charging on this device."
  say "Almost always the OS is overriding ACC. Do this, then rerun:"
  say "  Settings > Battery > turn OFF Adaptive Charging / charge optimization"
  say "If it STILL finds nothing, this device needs a charge node ACC doesn't"
  say "know yet — send this whole output back."
fi
say "======================================="
# daemon restart is handled by the EXIT trap
