#!/system/bin/sh
# $id early-cap -- runs at Magisk post-fs-data (EARLY boot, before the daemon)
# Copyright 2017-2024, VR25 / ACC contributors
# License: GPLv3+
#
# rc14 (B-boot): close the multi-minute window where charging is UNCONTROLLED after every
# reboot. service.sh (late_start_service) deliberately waits for the lock screen / boot_completed
# before starting the daemon -- up to ~3 min -- so a phone that rebooted while sitting at the pause
# limit happily charges PAST it until accd finally enforces. This one-shot reads the SAME config the
# daemon uses and, if already at/over pause_capacity, applies the configured switch's OFF value right
# now. The daemon takes over (resume/verify/fallback) once it starts; this only covers the gap.
#
# SAFETY MODEL (this script runs at the most bootloop-sensitive boot stage, so every line is defensive):
#   * one-shot, no loops, no daemons spawned, no fallback switch-cycling (the daemon does all that later);
#   * the actual work runs under a 6 s `timeout` re-invocation so it can NEVER block boot, even if a
#     sysfs write wedges; on hang the watchdog kills it and boot proceeds;
#   * bootloop self-heal: a counter incremented here and CLEARED by service.sh on a good boot; 3 strikes
#     without a clear (= boots never reaching late_start_service) latches `.no-early-cap` and bows out;
#   * fail-OPEN: if capacity/pause/switch can't be read with confidence, do NOTHING (let it charge -- the
#     daemon manages within minutes). Cutting on bad data could strand a low battery, which is worse;
#   * multiple hard escape hatches (module disable, acc disable, user opt-out) checked before anything.
# Test gate: `sh post-fs-data.sh --selftest` (9-case synthetic matrix, pure -- no real sysfs/boot).

id=acc
domain=vr25
dataDir=${EARLYCAP_DATA:-/data/adb/$domain/${id}-data}
execDir=/data/adb/$domain/$id
config=${EARLYCAP_CFG:-$dataDir/config.txt}
PS=${EARLYCAP_PS:-/sys/class/power_supply}
log=$dataDir/logs/early-cap.log

_ts() { date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo T; }

# pause_capacity is the 4th field of `capacity=(<shutdown> <coolDown> <resume> <pause> [mask])`.
# Parsed by position, not sourced -- never execute the config.
_pause() {
  _cl=$(grep -m1 '^capacity=' "$1" 2>/dev/null | sed -e 's/^capacity=(//' -e 's/).*$//')
  # shellcheck disable=SC2086
  set -- $_cl
  echo "${4:-}"
}

# Read the battery level from the KERNEL (Android/dumpsys is not up yet at post-fs-data).
# Prefer the canonical nodes, then any */capacity whose sibling type reads Battery. Empty/garbage
# is skipped, so a blank read can never become a bogus numeric compare.
_level() {
  for _c in "$PS"/battery/capacity "$PS"/bms/capacity; do
    [ -f "$_c" ] || continue
    _v=$(cat "$_c" 2>/dev/null)
    case ${_v:-x} in ''|*[!0-9]*) continue;; esac
    echo "$_v"; return 0
  done
  for _d in "$PS"/*/; do
    [ -f "$_d/capacity" ] || continue
    case "$(cat "$_d/type" 2>/dev/null)" in Battery) ;; *) continue;; esac
    _v=$(cat "$_d/capacity" 2>/dev/null)
    case ${_v:-x} in ''|*[!0-9]*) continue;; esac
    echo "$_v"; return 0
  done
  return 1
}

# Apply the OFF (stop) value of each switch triplet, mirroring flip_sw/disable_charging:
# write field-3 to each <node on off> group, resolving the "pcap" token to pause_capacity and
# SKIPPING non-numeric OFF values (e.g. 3600mV float-voltage switches -- the daemon owns those).
# Must be called with cwd == $PS so relative nodes (battery/input_suspend) resolve like the daemon.
# Echoes the nodes actually written.
_cut() {
  _sw=$1; _pz=$2; _wrote=
  # shellcheck disable=SC2086
  set -- $_sw
  while [ $# -ge 3 ] && [ -f "$1" ]; do
    _off=$3
    [ "$_off" = pcap ] && _off=$_pz
    case ${_off:-x} in ''|*[!0-9]*) shift 3; continue;; esac
    chmod a+w "$1" 2>/dev/null || :
    if echo "$_off" > "$1" 2>/dev/null; then _wrote="$_wrote $1"; fi
    shift 3
  done
  echo "$_wrote"
}

# The capping decision + action. cwd-independent (cd's into $PS itself). Always returns 0 -- boot
# must never see a nonzero from here.
_run() {
  sw=$(grep -m1 '^chargingSwitch=' "$config" 2>/dev/null | sed -e 's/^chargingSwitch=(//' -e 's/).*$//')
  case "$sw" in ''|'--'*) echo "$(_ts) no switch configured; skip" >> "$log" 2>/dev/null; return 0;; esac
  pause=$(_pause "$config")
  case ${pause:-x} in ''|*[!0-9]*) echo "$(_ts) bad/absent pause '$pause'; skip" >> "$log" 2>/dev/null; return 0;; esac
  { [ "$pause" -ge 1 ] && [ "$pause" -le 100 ]; } || { echo "$(_ts) pause $pause out of range; skip" >> "$log" 2>/dev/null; return 0; }
  level=$(_level) || { echo "$(_ts) cannot read level; skip (fail-open)" >> "$log" 2>/dev/null; return 0; }
  if [ "$level" -lt "$pause" ]; then
    echo "$(_ts) level $level < pause $pause; let charge (daemon will manage)" >> "$log" 2>/dev/null
    return 0
  fi
  cd "$PS" 2>/dev/null || { echo "$(_ts) no $PS; skip" >> "$log" 2>/dev/null; return 0; }
  wrote=$(_cut "$sw" "$pause")
  case "$wrote" in
    *[!\ ]*) echo "$(_ts) level $level >= pause $pause -> early-cut wrote:$wrote" >> "$log" 2>/dev/null;;
    *)       echo "$(_ts) level $level >= pause $pause but no node written (switch not present early?)" >> "$log" 2>/dev/null;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# --selftest : synthetic matrix for the capping core. No real sysfs, no boot.
# ---------------------------------------------------------------------------
_selftest() {
  _T=${TMPDIR:-/data/local/tmp}/ec-selftest.$$
  _pass=0; _fail=0
  _mkps() { rm -rf "$_T/ps"; mkdir -p "$_T/ps"; }
  _node() { mkdir -p "$_T/ps/${1%/*}"; printf '%s' "$2" > "$_T/ps/$1"; }
  _cfg() { printf 'chargingSwitch=(%s)\ncapacity=(%s)\n' "$1" "$2" > "$_T/config"; }
  _read() { cat "$_T/ps/$1" 2>/dev/null; }
  _check() { # desc expected actual
    if [ "$2" = "$3" ]; then _pass=$((_pass+1)); else _fail=$((_fail+1)); echo "  FAIL: $1 (want [$2] got [$3])"; fi
  }
  _do() { ( EARLYCAP_CFG="$_T/config" EARLYCAP_PS="$_T/ps" config="$_T/config" PS="$_T/ps" log=/dev/null; _run ) >/dev/null 2>&1; }

  # 1: over-limit single-node input-cut -> OFF(1) written
  _mkps; _node battery/capacity 80; _node battery/input_suspend 0
  _cfg "battery/input_suspend 0 1 --" "5 101 72 74 false"; _do
  _check "over-limit cut" 1 "$(_read battery/input_suspend)"

  # 2: under-limit -> untouched
  _mkps; _node battery/capacity 70; _node battery/input_suspend 0
  _cfg "battery/input_suspend 0 1 --" "5 101 72 74 false"; _do
  _check "under-limit no-op" 0 "$(_read battery/input_suspend)"

  # 3: exactly-at-limit (>=) -> cut
  _mkps; _node battery/capacity 74; _node battery/input_suspend 0
  _cfg "battery/input_suspend 0 1 --" "5 101 72 74 false"; _do
  _check "at-limit cut" 1 "$(_read battery/input_suspend)"

  # 4: pcap OFF token resolves to pause_capacity
  _mkps; _node battery/capacity 80; _node battery/charge_stop_level 100
  _cfg "battery/charge_stop_level 100 pcap" "5 101 72 74 false"; _do
  _check "pcap->pause" 74 "$(_read battery/charge_stop_level)"

  # 5: multi-node group -> every node written
  _mkps; _node battery/capacity 80; _node a/x 0; _node b/y 0
  _cfg "a/x 0 1 b/y 0 1" "5 101 72 74 false"; _do
  _check "multinode x" 1 "$(_read a/x)"; _check "multinode y" 1 "$(_read b/y)"

  # 6: non-numeric OFF (voltage switch) is skipped, not corrupted
  _mkps; _node battery/capacity 80; _node battery/voltage_max 4400000
  _cfg "battery/voltage_max 4400000 3600mV" "5 101 72 74 false"; _do
  _check "voltage skip" 4400000 "$(_read battery/voltage_max)"

  # 7: bad pause field -> fail-open (no write)
  _mkps; _node battery/capacity 80; _node battery/input_suspend 0
  _cfg "battery/input_suspend 0 1 --" "5 101 72 x false"; _do
  _check "bad pause fail-open" 0 "$(_read battery/input_suspend)"

  # 8: unreadable capacity -> fail-open
  _mkps; _node battery/input_suspend 0
  _cfg "battery/input_suspend 0 1 --" "5 101 72 74 false"; _do
  _check "no level fail-open" 0 "$(_read battery/input_suspend)"

  # 9: empty switch -> no-op
  _mkps; _node battery/capacity 80; _node battery/input_suspend 0
  _cfg "" "5 101 72 74 false"; _do
  _check "empty switch no-op" 0 "$(_read battery/input_suspend)"

  rm -rf "$_T" 2>/dev/null
  echo "early-cap selftest: $_pass passed, $_fail failed"
  [ $_fail -eq 0 ]
}

case "${1-}" in
  --selftest) _selftest; exit $?;;
  --version) echo "acc early-cap (post-fs-data) rc14"; exit 0;;
  __work) _run; exit 0;;
esac

# ---------------------------------------------------------------------------
# production boot path (Magisk post-fs-data)
# ---------------------------------------------------------------------------
MODDIR=${0%/*}
[ -f "$MODDIR/disable" ] && exit 0          # Magisk per-module disable
[ -f "$execDir/disable" ] && exit 0         # acc -x / global disable
[ -f "$dataDir/disable" ] && exit 0
[ -f "$dataDir/.no-early-cap" ] && exit 0   # user opt-out OR a prior self-heal latch
[ -f "$config" ] || exit 0                  # nothing configured (fresh install) -> nothing to cap
mkdir -p "$dataDir/logs" 2>/dev/null || :

# bootloop self-heal: increment here, service.sh clears on a good boot. 3 unreached-late_start
# boots => assume we are implicated and latch off. Counter parse is garbage-proof.
bc=$dataDir/.early-boot-count
n=$(cat "$bc" 2>/dev/null); case ${n:-0} in ''|*[!0-9]*) n=0;; esac
n=$((n+1)); echo "$n" > "$bc" 2>/dev/null || :
if [ "$n" -ge 3 ]; then
  echo "$(_ts) boot-count $n>=3 without a good boot; self-disabling early-cap (.no-early-cap)" >> "$log" 2>/dev/null
  touch "$dataDir/.no-early-cap" 2>/dev/null || :
  exit 0
fi

# Run the capping time-boxed so it can NEVER hang the post-fs-data stage. Re-invoke ourselves with
# __work under `timeout`; if timeout is unavailable, emulate it with a background job + sleep-kill.
if command -v timeout >/dev/null 2>&1; then
  timeout 6 sh "$0" __work >> "$log" 2>&1 || echo "$(_ts) early-cap work timed out/failed; boot continues" >> "$log" 2>/dev/null
else
  sh "$0" __work >> "$log" 2>&1 &
  _w=$!
  ( sleep 6; kill -9 "$_w" 2>/dev/null ) 2>/dev/null &
  wait "$_w" 2>/dev/null || :
fi
exit 0
