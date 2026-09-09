#!/system/bin/sh
AMPS=${AMPS:-./amps.sh}
eval "$(grep -E '^(rd|san|abs|counter_value)\(\)' "$AMPS")"
eval "$(sed -n '/^classify_held(){/,/^on_sane(){/{ /^on_sane()/!p; }' "$AMPS")"
W=$(mktemp -d "${TMPDIR:-/data/local/tmp}/amps-faults.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
BATT=$W; HAVE_TO=0; BLINDV=1; BL_ONLINE=1; WEAK_CHARGER=0; CHGIN=; IDLE=10000
P=0; F=0
read_st(){ echo Unknown; }
online_now(){ return 0; }
sleep(){ printf '%s\n' "$after" > "$BATT/charge_counter"; }
check(){ P=$((P+1)); [ "$1" = "$2" ] || { F=$((F+1)); echo "FAIL $3: $1 != $2"; }; }
for pair in '1000000:1001000:NOT-HELD' '1000000:999000:DRAIN' '1000000:1000000:CUT' '1000000:garbage:NOT-HELD' 'garbage:garbage:NOT-HELD' '0:0:NOT-HELD' '1000000:0:NOT-HELD' '1000000:999999999:NOT-HELD' '99999999999999999999:1:NOT-HELD' '-1:-1:NOT-HELD'; do
 before=${pair%%:*}; rest=${pair#*:}; after=${rest%%:*}; expected=${rest#*:}
 printf '%s\n' "$before" > "$BATT/charge_counter"
 check "$(classify_held)" "$expected" "$pair"
done
rm "$BATT/charge_counter"
check "$(classify_held)" NOT-HELD missing-counter
echo "t-sensor-faults: $P passed, $F failed"
[ "$F" = 0 ]
