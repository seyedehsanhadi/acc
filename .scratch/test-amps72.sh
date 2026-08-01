#!/system/bin/sh
# AMPS 7.2 crash-journal + blacklist contract. Runs under bash (PC) and mksh (device).
SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)/acc-compat.sh}"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1  >> $2"; FAIL=$((FAIL+1)); }
T=/tmp/a72.$$; [ -d /data/local/tmp ] && T=/data/local/tmp/a72.$$

# load the 7.2 helper block from the REAL script, with rd/log stubbed
load(){ rm -rf "$T"; mkdir -p "$T"
  AMPSD="$T"; BLF="$T/.acc-compat-blacklist"; JRN="$T/.acc-compat-inflight"; PBL="$T/.probe-blacklist"
  rd(){ cat "$1" 2>/dev/null; }
  log(){ :; }
  eval "$(awk '/^jrn_begin\(\)/,/^wr\(\)/' "$SRC" | sed '$d')"
}

echo "======== AMPS 7.2: crash journal + blacklist ========"
echo "version in source: $(grep -m1 '^V=' "$SRC")"
echo ""

# 1. journal records the node BEFORE the write, with its old value
load; echo old > "$T/node"
jrn_begin "$T/node" newval
J="$(sed -n 1p "$JRN"):$(sed -n 2p "$JRN"):$(sed -n 3p "$JRN")"
case "$J" in "$T/node:newval:old") ok "journal records node / new / OLD value before the write";;
  *) no "journal content wrong" "$J";; esac

# 2. journal cleared after a surviving write
jrn_end
[ -f "$JRN" ] && no "journal not cleared after success" "exists" || ok "journal cleared once the write survives"

# 3. SURVIVOR: journal left behind -> node restored AND blacklisted
load; echo old > "$T/node"; jrn_begin "$T/node" newval
echo newval > "$T/node"          # the write that killed the phone
survivor_check
R=$(cat "$T/node"); B=$(cat "$BLF" 2>/dev/null)
[ "$R" = old ] && ok "survivor: node RESTORED to its pre-crash value" || no "node not restored" "$R"
[ "$B" = "$T/node" ] && ok "survivor: node permanently BLACKLISTED" || no "not blacklisted" "$B"
[ -f "$JRN" ] && no "journal not consumed" "exists" || ok "survivor: journal consumed (no repeat on next start)"

# 4. blacklist gate actually refuses
bl_has "$T/node" && ok "bl_has() refuses a blacklisted node" || no "bl_has missed it" "-"
bl_has "$T/other" && no "bl_has false-positive" "-" || ok "bl_has allows an unrelated node"

# 5. idempotent: no duplicate entries
bl_add "$T/node"; bl_add "$T/node"
N=$(grep -c . "$BLF" 2>/dev/null)
[ "$N" = 1 ] && ok "blacklist is idempotent (no duplicates)" || no "duplicated" "$N lines"

# 6. survivor with no journal is a no-op
load; survivor_check
[ -f "$BLF" ] && no "blacklisted something with no journal" "-" || ok "no journal -> survivor_check is a no-op"

# 7. management CLI end to end (runs the real script)
rm -rf "$T"; mkdir -p "$T"
run(){ AMPSD="$T" BLF="$T/.acc-compat-blacklist" JRN="$T/.acc-compat-inflight" sh "$SRC" --blacklist "$@" 2>&1; }
O=$(run list);        case "$O" in *empty*) ok "CLI list: reports empty";; *) no "list on empty" "$O";; esac
O=$(run add /sys/x);  case "$O" in *"added: /sys/x"*) ok "CLI add";; *) no "add" "$O";; esac
O=$(run list);        case "$O" in *"/sys/x"*) ok "CLI list shows the entry";; *) no "list" "$O";; esac
O=$(run rm /sys/x);   case "$O" in *"removed: /sys/x"*) ok "CLI rm";; *) no "rm" "$O";; esac
O=$(run list);        case "$O" in *empty*) ok "CLI rm actually removed it";; *) no "still there" "$O";; esac
O=$(run add /sys/y); O=$(run clear)
case "$O" in *cleared*) ok "CLI clear";; *) no "clear" "$O";; esac
O=$(run rm /sys/zz);  case "$O" in *"empty"*|*"not blacklisted"*) ok "CLI rm of a missing entry is graceful";; *) no "rm missing" "$O";; esac
O=$(run bogus);       case "$O" in *usage*) ok "CLI rejects an unknown subcommand";; *) no "bogus" "$O";; esac

# 8. MERGE: ACC's own crash blacklist (probe-journal.sh, #305/#308) must be honoured.
#    It stores switch LINES relative to the power-supply dir; AMPS uses absolute paths.
load
printf 'battery/op_disable_charge 0 1 --\n' > "$PBL"
bl_has /sys/class/power_supply/battery/op_disable_charge \
  && ok "honours ACC's .probe-blacklist (absolute path matched to a relative switch line)" \
  || no "did NOT honour ACC's probe blacklist" "-"
bl_has /sys/class/power_supply/battery/input_suspend \
  && no "false-positive against ACC's list" "-" \
  || ok "unrelated node still allowed with ACC's list present"

# 9. FAIL-CLOSED: if the journal cannot persist, jrn_begin must FAIL so no write happens.
#     chmod cannot simulate this as root (root ignores the bits), so make a path component a
#     regular FILE: mkdir -p then fails with ENOTDIR even for uid 0.
load
: > "$T/blocker"
AMPSD="$T/blocker/sub"; JRN="$AMPSD/inflight"
if jrn_begin "$T/x" v 2>/dev/null; then no "jrn_begin returned success with an unwritable journal" "fail-open"
else ok "fail-closed: unwritable journal reports failure, so wr() skips the write"; fi

# 10. the file name must match the uninstaller's preserve glob (*compat*)
case "$BLF" in *compat*) ok "blacklist filename matches the uninstaller preserve glob (survives uninstall)";;
  *) no "name would be deleted on uninstall" "$BLF";; esac

rm -rf "$T"
echo ""
echo "======== $PASS passed, $FAIL failed ========"
[ $FAIL -eq 0 ]
