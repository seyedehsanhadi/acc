#!/system/bin/sh
# acc-switch-scan.sh - fast & complete ACC charging-switch scanner
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
#   ...acc-switch-scan.sh --apply                 # + LOCK the "discharge-cycle" method (DEFAULT)
#   ...acc-switch-scan.sh --apply --hold          # + LOCK "Hold@Limit" / bypass instead
# (This header used to say --apply locked Hold@Limit and named --cycle as the opt-in. The code
#  has always defaulted METHOD=cycle and every message it prints says "Range Cycle (DEFAULT)", so
#  the header was the wrong half of the contradiction; the flag is --hold, and --cycle is a no-op
#  that selects the default.)
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
    # "[0-9]*" is "starts with a digit", not "is a number", so 4x was accepted into MAX_S and only
    # blew up later in arithmetic - after the scanner had already begun writing charging nodes.
    [0-9]*)
      case $_a in
        *[!0-9]*) echo "! ignoring malformed duration: $_a" >&2;;
        *) MAX_S=$_a;;
      esac
    ;;
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
#
# rc23 shipped this as `exec 8>"$TMPDIR/.scan.lock" && flock -n 8`, which ABORTED EVERY RUN on
# Android. Android's flock is toybox's, whose usage is `flock [-sxun] fd`: it takes a descriptor as
# an argument and cannot take one the shell opened for it, so `flock -n 8` returned non-zero with
# nothing whatsoever holding the lock. Measured identically on a Mi A3 (Magisk) and a Pixel 6a
# (KernelSU). All three of AccA's scan buttons run this file, so all three printed "another switch
# scan is already running" -- never true -- and did nothing. The 0-byte lock file was the other half
# of the evidence: `exec 8>` truncates it before any pid could be read back out.
#
# The replacement uses mkdir, which is atomic on every filesystem and needs no external tool. A
# holder that is gone (killed, or the phone rebooted mid-scan) is taken over rather than blocking
# every future scan forever, and the takeover check reads /proc/<pid>/cmdline so a RECYCLED pid
# cannot masquerade as a live scan. $TMPDIR is tmpfs and is wiped at boot, so a reboot clears it
# regardless; the /proc check is for the kill-mid-scan case within one boot.
_SCANLOCK=$TMPDIR/.scan.lock.d
_scan_alive() {   # $1 = pid -> true only if that pid is a LIVE switch scan that is not us
  case "${1:-}" in ''|*[!0-9]*) return 1;; esac
  [ "$1" = "$$" ] && return 1
  [ -d "/proc/$1" ] || return 1
  # rc23c: grep the file directly. This was `tr '\0' ' ' < cmdline | grep -q`, and that PIPELINE
  # wedged on a Mi A3: tr spinning in state R, grep -q blocked behind it, the calling suite's shell
  # parked in sigsuspend, and `timeout 300` unable to help because it waits on a child that never
  # exits. It cost 25 minutes of a run and would stall any unattended suite sweep the same way.
  # A single grep on the file has no pipe to wedge and no second process to inherit a stdin that
  # never closes. -a because cmdline is NUL-separated and grep would otherwise call it binary; the
  # NULs simply act as separators for the match.
  grep -qa acc-switch-scan "/proc/$1/cmdline" 2>/dev/null
}
if ! mkdir "$_SCANLOCK" 2>/dev/null; then
  _o=$(cat "$_SCANLOCK/pid" 2>/dev/null)
  if _scan_alive "$_o"; then
    warn "another switch scan is already running (pid $_o); aborting this one"
    exit 0
  fi
  warn "clearing a stale scan lock (pid ${_o:-unknown} is gone)"
fi
echo $$ > "$_SCANLOCK/pid" 2>/dev/null || :

# fix7: resolve the "pcap" off-token (used by limit-type switches like
# charge_stop_level) to the configured pause_capacity, falling back to the live
# capacity. This makes the scan test the same flat-hold value the daemon applies,
# so the limit node reads as a clean [idle] hold instead of a [discharging] drain.
# rc23: DO NOT resolve this from the configured pause level. It looks like a bug that the grep below
# matches nothing -- there is no `pause_capacity=` line in the config, the value is field 4 of the
# capacity array -- so the fallback to the LIVE battery level always wins. That fallback is not an
# accident to be repaired; it is the only thing that makes the token work.
#
# pcap is the OFF value written to a limit node DURING A SCAN. Resolved to the live level, writing it
# stops charging immediately, which is the observable the switch test needs. Resolved to the
# configured pause -- 76 while you scan at 55% -- the firmware would not stop at all, and the scan
# would record a perfectly good level switch as "no effect". The daemon can use the configured value
# because it only applies it once the pack has REACHED that level; a scan has not.
#
# A change here was written and reverted on 2026-08-11 for exactly this reason. Leave it alone.
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
# rc22b: the same filter restore_all_on carries. The sweep was fixed and this was not, so a scan
# still ended with the charger-input nodes pinned at whatever they read at probe time instead of
# released high - on a Mi A3 that is usb/current_max back at 2.2A after ACC had negotiated 2.8A.
# These nodes are owned by charger negotiation; ACC's rule everywhere else is release HIGH and let
# the driver clamp, never replay a snapshot.
# rc23: the filter has to be PER NODE. A switch line is a sequence of "<node> <on> <off>" triples and
# grouped lines are real -- the tester emits them (a Pixel's four current paths go on one line, and a
# OnePlus pairs charging_enabled with op_disable_charge). This matched the whole LINE, so a single
# current_max anywhere on it skipped the restore of every other node on that line, including the
# input_suspend that was doing the cutting. That leaves the phone not charging until a reboot, which
# is the exact failure restore_all_on exists to prevent.
# rc23b: this must NOT carry restore_all_on's filter, and carrying it was a real bug.
#
# The two functions look alike and are not. restore_all_on sweeps the WHOLE switch file, which can
# hold a probe-time SNAPSHOT line for a current node (usb/current_max 2200000 0) appended by
# read-ch-curr-ctrl-files-p2.sh; replaying a snapshot hands back a stale negotiated value, so
# skipping current nodes there is correct. restore_on replays the CANDIDATE'S OWN line, whose ON
# field is the high release value (main/current_max 3000000 0 -> write 3000000). That is exactly
# ACC's rule everywhere else: release HIGH and let the driver clamp.
#
# With the filter here, a current node written to its OFF value (0) by write_off was never put back
# by anything. Measured on a Mi A3 after one scan: main/current_max, pc_port/current_max,
# usb/current_max, battery/constant_charge_current, battery/constant_charge_current_max,
# main/constant_charge_current_max and battery/charge_control_limit ALL left at 0. Two consequences,
# both bad. The phone is left unable to draw current until something else rewrites those nodes. And
# every candidate tested AFTER a current node is measured on a phone that can no longer charge, so
# a switch that works is recorded as "no effect" -- the scan contaminates its own remaining results.
restore_on() {
  local _restore=
  set -f; set -- ${1-}; set +f
  while [ $# -ge 3 ]; do
    [ "$1" = "--" ] && { shift 3; continue; }
    _restore="$_restore $1 $2 $3"; shift 3
  done
  [ -n "$_restore" ] && _write on "$_restore"
  return 0
}

# The sweep's variant: same PER-NODE walk, but current nodes are dropped because the sweep reads
# lines it did not write and one of them may be a snapshot. Per node, never per line: a grouped line
# is real (a Pixel's four current paths share one, a OnePlus pairs charging_enabled with
# op_disable_charge), and filtering the whole line would skip the input_suspend doing the cutting.
restore_on_safe() {
  local _restore=
  set -f; set -- ${1-}; set +f
  while [ $# -ge 3 ]; do
    case "$1" in
      --|*/current_max|*/input_current*|*/constant_charge_current*|*restrict_cur*) shift 3; continue;;
    esac
    _restore="$_restore $1 $2 $3"; shift 3
  done
  [ -n "$_restore" ] && _write on "$_restore"
  return 0
}

# rc23b: the baseline every candidate is measured against has to be REAL, not assumed.
#
# test_switch decides "this switch stopped charging" by comparing current against a baseline it read
# just before writing. If the previous candidate left the phone unable to charge, that baseline is
# taken on a dead phone and every later verdict is noise. Restoring is necessary but not sufficient:
# a node can refuse the write, or the charger can need a moment to renegotiate after being cut.
#
# So after each candidate is put back, wait for current to actually come back before testing the
# next one, and if it does not, say so rather than reporting confident nonsense for the remainder.
baseline_ok() {   # 0 = charging current is back
  local _i=0
  while [ "$_i" -lt 24 ]; do
    [ "$(abs "$(raw)")" -gt "$THR" ] 2>/dev/null && return 0
    nap; _i=$((_i+1))
  done
  return 1
}

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
  #
  # rc22: but SKIP the input-negotiation nodes. $SW carries two kinds of line for them: the
  # deliberate HIGH release from ctrl-files.sh (*/current_max 3000000 0) and a probe-time SNAPSHOT
  # appended by read-ch-curr-ctrl-files-p2.sh (usb/current_max 2200000 0). awk '!seen[$0]++' keeps
  # first-occurrence order, so the snapshot sits after the high line and this sweep, going top to
  # bottom, makes the SNAPSHOT the final value. On a Mi A3 that ends a scan with usb/current_max
  # back at 2.2A after ACC had negotiated it to 2.8A - handing back the entire measured advantage
  # for the rest of the session, silently, with no re-kick behind it.
  #
  # These nodes do not need restoring HERE. They are owned by charger negotiation, and ACC's
  # standing rule everywhere else is release HIGH and let the driver clamp, never replay a
  # snapshot - see set-ch-curr.sh, which documents this same hazard and pairs its restore with a
  # re-kick. The candidate's own line IS released high, by restore_on, right after it is tested.
  #
  # rc23b: the skip is now per NODE (restore_on_safe), not per line. This dropped the whole line on
  # any match, so a grouped line - which the tester really does emit - lost the restore of every
  # other node on it, including the input_suspend that was doing the cutting. That is the exact
  # "no charge until reboot" failure this sweep exists to prevent.
  [ -f "${SW:-/x}" ] || return 0
  while IFS= read -r _l; do
    case "$_l" in ''|'#'*) continue;; esac
    restore_on_safe "$_l" 2>/dev/null || :
  done < "$SW"
}
# rc23: THE reason the scanner was left inert. `acca -D restart` ends, inside daemon_ctrl, in
# `exec $TMPDIR/accd` -- the process we spawn does not merely start the daemon, it BECOMES the
# daemon. Called plainly from cleanup that daemon inherits this script's session, process group and
# stdio, so it dies the moment the script exits or the caller's pipe closes, and no amount of
# retrying inside cleanup can help: every retry inherits the same doom. That is why 25 s of retries
# plus an `acc -D restart` fallback still ended with no daemon on both phones, while the identical
# command run by hand from a surviving shell worked in about 2 s.
#
# setsid puts it in a session of its own, with stdio on /dev/null so a closed pipe cannot reach it.
# Exactly the fix `acc -t` carries for exactly the same defect.
# rc23b: `pgrep -f accd.sh` IS NOT A DAEMON CHECK, and using it made cleanup lie.
#
# release-lock.sh runs `pkill -f /data/adb/vr25/acc/accd.sh` and service.sh runs
# `start-stop-daemon -bx /data/adb/vr25/acc/accd.sh -S`. Both carry that path in their OWN argv, so
# `pgrep -f accd.sh` matches the machinery that tears the daemon down and the launcher that has not
# started it yet. Measured: a scan reported "ACC daemon restarted; charging is back under ACC
# control" and there was no daemon 45 seconds later; the wait loop had matched a transient that
# lived two seconds at t+62.
#
# Match the daemon itself: a shell running accd.sh as its script argument, and never a helper that
# merely names it.
# True only for the daemon itself. Substring matching is not enough and that is the whole point:
# `pkill -f <execDir>/accd.sh` and `start-stop-daemon -bx <execDir>/accd.sh -S` both CONTAIN the
# path, and so does any helper invoked with it. The daemon is specifically a shell whose SCRIPT
# argument is accd.sh, which none of those are. Excluding the known helpers by name would be a
# blacklist that the next helper defeats; this is a positive test for the real shape.
_is_accd() {   # $1 = pid
  local _pid=${1:-} _c
  case "$_pid" in ''|*[!0-9]*) return 1;; esac
  [ -r "/proc/$_pid/cmdline" ] || return 1
  _c=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
  [ -n "$_c" ] || return 1
  set -f; set -- $_c; set +f
  case "${1:-}" in sh|*/sh|mksh|*/mksh|bash|*/bash|busybox|*/busybox) ;; *) return 1;; esac
  [ "${1##*/}" = busybox ] && shift          # busybox sh <script>
  case "${2:-}" in */accd.sh|accd.sh) return 0;; esac
  return 1
}
daemon_alive() {
  local _p
  for _p in $(pgrep -f "accd.sh" 2>/dev/null); do
    _is_accd "$_p" && return 0
  done
  return 1
}

restart_daemon_detached() {
  [ -n "$ACCA" ] || return 1
  if command -v setsid >/dev/null 2>&1; then
    setsid "$ACCA" -D restart </dev/null >/dev/null 2>&1 &
  else
    nohup "$ACCA" -D restart </dev/null >/dev/null 2>&1 &
  fi
  return 0
}
cleanup() {
  # release the single-instance mutex only if this process still owns it, so a scan that started
  # while we were exiting is not unlocked out from under itself
  [ "$(cat "${_SCANLOCK:-/nonexistent}/pid" 2>/dev/null)" = "$$" ] && rm -rf "$_SCANLOCK" 2>/dev/null
  [ -n "$cur_line" ] && restore_on "$cur_line" 2>/dev/null
  restore_all_on
  restart_daemon_detached || :
  # fix10: confirm the daemon actually came back. `acca -D restart` now detaches it,
  # but verify so a failed restart is never silent -- a stopped daemon = no cap.
  # `acca -D` exits 0 when accd holds its lock (running), 9 when it does not.
  # rc23: wait in SECONDS, and try the restart again before giving up.
  # This waited `nap` x8, and nap is usleep STEP_MS -- 300 ms -- so the whole window was 2.4 s
  # against a restart measured at about 2 s on a Mi A3. It was a coin flip, and losing it printed
  # "charging is currently UNCAPPED" at a user whose daemon was about to come back on its own.
  # Nobody had seen it because the single-instance guard above aborted every run before this line.
  up=0
  if [ -n "$ACCA" ]; then
    i=0; while [ "$i" -lt 20 ]; do
      daemon_alive && { up=1; break; }
      [ "$i" = 9 ] && restart_daemon_detached   # one more push half way through
      sleep 1; i=$((i+1))
    done
  fi
  # last resort: the module's own CLI, which resolves the daemon differently. Detached for the same
  # reason as above -- a bare `acc -D restart` here execs accd into this dying script's session.
  if [ "$up" = 0 ] && command -v acc >/dev/null 2>&1; then
    if command -v setsid >/dev/null 2>&1; then
      setsid acc -D restart </dev/null >/dev/null 2>&1 &
    else
      nohup acc -D restart </dev/null >/dev/null 2>&1 &
    fi
    i=0; while [ "$i" -lt 20 ]; do
      daemon_alive && { up=1; break; }
      sleep 1; i=$((i+1))
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
# HUP as well as INT/TERM, matching acc.sh's exxit trap and AMPS's restore trap. This scan works by
# writing every candidate node to its OFF value in turn, and SIGHUP is what arrives when the terminal
# or adb session that launched an unattended scan goes away - the likeliest way one is interrupted in
# the field. Without it cleanup never runs: candidates stay cut and no daemon comes back, so charging
# is uncapped on a phone whose owner thinks a scan is still in progress. EXIT does not cover this; a
# shell killed by an uncaught signal dies without running its EXIT trap.
# Signals need their own trap. cleanup() RETURNS, it does not exit, so handling INT/TERM/HUP with a
# bare `trap cleanup` restored the nodes, restarted the daemon, and then let the scan resume from
# where it was interrupted -- writing charge switches again, now concurrently with the daemon it
# had just brought back, and running cleanup a second time from the EXIT trap. Ctrl-C did not stop
# the scanner. Exit explicitly on a signal; keep the plain EXIT trap for the normal path.
trap 'cleanup; exit 130' INT TERM HUP
trap cleanup EXIT

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
anyResume=0   # rc5 (#15): set when any switch is resume-verified (rok=1); --apply refuses a no-resume-only result

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
  local line=$1 base baseRaw chgNeg revd nr now i ms mode lim klass inb rok held ci cnr cnow crev
  # widened 14->20 polls: some chargers renegotiate USB-PD on each toggle and take
  # longer to resume to the charging baseline; do not falsely "skip" them.
  i=0; while [ "$(abs "$(raw)")" -le "$THR" ] 2>/dev/null && [ "$i" -lt 20 ]; do nap; i=$((i+1)); done
  baseRaw=$(raw); base=$(abs "$baseRaw")
  [ "$base" -gt "$((THR / 2))" ] 2>/dev/null || { echo skip; return; }   # rc5 (#14): skip only at near-zero baseline; trickle/high-SOC still tests (reversal-based detection below)
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
      # rc(6.4): SUSTAINED-hold confirm (mirrors the daemon's cycle_switches). The detection
      # above fires on a SINGLE sample -- a switch that stops current for one read then lets
      # the firmware re-arm (MTK current_cmd on Xiaomi/HyperOS klee) would otherwise be
      # accepted and --apply-LOCKED here. Re-sample a few times; if current returns to the
      # charging direction above THR, it did NOT hold -> fail (do not lock a non-holding switch).
      held=1; ci=0
      # rc6 (F4): confirm the hold for >~3s, not 0.9s. The firmware re-arm this guards against
      # (MTK current_cmd on Xiaomi/HyperOS klee) bounces back at ~loopDelay[0]=3s, which a
      # 3x300ms=0.9s window missed -> a non-holding switch got --apply-LOCKED. Sample across
      # ~4.5s so a brief stop-then-rearm is caught here, like the daemon's own sustained check.
      while [ "$(( ci * STEP_MS ))" -lt 4500 ]; do
        nap; ci=$((ci+1)); cnr=$(raw); cnow=$(abs "$cnr"); crev=0
        if [ "$chgNeg" = 1 ]; then [ "$cnr" -gt 0 ] 2>/dev/null && crev=1; else [ "$cnr" -lt 0 ] 2>/dev/null && crev=1; fi
        [ "$crev" = 0 ] && [ "$cnow" -ge $(( base / 3 )) ] 2>/dev/null && { held=0; break; }
      done
      [ "$held" = 1 ] || { restore_on "$line"; cur_line=; echo fail; return; }
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
# rc23b: build the list rather than telling the user to run a command that does not build it.
#
# $SW is written only by the daemon's INIT path (accd.sh with -i, or when its cached battery
# interface is unusable). A plain `acc -D restart` does NOT rebuild it, so the old remedy here --
# "run 'acc -D restart' once, then retry" -- was wrong, and following it left the user in exactly
# the same place. On a phone that has been up a while the file is simply absent, because $TMPDIR is
# tmpfs and only the boot-time init populated it.
#
# The scan is about to stop the daemon anyway, so asking for an init first costs nothing it was not
# already going to spend.
if [ ! -s "$SW" ]; then
  say "building the switch list (first run since boot)..."
  if [ -n "$ACCA" ]; then
    "$ACCA" -D stop >/dev/null 2>&1 || :
    if command -v setsid >/dev/null 2>&1; then
      setsid $TMPDIR/accd --init </dev/null >/dev/null 2>&1 &
    else
      nohup $TMPDIR/accd --init </dev/null >/dev/null 2>&1 &
    fi
    _iw=0
    while [ "$_iw" -lt 45 ]; do
      [ -s "$SW" ] && break
      sleep 1; _iw=$((_iw+1))
    done
  fi
fi
[ -s "$SW" ] || { warn "no switch list at $SW, and building one did not produce it."; \
                  warn "  Reboot once and re-run: the list is written when ACC starts at boot."; exit 1; }

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

# `|| :`, not `|| echo "?"`: grep -c prints its count and THEN exits non-zero when that count is
# zero, so the fallback appended a second value and $total became "0 ?" -- which every later
# arithmetic and comparison on it then mis-read.
total=$(grep -cvE '^#|^$' "$SW" 2>/dev/null || :)
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
contaminated=0
BL=$TMPDIR/.sw-blacklist
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  # rc16: skip switches the runtime monitor parked as non-holding for this session
  [ -f "$BL" ] && grep -qxF "$line" "$BL" 2>/dev/null && continue
  n=$((n+1))
  # rc23b: prove the phone is back to a charging baseline BEFORE this candidate is measured, so a
  # residue from the previous one cannot be read as this one's verdict. Only meaningful once at
  # least one candidate has been written; the very first read is the run's own baseline.
  if [ "$n" -gt 1 ] && [ "$contaminated" = 0 ]; then
    if ! baseline_ok; then
      contaminated=1
      say ""
      # One self-contained line first, so this is greppable. The wrapped prose below split
      # "cannot be trusted" across two lines, which defeated a grep looking for exactly that.
      say "  ! RESULTS-UNTRUSTWORTHY: charging did not resume between switches."
      say "    Everything from here on was measured on a phone that is not charging, so a switch"
      say "    that works can be recorded as 'no effect'. Unplug, replug and re-run; if it happens"
      say "    again, send this output back."
      say ""
    fi
  fi
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
            [ "$rok" = 1 ] && anyResume=1 || :
            results="${results}${P} ${2} ${3} ${line}
"
          fi
          ;;
    skip) say "(not charging - rerun while charging)"
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
  if [ "$APPLY" = 1 ] && [ -n "$best" ] && [ "${contaminated:-0}" = 1 ]; then
    # rc23b: the run already told the user its later results cannot be trusted, because charging did
    # not come back between candidates. Locking a switch chosen from that data is exactly how a phone
    # ends up on a switch that does not work. Observed live on a Pixel 6a: four drain-type switches
    # cut passthrough, charging stayed down, and candidates 10 through 21 were all measured on a
    # phone that was not charging -- any of which could have been the "best" here.
    say "NOT auto-locked: charging stopped part-way through, so the ranking is unreliable."
    say "  Unplug, replug and re-run. Only lock a switch from a run with no such warning."
  elif [ "$APPLY" = 1 ] && [ -n "$best" ] && [ "$anyResume" = 1 ]; then
    [ -n "$ACCA" ] && "$ACCA" -s "s=${best} --" >/dev/null 2>&1 || :
    say "APPLIED=1   method=${METHOD}   (locked in: acc -s s='${best} --')"
  elif [ "$APPLY" = 1 ] && [ -n "$best" ]; then
    # rc5 (#15): --apply but NO switch verified that charging RESUMES (all stop-only). Locking one
    # could leave charging stuck off. Recommend instead of auto-locking.
    say "NOT auto-locked: no switch verified that charging RESUMES. Confirm resume first, then: acc -s s='${best} --'"
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
    say "know yet - send this whole output back."
  fi
fi
say "======================================="
# daemon restart is handled by the EXIT trap
