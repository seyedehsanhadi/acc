#!/system/bin/sh
# t105 - write() must retry ONLY a write that was attempted and did not verify.
# Four branches, all through the one choke point:
#   1. verified match      - exactly one echo, rc 0.
#   2. attempted, unverified - full retry budget, rc $3 unchanged.
#   3. chmod/non-file       - zero echos, immediate rc $3 unchanged (never attempted).
#   4. blacklist marker     - zero echos, immediate rc $3 unchanged (deliberately never attempted).
ID=t105; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
W=/data/local/tmp/t105; rm -rf $W; mkdir -p $W

sed -n "/^write() {/,/^}/p" $execDir/misc-functions.sh > $W/write.sh
[ -s $W/write.sh ] || { no "could not extract write() from $execDir/misc-functions.sh - harness is broken, not the product"; fin; }

# count_echos <label> <run-script-path> <grep-pattern>
# Runs the script under -x and counts trace lines matching the pattern. Refuses to grade a
# blank measurement (finding 3): an empty/missing trace must FAIL, never silently read as 0.
count_echos() {
  _lbl=$1; _rs=$2; _pat=$3
  /system/bin/sh -x "$_rs" > "$_rs.trace" 2>&1
  [ -s "$_rs.trace" ] || { no "$_lbl: trace file is empty - harness produced no measurement"; echo -1; return; }
  grep -c "$_pat" "$_rs.trace"
}

# ---------------------------------------------------------------------------------------------
# Branch 1: verified match - exactly one echo, rc 0.
: > $W/node1
cat > $W/run1.sh <<EOF
TMPDIR=$W; dataDir=$W; mkdir -p \$dataDir/logs
sw_blacklisted(){ return 1; }
_wlog(){ :; }
isAccd=false
usleep(){ :; }
. $W/write.sh
write 7 $W/node1
echo "rc=\$?"
EOF
_e1=$(count_echos "branch1" $W/run1.sh "echo 7 > $W/node1")
_v1=$(cat $W/node1)
[ "$_v1" = 7 ] && ok "branch1: the value landed ($_v1)" || no "branch1: value is '$_v1', expected 7"
grep -q 'rc=0' $W/run1.sh.trace && ok "branch1: write() returned 0" || no "branch1: did not return 0: $(grep rc= $W/run1.sh.trace)"
[ "${_e1:-0}" -eq 1 ] && ok "branch1: exactly 1 echo after a verified write" || no "branch1: ${_e1} echo(s) - the post-verify hammer is back"

# ---------------------------------------------------------------------------------------------
# Branch 2: attempted but never verifies - a value-transforming node (real example: HyperOS
# smart_chg, called out in the rc14 comment above write()). $1 is a PATH, so write() echoes the
# path string itself into the node; the verify step then dereferences $one to the path's
# CONTENT, which can never equal the path string that was written. No background process, no
# timing dependency - the mismatch is structural and every retry reproduces it identically.
echo 42 > $W/valuefile
: > $W/node2
cat > $W/run2.sh <<EOF
TMPDIR=$W; dataDir=$W; mkdir -p \$dataDir/logs
sw_blacklisted(){ return 1; }
_wlog(){ :; }
isAccd=false
usleep(){ :; }
. $W/write.sh
write $W/valuefile $W/node2 99
echo "rc=\$?"
EOF
_e2=$(count_echos "branch2" $W/run2.sh "echo $W/valuefile > $W/node2")
_rc2=$(grep 'rc=' $W/run2.sh.trace | tail -1)
[ "$_rc2" = "rc=99" ] && ok "branch2: rc=99 (the caller's \$3, unchanged)" || no "branch2: $_rc2, expected rc=99"
if [ "${_e2:-0}" -ge 2 ] && [ "${_e2:-0}" -le 6 ]; then
  ok "branch2: ${_e2} echo(s) - the full retry budget ran, not a first-try bail"
else
  no "branch2: ${_e2} echo(s) - expected the retry budget (2-6 attempts, initial + up to 5 retries)"
fi

# ---------------------------------------------------------------------------------------------
# Branch 3: chmod/non-file path - point the node at a directory. [ -f "$2" ] is false for a
# directory, which is the SAME else-branch a real chmod failure takes; write() must never even
# attempt an echo, and must return immediately.
mkdir -p $W/node3dir
cat > $W/run3.sh <<EOF
TMPDIR=$W; dataDir=$W; mkdir -p \$dataDir/logs
sw_blacklisted(){ return 1; }
_wlog(){ :; }
isAccd=false
usleep(){ :; }
. $W/write.sh
write 5 $W/node3dir 77
echo "rc=\$?"
EOF
_e3=$(count_echos "branch3" $W/run3.sh "echo 5 > $W/node3dir")
_rc3=$(grep 'rc=' $W/run3.sh.trace | tail -1)
[ "$_rc3" = "rc=77" ] && ok "branch3: rc=77 (the caller's \$3, unchanged)" || no "branch3: $_rc3, expected rc=77"
[ "${_e3:-0}" -eq 0 ] && ok "branch3: zero echos - a non-writable node is never attempted" || no "branch3: ${_e3} echo(s) - should never have attempted a write"

# ---------------------------------------------------------------------------------------------
# Branch 4: blacklist marker - a "#<node>" line in the write log with no $lastNode set is the
# deliberate no-echo skip (rc21 comment above write()). It must stay a zero-echo immediate
# return: it is not a failed write, it is a write ACC refuses to attempt at all.
: > $W/node4
cat > $W/run4.sh <<EOF
TMPDIR=$W; dataDir=$W; mkdir -p \$dataDir/logs
echo "#$W/node4" > \$dataDir/logs/write.log
sw_blacklisted(){ return 1; }
_wlog(){ :; }
isAccd=false
usleep(){ :; }
. $W/write.sh
write 3 $W/node4 55
rc=\$?
echo "rc=\$rc"
echo "blacklisted=\$blacklisted"
EOF
_e4=$(count_echos "branch4" $W/run4.sh "echo 3 > $W/node4")
_rc4=$(grep 'rc=' $W/run4.sh.trace | tail -1)
[ "$_rc4" = "rc=55" ] && ok "branch4: rc=55 (the caller's \$3, unchanged)" || no "branch4: $_rc4, expected rc=55"
[ "${_e4:-0}" -eq 0 ] && ok "branch4: zero echos - a blacklisted node is never attempted" || no "branch4: ${_e4} echo(s) - the write-blacklist choke point was bypassed"
grep -q 'blacklisted=true' $W/run4.sh.trace && ok "branch4: blacklisted=true reached the caller" || no "branch4: caller never saw blacklisted=true: $(grep blacklisted= $W/run4.sh.trace)"

fin
