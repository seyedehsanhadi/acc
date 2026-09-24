#!/system/bin/sh
# A switch blacklisted while it was HOLDING the cut must be released once, so the phone can
# still charge. _drop_blocked_sw did that only when the config named the switch; under auto
# fan-out the config is empty and the node is named only by .last-good-switch, so the release
# was unreachable and the phone was stranded. Device-evidence: moto g64 5G, en_power_path left
# at 0 for ~3.5h while chDisabledByAcc reported false.
execDir=${execDir:-/data/adb/vr25/acc}
# $0 has no slash when invoked as a bare filename, so ${0%/*} returns the FILENAME and every
# awk lift silently fails. Resolve the directory properly.
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF=.
AWKF=${AWKF:-$SELF/../xf.awk}
ACCD=${ACCD:-$execDir/accd.sh}
MF=${MF:-$execDir/misc-functions.sh}
P=0; F=0
# Pin the scratch base once, to a directory that actually exists on this host: the device has
# /data/local/tmp, a workstation does not.
_TMPD0=${TMPDIR:-}
[ -d "${_TMPD0:-/nonexistent}" ] || _TMPD0=/data/local/tmp
[ -d "$_TMPD0" ] || _TMPD0=/tmp
[ -d "$_TMPD0" ] || _TMPD0=.
run(){ # $1=case $2=expected-first $3=expected-second(after node forced back off)
  # Always allocate from the ORIGINAL TMPDIR: a previous case set TMPDIR to its own
  # scratch dir, which is now deleted, and mktemp there fails silently.
  W=$(TMPDIR=$_TMPD0 mktemp -d)
  [ -d "$W" ] || { echo "  FAIL $1: mktemp -d failed"; F=$((F+1)); return; }; mkdir -p "$W/data" "$W/tmp" "$W/psy"
  dataDir=$W/data; TMPDIR=$W/tmp; execDir=$W; isAccd=true
  NODE=$W/psy/en_power_path
  printf '%s\t%s\t%s\n' "$NODE" 1 "2026-09-15 19:16" > "$dataDir/.acc-compat-blacklist"
  printf '%s 1 0\n' "$NODE" > "$dataDir/.last-good-switch"
  echo 0 > "$NODE"
  eval "$(awk -v fn=sw_blacklisted -f "$AWKF" "$MF")"
  eval "$(awk -v fn=_drop_blocked_sw -f "$AWKF" "$ACCD")"
  warn_once_per(){ :; }; _srccfg(){ :; }; _wlog(){ :; }; parse_value(){ echo "$1"; }
  flip_sw(){ set -- ${chargingSwitch[@]-}; [ -f "${1:-//}" ] || return 2
    if [ "${_BLRELEASE:-0}" != 1 ] && sw_blacklisted "$1"; then return 1; fi
    printf '%s\n' "$2" > "$1"; }
  case $1 in
    configured) chargingSwitch=("$NODE" 1 0 --);;
    autoswitch) chargingSwitch=();;
    clean)      chargingSwitch=("$NODE" 1 0 --); : > "$dataDir/.acc-compat-blacklist";;
    auto-clean) chargingSwitch=(); : > "$dataDir/.acc-compat-blacklist";;
    no-lgs)     chargingSwitch=(); rm -f "$dataDir/.last-good-switch";;
  esac
  _drop_blocked_sw >/dev/null 2>&1
  a=$(command cat "$NODE")
  echo 0 > "$NODE"
  _drop_blocked_sw >/dev/null 2>&1
  b=$(command cat "$NODE")
  if [ "$a" = "$2" ] && [ "$b" = "$3" ]; then P=$((P+1))
  else echo "  FAIL $1: first='$a' want '$2', second='$b' want '$3'"; F=$((F+1)); fi
  rm -rf "$W"
}
# second call must always be 0: the release happens ONCE. A node is on the blocked list because
# it took a phone DOWN, so re-writing it every daemon pass is not an acceptable price.
run configured 1 0
run autoswitch 1 0
run clean      0 0
run auto-clean 0 0
run no-lgs     0 0
echo "t-blocked-switch-release: $P passed, $F failed"
[ "$F" = 0 ]
