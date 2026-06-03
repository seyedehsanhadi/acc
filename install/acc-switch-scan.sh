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
METHOD=cycle                       # which method to lock: cycle (range X..Y, DEFAULT) | hold (Hold@Limit / bypass)
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

# rc16: single-instance mutex. The daemon may auto-trigger this scan while the user
# also taps a "Scan & lock" script -- two scanners toggling switches at once is chaos.
# flock a tmpfs lock; if another scan holds it, exit cleanly. (No-op if flock absent.)
if command -v flock >/dev/null 2>&1; then
  exec 8>"$TMPDIR/.scan.lock" 2>/dev/null && { flock -n 8 || { warn "another switch scan is already running; aborting this one"; exit 0; }; }
fi

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
restore_all_on() {
  # rc19: restore EVERY candidate switch to its ON value, so an interrupted/errored test
  # can never leave a charge node pinned off (the "no charge until reboot" report). SW is
  # set by the time any exit happens. SIGKILL still skips this -- the daemon's startup
  # recovery (cycle_switches on) covers that case.
  [ -f "${SW:-/x}" ] || return 0
  while IFS= read -r _l; do
    case "$_l" in ''|'#'*) continue;; esac
    restore_on "$_l" 2>/dev/null || :
  done < "$SW"
}
cleanup() {
  [ -n "$cur_line" ] && restore_on "$cur_line" 2>/dev/null
  restore_all_on
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

# rc16: INPUT (charger-side) current, used to tell a true bypass/hold (charger still
# feeding the phone => battery idle, no drain) from a passthrough-BLOCKING switch
# (charger dead => battery powers the phone => DRAINS while plugged, e.g. some Sony
# Xperia). Best-effort: if no input node is found, classification falls back to "clean".
inFile=
for _f in usb/current_now usb/input_current_now main-charger/current_now \
          dc/current_now wireless/current_now */input_current_now */input_cur; do
  [ -f "$_f" ] && { inFile=$_f; break; }
done
in_raw() { [ -n "$inFile" ] && { c=$(cat "$inFile" 2>/dev/null); echo "${c:-0}"; } || echo 0; }

# ---------- per-switch fast test ----------
# echoes: "ok <ms> <idle|discharging> <bypass|clean|drain> <rok 0|1>" | "fail" | "skip"
#   class:  bypass = stopped & charger still feeds phone (true hold, no drain)
#           drain  = stopped & charger dead & battery sourcing load (DRAINS plugged!)
#           clean  = stopped, input indeterminate (fine for Range Cycle)
#   rok:    1 = charging verifiably RESUMED after re-arm (guarantees the X..Y cycle)
test_switch() {
  local line=$1 base baseRaw chgNeg revd nr now i ms mode lim klass inb rok
  # widened 14->20 polls: some chargers renegotiate USB-PD on each toggle and take
  # longer to resume to the charging baseline; do not falsely "skip" them.
  i=0; while [ "$(abs "$(raw)")" -le "$THR" ] 2>/dev/null && [ "$i" -lt 20 ]; do nap; i=$((i+1)); done
  baseRaw=$(raw); base=$(abs "$baseRaw")
  [ "$base" -gt "$THR" ] 2>/dev/null || { echo skip; return; }
  # Some kernels (e.g. certain Motorola) report current_now with the INVERTED sign
  # (charging negative / discharging positive). Anchor "stopped" to a reversal vs THIS
  # baseline's sign so the scan is correct on either convention (a plain `nr < 0` test
  # false-positives every switch on an inverted-sign device, since charging is already
  # negative there). chgNeg=1 means this device reports charging as negative.
  chgNeg=0; [ "$baseRaw" -lt 0 ] 2>/dev/null && chgNeg=1
  cur_line=$line
  write_off "$line"
  lim=$(( MAX_S * 1000 / STEP_MS )); [ "$lim" -lt 1 ] && lim=1
  i=0; ms=0
  while [ "$i" -lt "$lim" ]; do
    nap; i=$((i+1)); ms=$(( i * STEP_MS ))
    nr=$(raw); now=$(abs "$nr")
    # current REVERSED vs the charging baseline (sign-agnostic; handles inverted-sign kernels)
    revd=0
    if [ "$chgNeg" = 1 ]; then
      [ "$nr" -gt 0 ] 2>/dev/null && revd=1
    else
      [ "$nr" -lt 0 ] 2>/dev/null && revd=1
    fi
    # "stopped" = current reversed direction (now discharging) OR magnitude fell under 1/3 baseline
    if [ "$revd" = 1 ] || [ "$now" -lt $(( base / 3 )) ] 2>/dev/null; then
      mode=idle; [ "$revd" = 1 ] && mode=discharging
      # classify hold-quality from the CHARGER-side current
      inb=$(abs "$(in_raw)")
      if [ -n "$inFile" ] && [ "$revd" = 1 ] && [ "$inb" -le "$THR" ] 2>/dev/null; then
        klass=drain          # battery sourcing load AND no charger input = passthrough blocked
      elif [ -n "$inFile" ] && [ "$now" -le "$THR" ] 2>/dev/null && [ "$inb" -gt "$THR" ] 2>/dev/null; then
        klass=bypass         # battery idle AND charger still feeding = true hold
      else
        klass=clean
      fi
      # RESUME verify: re-arm and confirm charging actually comes back, so a locked
      # switch is guaranteed able to recharge from X. Best-effort (cannot resume when
      # already at/above the limit) -> rok=0 just downranks, never hard-fails.
      restore_on "$line"; cur_line=
      rok=0; i=0
      while [ "$i" -lt 14 ]; do nap; i=$((i+1)); [ "$(abs "$(raw)")" -gt "$THR" ] 2>/dev/null && { rok=1; break; }; done
      echo "ok $ms $mode $klass $rok"; return
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
[ "$APPLY" = 1 ] && say "lock   : $([ "$METHOD" = cycle ] && echo 'Range Cycle (DEFAULT)' || echo 'Hold@Limit / bypass')"
[ "$(abs "$(raw)")" -gt "$THR" ] 2>/dev/null || { warn "Not charging now. Plug in the charger and rerun."; exit 1; }

# rc16: thermal guard. A baseline captured while the charger is thermally throttled is
# unreliable (a switch can look like "no effect" only because current was already low).
# Warn but proceed -- never block capping on a warm battery.
_tf=
for _t in battery/temp $(echo "$battStatus" | sed 's,/[^/]*$,/temp,') bms/temp; do
  [ -f "$_t" ] && { _tf=$_t; break; }
done
if [ -n "$_tf" ]; then
  _tc=$(cat "$_tf" 2>/dev/null || echo 0)
  [ "$_tc" -ge 400 ] 2>/dev/null && warn "battery warm ($(( _tc / 10 ))C): charger may be throttling; results can be less reliable."
fi

[ -n "$ACCA" ] && "$ACCA" -D stop >/dev/null 2>&1 || :
nap

total=$(grep -cvE '^#|^$' "$SW" 2>/dev/null || echo "?")
say "testing $total switches (max ${MAX_S}s each)..."
say ""

# rc19: persist per-switch results so AccA diagnostics can show which method works and
# which does NOT on THIS phone (overwritten each scan).
RESLOG=$dataDir/logs/switch-test.log
mkdir -p $dataDir/logs 2>/dev/null || :
{ echo "# ACC switch test  device=$(getprop ro.product.device 2>/dev/null)  method=$METHOD"
  echo "# WORKS=stops charging  DRAINS=stops but cuts passthrough (rejected)  NOEFFECT=no stop  SKIP=not charging"
} > $RESLOG 2>/dev/null || :

results=
drained=0
n=0
BL=$TMPDIR/.sw-blacklist
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  # rc16: skip switches the runtime monitor parked as non-holding for this session
  [ -f "$BL" ] && grep -qxF "$line" "$BL" 2>/dev/null && continue
  n=$((n+1))
  printf '  %2d. %-56.56s ' "$n" "$line"
  r=$(test_switch "$line")
  set -- $r
  case "${1:-}" in
    ok)   klass=${4:-clean}; rok=${5:-0}
          say "STOPS ${2}ms [${3}/${klass}/$([ "$rok" = 1 ] && echo resumes || echo no-resume)]"
          if [ "$klass" = drain ]; then
            # NEVER lock a switch that kills charger passthrough -> drains while plugged
            say "        ^ rejected: blocks passthrough (battery would DRAIN while plugged)"
            echo "DRAINS   $line   (rejected: cuts charger passthrough -> would drain plugged)" >> $RESLOG 2>/dev/null || :
            drained=$((drained + 1))
          else
            echo "WORKS    $line   (${3}/${klass}/$([ "$rok" = 1 ] && echo resumes || echo no-resume), ${2}ms)" >> $RESLOG 2>/dev/null || :
            # rank: pcap-pcap=hold, pcap-5=cycle (ordered by chosen METHOD); plain
            # switches by mode; in Hold mode a bypass-classified switch wins. A switch
            # whose RESUME was not verified gets +4 so resume-verified ones (the real
            # X..Y guarantee) always sort ahead. Lowest score wins.
            P=4
            case "$line" in
              *\ pcap\ pcap) [ "$METHOD" = cycle ] && P=2 || P=0;;
              *\ pcap\ 5)    [ "$METHOD" = cycle ] && P=0 || P=2;;
              *) if [ "$METHOD" = hold ] && [ "$klass" = bypass ]; then P=0
                 else case "$3" in idle) P=1;; *) P=3;; esac; fi;;
            esac
            [ "$rok" = 1 ] || P=$((P + 4))
            results="${results}${P} ${2} ${3} ${line}
"
          fi
          ;;
    skip) say "(not charging — rerun while charging)"
          echo "SKIP     $line   (not charging during test)" >> $RESLOG 2>/dev/null || :;;
    *)    say "no effect"
          echo "NOEFFECT $line" >> $RESLOG 2>/dev/null || :;;
  esac
done < "$SW"

say ""
say "================ RESULT ================"
if [ -n "$results" ]; then
  say "Working switches (best first -- $([ "$METHOD" = cycle ] && echo 'Range Cycle' || echo 'Hold@Limit'), resume-verified, then fastest):"
  printf '%s' "$results" | sort -n -k1,1 -k2,2n | while read prio ms mode rest; do
    say "  [${ms}ms ${mode}]  $rest"
  done
  best=$(printf '%s' "$results" | sort -n -k1,1 -k2,2n | head -n1 | cut -d' ' -f4-)
  rm $TMPDIR/.autolock-noswitch 2>/dev/null || :
  { echo ""; echo "BEST(${METHOD})=${best}"; } >> $RESLOG 2>/dev/null || :
  say ""
  say "BEST=${best}"
  if [ "$APPLY" = 1 ] && [ -n "$best" ]; then
    [ -n "$ACCA" ] && "$ACCA" -s "s=${best} --" >/dev/null 2>&1 || :
    say "APPLIED=1   method=${METHOD}   (locked in: acc -s s='${best} --')"
  else
    say "Recommended ($([ "$METHOD" = cycle ] && echo 'Range Cycle' || echo 'Hold@Limit')) -- lock it in (stops ACC auto-cycling):"
    say "  acc -s s='${best} --'"
    say "  (re-run with --apply to lock it; --hold for Hold@Limit/bypass, --cycle for Range Cycle)"
  fi
  say ""
  say "Range Cycle = charge to your limit, discharge to resume, repeat (pcap 5)."
  say "Hold@Limit  = park/bypass at your limit, no charge or discharge (pcap pcap)."
else
  # rc16: leave a marker the daemon reads so a no-switch device is surfaced, never silent
  touch $TMPDIR/.autolock-noswitch 2>/dev/null || :
  if [ "$drained" -gt 0 ]; then
    say "NO SAFE switch found: the $drained switch(es) that stopped charging also block"
    say "charger passthrough here, so locking them would DRAIN the battery while plugged."
    say "Not locking any. This phone needs a bypass-capable node ACC does not have yet."
  else
    say "NO switch stopped charging on this device."
    say "Almost always the OS is overriding ACC. Do this, then rerun:"
    say "  Settings > Battery > turn OFF Adaptive Charging / charge optimization"
    say "If it STILL finds nothing, this device needs a charge node ACC doesn't"
    say "know yet — send this whole output back."
  fi
fi
say "======================================="
# daemon restart is handled by the EXIT trap
