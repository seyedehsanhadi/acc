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
#   su -c 'sh /sdcard/acc-switch-scan.sh'         # scan only (recommend a switch)
#   ...acc-switch-scan.sh --apply                 # + LOCK the "hold at limit" method (DEFAULT)
#   ...acc-switch-scan.sh --apply --cycle         # + LOCK the "discharge-cycle" method instead
# Optional max seconds-per-switch (default 4):   ...acc-switch-scan.sh 6

set -u

domain=vr25
export TMPDIR=/dev/.$domain/acc
execDir=/data/adb/$domain/acc
dataDir=/data/adb/$domain/acc-data
PATH=/data/adb/$domain/bin:$PATH

MAX_S=4                            # max seconds to wait per switch before "no effect"
STEP_MS=300                        # poll interval (ms)
APPLY=0                            # --apply: lock the best switch automatically
METHOD=hold                        # which method to lock: hold (park at limit, DEFAULT) | cycle (discharge<->recharge)
for _a in "$@"; do
  case "$_a" in
    --apply) APPLY=1;;
    --cycle) METHOD=cycle;;
    --hold)  METHOD=hold;;
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

# fix7: resolve the "pcap" off-token (used by limit-type switches like
# charge_stop_level) to the configured pause_capacity, falling back to the live
# capacity. This makes the scan test the same flat-hold value the daemon applies,
# so the limit node reads as a clean [idle] hold instead of a [discharging] drain.
PCAP=$(grep -hoE '^pause_capacity=[0-9]+' "$dataDir/config.txt" "$execDir/config.txt" 2>/dev/null | grep -oE '[0-9]+' | head -n1)
[ -n "${PCAP:-}" ] || PCAP=$(cat battery/capacity 2>/dev/null || echo 60)

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
      pcap)   v=$PCAP;;
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
  # fix10: confirm the daemon actually came back. `acca -D restart` now detaches it,
  # but verify so a failed restart is never silent -- a stopped daemon = no cap.
  # `acca -D` exits 0 when accd holds its lock (running), 9 when it does not.
  up=0
  if [ -n "$ACCA" ]; then
    i=0; while [ "$i" -lt 8 ]; do
      "$ACCA" -D >/dev/null 2>&1 && { up=1; break; }
      nap; i=$((i+1))
    done
  fi
  say ""
  if [ "$up" = 1 ]; then
    say "ACC daemon restarted; charging is back under ACC control."
  else
    say "! ACC daemon did NOT come back -- charging is currently UNCAPPED."
    say "  Fix: reboot, or toggle the daemon off then on in AccA."
  fi
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
  # fix10: a previous test may have left the charger idle/bypassed; wait briefly for
  # charging to resume so this switch is measured from a charging baseline. Without
  # this, a switch tested right after a stopping one (e.g. the pcap variant) falsely
  # reads as "skip / not charging" and never gets evaluated.
  i=0; while [ "$(abs "$(raw)")" -le "$THR" ] 2>/dev/null && [ "$i" -lt 14 ]; do nap; i=$((i+1)); done
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
[ "$APPLY" = 1 ] && say "lock   : $([ "$METHOD" = cycle ] && echo 'discharge-cycle (battery-idle OFF)' || echo 'hold at limit / battery-idle (DEFAULT)')"
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
    ok)   say "STOPS ${2}ms [${3}]"
          # fix12: rank by the METHOD the user chose to lock, decided by the switch
          # LINE itself (measured idle/discharging is unreliable on devices that
          # slow-drain even at the limit). "<node> pcap pcap" = hold-at-cap;
          # "<node> pcap 5" = discharge-cycle. Default (hold) -> pcap-pcap first;
          # --cycle -> pcap-5 first. Plain (non-pcap) switches: idle above discharging.
          P=4
          case "$line" in
            *\ pcap\ pcap) [ "$METHOD" = cycle ] && P=2 || P=0;;
            *\ pcap\ 5)    [ "$METHOD" = cycle ] && P=0 || P=2;;
            *)             case "$3" in idle) P=1;; *) P=3;; esac;;
          esac
          results="${results}${P} ${2} ${3} ${line}
";;
    skip) say "(not charging — rerun while charging)";;
    *)    say "no effect";;
  esac
done < "$SW"

say ""
say "================ RESULT ================"
if [ -n "$results" ]; then
  say "Working switches (best first -- $([ "$METHOD" = cycle ] && echo 'discharge-cycle' || echo 'hold-at-limit') method preferred, then fastest):"
  printf '%s' "$results" | sort -n -k1,1 -k2,2n | while read prio ms mode rest; do
    say "  [${ms}ms ${mode}]  $rest"
  done
  best=$(printf '%s' "$results" | sort -n -k1,1 -k2,2n | head -n1 | cut -d' ' -f4-)
  say ""
  say "BEST=${best}"
  if [ "$APPLY" = 1 ] && [ -n "$best" ]; then
    [ -n "$ACCA" ] && "$ACCA" -s "s=${best} --" >/dev/null 2>&1 || :
    say "APPLIED=1   method=${METHOD}   (locked in: acc -s s='${best} --')"
  else
    say "Recommended ($([ "$METHOD" = cycle ] && echo 'discharge-cycle' || echo 'hold-at-limit')) -- lock it in (stops ACC auto-cycling):"
    say "  acc -s s='${best} --'"
    say "  (re-run the scan with --apply to lock it; add --cycle for the discharge-cycle method)"
  fi
  say ""
  say "hold-at-limit = parks the battery at your limit (pcap pcap);  discharge-cycle ="
  say "drops to your resume level then recharges to the limit, repeating (pcap 5)."
else
  say "NO switch stopped charging on this device."
  say "Almost always the OS is overriding ACC. Do this, then rerun:"
  say "  Settings > Battery > turn OFF Adaptive Charging / charge optimization"
  say "If it STILL finds nothing, this device needs a charge node ACC doesn't"
  say "know yet — send this whole output back."
fi
say "======================================="
# daemon restart is handled by the EXIT trap
