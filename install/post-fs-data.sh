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
#   * the actual work runs under a 6 s `timeout` re-invocation so a slow or looping write cannot delay
#     boot beyond that -- the watchdog kills it and boot proceeds. CAVEAT: a sysfs write that wedges the
#     kernel in TASK_UNINTERRUPTIBLE (D-state) cannot be killed by any signal, `timeout` included; that
#     is a driver-level hang no userland can pre-empt. The write-ahead journal still blacklists such a
#     node on the NEXT boot (if the kernel hung-task detector reboots), and the flashable uninstaller
#     recovers it either way -- so it is a bounded, recoverable hang, never a silent EDL loop;
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
# Battery millivolts, same node-selection rule as _level. Needed because a pause capacity may be
# expressed in mV: set-prop.sh accepts 3001-5000 as a documented domain and `acc 3900` sets one,
# but early-cap only ever compared a PERCENT, so an mV config fell straight through its range test
# and skipped the boot-gap cut entirely -- fail-open, on the one path that exists to close the
# window before the daemon starts.
_mvolt() {
  for _c in "$PS"/battery/voltage_now "$PS"/bms/voltage_now; do
    [ -f "$_c" ] || continue
    _v=$(cat "$_c" 2>/dev/null)
    case ${_v:-x} in ''|*[!0-9]*) continue;; esac
    [ "$_v" -ge 100000 ] 2>/dev/null && _v=$(( _v / 1000 ))
    echo "$_v"; return 0
  done
  for _d in "$PS"/*/; do
    [ -f "$_d/voltage_now" ] || continue
    case "$(cat "$_d/type" 2>/dev/null)" in Battery) ;; *) continue;; esac
    _v=$(cat "$_d/voltage_now" 2>/dev/null)
    case ${_v:-x} in ''|*[!0-9]*) continue;; esac
    [ "$_v" -ge 100000 ] 2>/dev/null && _v=$(( _v / 1000 ))
    echo "$_v"; return 0
  done
  return 1
}

_system_policy_active() {
  for _sp in "$PS"/*/charging_policy; do
    [ -r "$_sp" ] || continue
    _sv=; { read -r _sv < "$_sp"; } 2>/dev/null || :
    case ${_sv:-x} in ''|x|*[!0-9]*) continue;; esac
    [ "$_sv" -gt 1 ] 2>/dev/null && return 0
  done
  return 1
}

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
  # rc21: never cut in offline charging mode -- the phone is powered OFF with the cable in,
  # running Android's `charger` binary, and a cut drives online=0 which that binary reads as an
  # unplug and powers the device off. Captured on a Mi A3:
  #   [charger] charger: device unplugged, shutting down / reboot: Power down
  # A phone left charging overnight would be found dead instead of full.
  # Only the boot-mode property can tell here: this runs before Android either way, so the
  # zygote test the daemon uses would wrongly match a NORMAL early boot and disable the early
  # cap for everyone. Absent/unknown prop = proceed, so no device loses the cap by accident.
  case "$(getprop ro.bootmode 2>/dev/null)$(getprop ro.boot.mode 2>/dev/null)" in
    *charger*) echo ""; return 0;;
  esac
  # shellcheck disable=SC2086
  set -- $_sw
  while [ $# -ge 3 ]; do
    [ -f "$1" ] || { shift 3; continue; }
    _off=$3
    [ "$_off" = pcap ] && _off=$_pz
    case ${_off:-x} in ''|*[!0-9]*) shift 3; continue;; esac
    chmod a+w "$1" 2>/dev/null || :
    if echo "$_off" > "$1" 2>/dev/null; then _wrote="$_wrote $1"; fi
    shift 3
  done
  echo "$_wrote"
}

# _pending_check: run ONCE at boot (production path). If the previous boot ARMED the early-cap
# journal but never disarmed it, our early-cut write kernel-panicked / crash-rebooted the device
# mid-write. Permanently blacklist that switch (so neither early-cap nor accd ever writes it again)
# and latch early-cap off. Returns 0 when it fired (caller exits), 1 otherwise. Brick-safe: this is
# what turns a #305-class panic into ONE crash instead of an EDL-bound boot loop.
# rc21: node-level blacklist test with the same semantics as misc-functions.sh's sw_blacklisted,
# but self-contained -- post-fs-data runs before anything else and must not source the daemon env.
# Reads BOTH lists by LEADING FIELD. The first cut of this check used `grep -qxF` against
# .probe-blacklist alone, which could never match anything: the config's switch spec is
# "node on off --", the probe list stores three fields, and AMPS stores "path<TAB>value<TAB>when".
# So a node AMPS had recorded as taking the phone down was still written at the single most
# panic-sensitive stage of boot -- the boot loop this file exists to prevent.
_bl_node() {
  [ -n "${1:-}" ] || return 1
  _bn=${1##*/power_supply/}; _bf=/sys/class/power_supply/$_bn
  _bcr=$(printf '\r'); _btab=$(printf '\t')
  for _blf in "$dataDir/.acc-compat-blacklist" "$dataDir/.probe-blacklist"; do
    [ -s "$_blf" ] || continue
    while IFS= read -r _bl || [ -n "${_bl:-}" ]; do
      _bl=${_bl%"$_bcr"}
      case "$_bl" in ''|'#'*) continue;; esac
      _bl=${_bl%%"$_btab"*}; _bl=${_bl%% *}
      [ "$_bl" = "$1" ] || [ "$_bl" = "$_bf" ] || [ "$_bl" = "$_bn" ] || continue
      return 0
    done < "$_blf"
  done
  return 1
}

# Is any node in a switch SPEC ("node on off --", possibly grouped) blocked?
_bl_spec() {
  for _bs in $1; do
    case "$_bs" in --) break;; */*) _bl_node "$_bs" && return 0;; esac
  done
  return 1
}

_pending_check() {
  [ -f "$dataDir/.earlycap-pending" ] || return 1
  _ecp=$(cat "$dataDir/.earlycap-pending" 2>/dev/null)
  if [ -n "$_ecp" ]; then
    # Latch and blacklist are deliberately split. Latching early-cap off is cheap and reversible:
    # the daemon still enforces the limit seconds later, so the user loses only the boot-gap
    # protection. Blacklisting is PERMANENT and also stops the daemon writing that node, i.e. it
    # can cost the user their only working switch. The journal alone cannot tell a kernel panic
    # from this file's own `timeout 6` firing on a merely slow cut, so blacklist only with the
    # same panic evidence AMPS demands, and always latch. A slow switch loses the early cut; a
    # deadly one loses everything.
    _br="$(getprop sys.boot.reason 2>/dev/null)$(getprop ro.boot.bootreason 2>/dev/null)"
    case "$_br" in
      *panic*|*watchdog*|*wdog*|*kernel_panic*)
        _ecn=${_ecp%% *}
        if ! _bl_node "$_ecn"; then
          printf '%s\n' "$_ecp" >> "$dataDir/.probe-blacklist" 2>/dev/null || :
        fi
        echo "$(_ts) early-cut write panic-rebooted last boot; blacklisted + latch ($_ecp, reason=$_br)" >> "$log" 2>/dev/null;;
      *)
        echo "$(_ts) early-cut did not complete last boot but the reboot reason was not a panic ($_br); latching early-cap off only, switch NOT blacklisted ($_ecp)" >> "$log" 2>/dev/null;;
    esac
  fi
  rm -f "$dataDir/.earlycap-pending" 2>/dev/null || :
  touch "$dataDir/.no-early-cap" 2>/dev/null || :
  sync 2>/dev/null || :
  return 0
}

# The capping decision + action. cwd-independent (cd's into $PS itself). Always returns 0 -- boot
# must never see a nonzero from here.
_run() {
  if _system_policy_active; then
    echo "$(_ts) Android charge policy is active; skip early-cut (OS owns charge control)" >> "$log" 2>/dev/null
    return 0
  fi
  sw=$(grep -m1 '^chargingSwitch=' "$config" 2>/dev/null | sed -e 's/^chargingSwitch=(//' -e 's/).*$//')
  case "$sw" in ''|'--'*) echo "$(_ts) no switch configured; skip" >> "$log" 2>/dev/null; return 0;; esac
  # Brick-safe (GitHub #305): never early-write a switch accd already blacklisted for kernel-
  # panicking on a prior boot. early-cap runs BEFORE accd, so without this it would re-fire a
  # known-deadly node at the most panic-sensitive boot stage (and accd's blacklist would never
  # get the chance to protect it).
  if _bl_spec "$sw"; then
    echo "$(_ts) switch on the blocked list (accd probe or AMPS crash list); skip early-cap ($sw)" >> "$log" 2>/dev/null; return 0
  fi
  pause=$(_pause "$config")
  case ${pause:-x} in ''|*[!0-9]*) echo "$(_ts) bad/absent pause '$pause'; skip" >> "$log" 2>/dev/null; return 0;; esac
  # Two domains, both documented and both settable: 1-100 percent, or 3001-5000 millivolts.
  if [ "$pause" -ge 1 ] 2>/dev/null && [ "$pause" -le 100 ] 2>/dev/null; then
    level=$(_level) || { echo "$(_ts) cannot read level; skip (fail-open)" >> "$log" 2>/dev/null; return 0; }
    if [ "$level" -lt "$pause" ]; then
      echo "$(_ts) level $level < pause $pause; let charge (daemon will manage)" >> "$log" 2>/dev/null
      return 0
    fi
  elif [ "$pause" -ge 3001 ] 2>/dev/null && [ "$pause" -le 5000 ] 2>/dev/null; then
    level=$(_mvolt) || { echo "$(_ts) cannot read voltage; skip (fail-open)" >> "$log" 2>/dev/null; return 0; }
    if [ "$level" -lt "$pause" ]; then
      echo "$(_ts) ${level}mV < pause ${pause}mV; let charge (daemon will manage)" >> "$log" 2>/dev/null
      return 0
    fi
  else
    echo "$(_ts) pause $pause out of range; skip" >> "$log" 2>/dev/null; return 0
  fi
  cd "$PS" 2>/dev/null || { echo "$(_ts) no $PS; skip" >> "$log" 2>/dev/null; return 0; }
  # Write-ahead journal (1-strike): persist the switch about to be written + flush to disk BEFORE
  # _cut. If _cut kernel-panics mid-write, this record survives the crash; next boot _pending_check
  # blacklists it and bows out -> one brick at most, never a loop. Kept separate from accd's
  # .probe-pending so the two can never race.
  printf '%s\n' "$sw" > "$dataDir/.earlycap-pending" 2>/dev/null || :
  sync 2>/dev/null || :
  # rc21: VERIFY the write-ahead journal actually landed before cutting. If $dataDir is unwritable at
  # this moment (full or read-only /data after an fsck, SELinux glitch) the journal write silently
  # no-ops -- and without this check we would still cut the node UNPROTECTED, so a mid-write kernel
  # panic could not be blacklisted next boot (the .early-boot-count 3-strike counter, sharing the same
  # unwritable dir, can't accumulate either) => the exact unbounded boot loop the journal exists to
  # prevent. No durable journal, no cut: bow out and let the daemon enforce within seconds. Fail-safe.
  if [ ! -s "$dataDir/.earlycap-pending" ]; then
    echo "$(_ts) journal unwritable (dataDir RO/full?); skip early-cut (fail-safe, daemon will manage)" >> "$log" 2>/dev/null
    return 0
  fi
  wrote=$(_cut "$sw" "$pause")
  rm -f "$dataDir/.earlycap-pending" 2>/dev/null || :
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
  _do() { ( EARLYCAP_CFG="$_T/config" EARLYCAP_PS="$_T/ps" config="$_T/config" PS="$_T/ps" dataDir="$_T/data" log=/dev/null; mkdir -p "$_T/data"; _run ) >/dev/null 2>&1; }

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

  # 10 (brick-safe): switch on the panic-blacklist -> NOT written, even over the limit
  _mkps; _node battery/capacity 80; _node battery/input_suspend 0; mkdir -p "$_T/data"
  printf 'battery/input_suspend 0 1 --\n' > "$_T/data/.probe-blacklist"
  _cfg "battery/input_suspend 0 1 --" "5 101 72 74 false"; _do
  _check "blacklisted switch skipped" 0 "$(_read battery/input_suspend)"
  rm -f "$_T/data/.probe-blacklist"

  # 11 (journal): a clean cut leaves NO armed pending record (disarmed after the write returns)
  _mkps; _node battery/capacity 80; _node battery/input_suspend 0; mkdir -p "$_T/data"
  rm -f "$_T/data/.earlycap-pending"
  _cfg "battery/input_suspend 0 1 --" "5 101 72 74 false"; _do
  _check "journal disarmed after clean write" "" "$(cat "$_T/data/.earlycap-pending" 2>/dev/null)"

  # 12 (self-heal): a leftover pending (= last boot did not finish the cut).
  # rc21: latch and blacklist are split. Latching is cheap and reversible, so it is unconditional.
  # Blacklisting is permanent and also stops the daemon using the node, so it needs the same panic
  # evidence AMPS demands -- this file's own `timeout 6` firing on a merely slow cut leaves an
  # identical journal, and that must not cost the user their only working switch.
  mkdir -p "$_T/data"; rm -f "$_T/data/.probe-blacklist" "$_T/data/.no-early-cap"
  printf 'battery/input_suspend 0 1 --\n' > "$_T/data/.earlycap-pending"
  ( dataDir="$_T/data" log=/dev/null; getprop(){ echo kernel_panic; }; _pending_check )
  _check "pending+panic -> blacklisted" "battery/input_suspend 0 1 --" "$(cat "$_T/data/.probe-blacklist" 2>/dev/null)"
  _check "pending+panic -> latched off" "yes" "$([ -f "$_T/data/.no-early-cap" ] && echo yes || echo no)"
  _check "pending+panic -> cleared" "" "$(cat "$_T/data/.earlycap-pending" 2>/dev/null)"

  # 12b: same journal, ordinary reboot reason -> latch only, switch NOT blacklisted.
  rm -f "$_T/data/.probe-blacklist" "$_T/data/.no-early-cap"
  printf 'battery/input_suspend 0 1 --\n' > "$_T/data/.earlycap-pending"
  ( dataDir="$_T/data" log=/dev/null; getprop(){ echo reboot,userrequested; }; _pending_check )
  _check "pending+normal reboot -> NOT blacklisted" "" "$(cat "$_T/data/.probe-blacklist" 2>/dev/null)"
  _check "pending+normal reboot -> latched off" "yes" "$([ -f "$_T/data/.no-early-cap" ] && echo yes || echo no)"

  # 12c: the early cut must consult AMPS's crash list, not only accd's probe list. Without this
  # the one write that happens before Android exists was the only path that ignored the list
  # recording which node had already taken the phone down.
  rm -f "$_T/data/.probe-blacklist" "$_T/data/.no-early-cap" "$_T/data/.acc-compat-blacklist"
  _mkps; _node battery/capacity 80; _node battery/input_suspend 0
  printf '/sys/class/power_supply/battery/input_suspend\t1\tx\n' > "$_T/data/.acc-compat-blacklist"
  _cfg "battery/input_suspend 0 1 --" "5 101 72 74 false"; _do
  _check "AMPS-listed node not written pre-Android" 0 "$(_read battery/input_suspend)"
  rm -f "$_T/data/.acc-compat-blacklist"

  # 12d: control for 12c -- with the list gone, the same setup DOES cut, so 12c proves something.
  _mkps; _node battery/capacity 80; _node battery/input_suspend 0
  _cfg "battery/input_suspend 0 1 --" "5 101 72 74 false"; _do
  _check "control: unlisted node still cut" 1 "$(_read battery/input_suspend)"

  # 13 (rc21): journal write fails (dataDir unwritable) -> MUST NOT cut, even over the limit.
  # dataDir points under a regular FILE, so the .earlycap-pending write cannot land; the fail-safe
  # must bow out rather than cut a node it can't protect. Root bypasses chmod, so use a bad path.
  _mkps; _node battery/capacity 80; _node battery/input_suspend 0
  : > "$_T/notdir"
  _cfg "battery/input_suspend 0 1 --" "5 101 72 74 false"
  ( EARLYCAP_CFG="$_T/config" EARLYCAP_PS="$_T/ps" config="$_T/config" PS="$_T/ps" dataDir="$_T/notdir/x" log=/dev/null; _run ) >/dev/null 2>&1
  rm -f "$_T/notdir"
  _check "journal unwritable -> no cut (fail-safe)" 0 "$(_read battery/input_suspend)"

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

# 1-strike self-heal: did last boot's early-cut write crash-reboot the device mid-write? If so,
# blacklist that switch + latch off, and do NOT arm/write again this boot. Must run before anything
# writes a node. Turns a panic-node into one crash, never an EDL-bound loop.
_pending_check && exit 0

# bootloop self-heal: increment here, service.sh clears on a good boot. 3 unreached-late_start
# boots => assume we are implicated and latch off. Counter parse is garbage-proof.
bc=$dataDir/.early-boot-count
n=$(cat "$bc" 2>/dev/null); case ${n:-0} in ''|*[!0-9]*) n=0;; esac
n=$((n+1)); echo "$n" > "$bc" 2>/dev/null || :
# Flush it. The 1-strike journal syncs for exactly this reason and the 3-strike backstop needs it
# more, not less: the boot it has to survive is one that panics before anything else reaches disk.
# Left in page cache, the increment is lost on precisely those boots, the counter never reaches 3,
# and the backstop never trips.
sync 2>/dev/null || :
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
