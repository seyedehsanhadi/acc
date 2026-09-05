#!/system/bin/sh
# Paired kernel model: reject stop <= start; measure current, not a delayed SOC tick.
AMPS=${AMPS:-./amps.sh}
W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
eval "$(sed -n '/^native_stress()/,/^finalist_stress()/{ /^finalist_stress()/!p; }' "$AMPS")"
command -v native_stress >/dev/null 2>&1 || { echo 'FAIL native finalist never cycles'; exit 1; }
eval "$(sed -n '/^native_verdict()/,/^is_pump()/{ /^is_pump()/!p; }' "$AMPS")"
F=0
check(){ if "$@"; then echo "PASS $*"; else echo "FAIL $*"; F=$((F+1)); fi; }
ACTIVE=1; BLINDV=0; CUR_USABLE=1; SETTLE=0; TMAX=450; STRESS_CYCLES=2; BATT=$W
mkdir "$W/kernel"; node=$W/kernel/charge_stop_level; pair=$W/kernel/charge_start_level
echo 50 > "$BATT/capacity"
read1(){ cat "$1"; }; san(){ echo "$1"; }; snap_add(){ :; }; sleep(){ :; }
over(){ return 1; }; batt_temp(){ echo 300; }; log(){ :; }; stop_check(){ :; }
list_drop(){ echo ''; }; drop_finalist(){ dropped=1; }
wr(){
  if [ "$1" = "$node" ]; then
    [ "$2" -gt "$(cat "$pair")" ] || return 1
  elif [ "$1" = "$pair" ]; then
    [ "$2" -lt "$(cat "$node")" ] || return 1
  fi
  printf '%s\n' "$2" > "$1"
}
chg_now(){
  [ "$mode" = no-baseline ] && { echo 0; return; }
  [ "$mode" = resume-fail ] && [ "$probes" -gt 0 ] && { echo 0; return; }
  [ "$(cat "$node")" -gt 50 ] && echo 1 || echo 0
}
hold_probe(){
  probes=$((probes+1)); SAMP_N=0; SAMP_LAST=0
  [ "$mode" = leak ] && { SAMP_N=3; SAMP_LAST=1; }
  echo 51 > "$BATT/capacity"
  return 0
}
for mode in clean leak resume-fail no-baseline; do
  echo 80 > "$node"; echo 70 > "$pair"; echo 50 > "$BATT/capacity"
  probes=0; dropped=0; LEVELOK='|native'; le_enf=native
  native_stress native "$node 100 pcap"; result=$?
  check test "$(cat "$node")/$(cat "$pair")" = 80/70
  case "$mode" in
    clean) check test "$result:$probes:$dropped:$_FS_UNVERIFIED" = 0:4:0:;;
    leak|resume-fail) check test "$result:$dropped" = 1:1;;
    no-baseline) check test "$result:$probes:$dropped:$_FS_UNVERIFIED" = 0:0:0:native;;
  esac
done
echo "native-finalist: $F failed"
[ "$F" = 0 ]
