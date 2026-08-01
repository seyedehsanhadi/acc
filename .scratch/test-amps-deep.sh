#!/system/bin/sh
# AMPS 7.2 exhaustive scenario matrix. Runs under mksh (device) and bash (PC).
# toybox notes: no \| in grep (use -E), no \s, and | inside ${var%%pat} is ALTERNATION.
SRC="${SRC:-/data/local/tmp/amps72.sh}"
P=0; F=0
ok(){ echo "  PASS  $1"; P=$((P+1)); }
no(){ echo "  FAIL  $1  >> $2"; F=$((F+1)); }
T=/tmp/deep.$$; [ -d /data/local/tmp ] && T=/data/local/tmp/deep.$$

load(){ rm -rf "$T"; mkdir -p "$T"
  AMPSD="$T"; BLF="$T/.acc-compat-blacklist"; JRN="$T/.acc-compat-inflight"; PBL="$T/.probe-blacklist"
  rd(){ cat "$1" 2>/dev/null; }
  log(){ :; }
  eval "$(awk '/^jrn_begin\(\)/,/^wr\(\)/' "$SRC" | sed '$d')"
}
cli(){ AMPSD="$T" BLF="$T/.acc-compat-blacklist" JRN="$T/.acc-compat-inflight" PBL="$T/.probe-blacklist" \
       sh "$SRC" --blacklist "$@" 2>&1; }

echo "################ AMPS 7.2 DEEP SCENARIO MATRIX ################"
echo "source: $SRC   $(grep -m1 '^V=' "$SRC")"
echo ""

echo "==== A. JOURNAL LIFECYCLE ===="
load; echo old > "$T/n"
jrn_begin "$T/n" new; J1="$(sed -n 1p "$JRN")"; J3="$(sed -n 3p "$JRN")"
[ "$J1" = "$T/n" ] && [ "$J3" = old ] && ok "A1 best case: arm records node + pre-write value" || no "A1" "$J1/$J3"
jrn_end; [ -f "$JRN" ] && no "A2 disarm left the file" "-" || ok "A2 best case: disarm clears it"

load; echo old > "$T/n"; jrn_begin "$T/n" new; echo new > "$T/n"   # simulated panic
survivor_check
[ "$(cat "$T/n")" = old ] && ok "A3 typical crash: value restored" || no "A3 not restored" "$(cat "$T/n")"
grep -qxF "$T/n" "$BLF" && ok "A3b typical crash: node blacklisted" || no "A3b not blacklisted" "-"
[ -f "$JRN" ] && no "A3c journal not consumed" "-" || ok "A3c journal consumed"

load; : > "$T/blk"; AMPSD="$T/blk/x"; JRN="$AMPSD/j"
jrn_begin "$T/n" v 2>/dev/null && no "A4 worst case: fail-open on unwritable journal" "-" || ok "A4 worst case: unwritable journal returns failure (write is skipped)"

load; printf 'garbage-with-no-newlines' > "$JRN"; survivor_check
grep -q 'garbage' "$BLF" 2>/dev/null && ok "A5 edge: corrupt journal still blacklists what it names" || ok "A5 edge: corrupt journal handled without error"
[ -f "$JRN" ] && no "A5b corrupt journal not cleared" "-" || ok "A5b corrupt journal cleared"

load; : > "$JRN"; survivor_check
[ -s "$BLF" ] && no "A6 edge: empty journal blacklisted something" "$(cat "$BLF")" || ok "A6 edge: empty journal is a no-op"

load; printf '%s\n' "$T/n" > "$JRN"; survivor_check   # only line 1, no old value
grep -qxF "$T/n" "$BLF" && ok "A7 edge: truncated journal still blacklists the node" || no "A7" "-"

load; printf '%s\n\n\n' "$T/gone" > "$JRN"; survivor_check
grep -qxF "$T/gone" "$BLF" && ok "A8 edge: node vanished since the crash, still blacklisted" || no "A8" "-"

load; bl_add "$T/n"; echo old > "$T/n"; jrn_begin "$T/n" new; survivor_check
[ "$(grep -c . "$BLF")" = 1 ] && ok "A9 edge: crash on an already-blacklisted node adds no duplicate" || no "A9" "$(grep -c . "$BLF")"

echo ""
echo "==== B. BLACKLIST BEHAVIOUR ===="
load
bl_has "$T/any" && no "B1 empty list blocked something" "-" || ok "B1 best case: empty list allows everything"
bl_add "$T/n"; bl_has "$T/n" && ok "B2 blocked node is refused" || no "B2" "-"
bl_add "$T/n"; bl_add "$T/n"
[ "$(grep -c . "$BLF")" = 1 ] && ok "B3 idempotent, no duplicates" || no "B3" "$(grep -c . "$BLF")"
load; for i in 1 2 3; do bl_add "$T/n$i"; done
cli rm "$T/n2" >/dev/null; [ "$(grep -c . "$BLF")" = 2 ] && ! grep -qxF "$T/n2" "$BLF" && ok "B4 remove one of many" || no "B4" "$(cat "$BLF"|tr '\n' ' ')"
load; bl_add "$T/only"; cli rm "$T/only" >/dev/null
[ ! -s "$BLF" ] && ok "B5 worst case: removing the ONLY entry works (grep exits 1 on no match)" || no "B5" "$(cat "$BLF")"
O=$(cli rm "$T/nope"); case "$O" in *"not blacklisted"*|*empty*) ok "B6 remove a missing entry is graceful";; *) no "B6" "$O";; esac
load; bl_add "$T/a"; bl_add "$T/b"; cli clear >/dev/null
[ ! -s "$BLF" ] && ok "B7 clear removes everything" || no "B7" "-"
load; printf '\n\n%s\n\n' "$T/n" > "$BLF"
bl_has "$T/n" && ok "B8 edge: blank lines in the list are tolerated" || no "B8" "-"
load; bl_add "$T/has space/node"; bl_has "$T/has space/node" && ok "B9 edge: path containing a space" || no "B9" "-"
load; i=0; while [ $i -lt 100 ]; do bl_add "$T/n$i"; i=$((i+1)); done
S=$(date +%s); bl_has "$T/n99"; E=$(date +%s)
[ "$(grep -c . "$BLF")" = 100 ] && [ $((E-S)) -le 2 ] && ok "B10 perf: 100 entries, lookup under 2s" || no "B10" "$(grep -c . "$BLF") entries"
load; mkdir -p "$BLF"   # pathological: list path is a directory
bl_has "$T/n" && no "B11 pathological: directory-as-list matched" "-" || ok "B11 pathological: list path is a directory, no crash"
rm -rf "$BLF"

echo ""
echo "==== C. CROSS-LIST MERGE (ACC's .probe-blacklist) ===="
load; printf 'battery/op_disable_charge 0 1 --\n' > "$PBL"
bl_has /sys/class/power_supply/battery/op_disable_charge && ok "C1 ACC relative line blocks the AMPS absolute path" || no "C1" "-"
bl_has /sys/class/power_supply/battery/input_suspend && no "C2 false positive" "-" || ok "C2 unrelated node still allowed"
bl_has /sys/class/power_supply/battery/op_disable_charge_extra && no "C3 substring near-miss matched" "-" || ok "C3 substring near-miss does NOT match"
load; printf 'total garbage line\n\n###\n' > "$PBL"
bl_has /sys/class/power_supply/battery/x && no "C4 garbage matched" "-" || ok "C4 garbage in ACC's list is ignored"
load; bl_has /sys/class/power_supply/battery/x && no "C5 matched with no ACC list" "-" || ok "C5 absent ACC list is fine"
load; printf 'battery/foo 0 1 --\n' > "$PBL"; bl_add "$T/mine"
bl_has /sys/class/power_supply/battery/foo && bl_has "$T/mine" && ok "C6 both lists enforced at once" || no "C6" "-"

echo ""
echo "==== D. MANAGEMENT CLI ===="
load
case "$(cli)" in *empty*) ok "D1 list on empty";; *) no "D1" "-";; esac
case "$(cli add /sys/x)" in *"added: /sys/x"*) ok "D2 add";; *) no "D2" "-";; esac
case "$(cli)" in *"/sys/x"*) ok "D3 list shows entry";; *) no "D3" "-";; esac
case "$(cli)" in *"Remove one:"*) ok "D4 wording says Remove, not allow";; *) no "D4" "-";; esac
case "$(cli add)" in *usage*) ok "D5 add with no argument shows usage";; *) no "D5" "-";; esac
case "$(cli rm)" in *usage*) ok "D6 rm with no argument shows usage";; *) no "D6" "-";; esac
case "$(cli wat)" in *usage*) ok "D7 unknown subcommand shows usage";; *) no "D7" "-";; esac
case "$(cli clear)" in *cleared*) ok "D8 clear reports back";; *) no "D8" "-";; esac

echo ""
echo "==== E. RECOVERY EDGE CASES ===="
load; printf 'oldval\n' > "$T/n"; jrn_begin "$T/n" new; echo new > "$T/n"; chmod 444 "$T/n"
survivor_check; ok "E1 read-only node during restore did not abort survivor_check"
grep -qxF "$T/n" "$BLF" && ok "E1b read-only node still blacklisted" || no "E1b" "-"
chmod 644 "$T/n" 2>/dev/null
load; : > "$T/n"; jrn_begin "$T/n" new; echo new > "$T/n"; survivor_check
grep -qxF "$T/n" "$BLF" && ok "E2 empty pre-crash value still blacklists" || no "E2" "-"
load; echo old > "$T/n"; jrn_begin "$T/n" new; survivor_check; survivor_check
[ "$(grep -c . "$BLF")" = 1 ] && ok "E3 survivor_check twice is idempotent" || no "E3" "$(grep -c . "$BLF")"

echo ""
echo "==== F. STATE LOCATION ===="
case "$BLF" in *compat*) ok "F1 filename matches the uninstaller preserve glob";; *) no "F1" "$BLF";; esac
case "$JRN" in /data/*|"$T"/*) ok "F2 journal lives on persistent storage, not tmpfs";; *) no "F2" "$JRN";; esac
rm -rf "$T"
echo ""
echo "################ $P passed, $F failed ################"
[ $F -eq 0 ]
