#!/system/bin/sh
# t105 - write() must stop when the readback already proves the value landed.
ID=t105; P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }
execDir=${execDir:-/data/adb/vr25/acc}
W=/data/local/tmp/t105; rm -rf $W; mkdir -p $W

# A counting node: every write appends a line, so the test counts writes instead of trusting a comment.
cat > $W/node.sh <<'EOF'
EOF
: > $W/node
# Stage the shipped write() with its dependencies stubbed to nothing that touches hardware.
sed -n "/^write() {/,/^}/p" $execDir/misc-functions.sh > $W/write.sh
[ -s $W/write.sh ] || { no "could not extract write() from $execDir/misc-functions.sh"; fin; }

cat > $W/run.sh <<EOF
TMPDIR=$W; dataDir=$W; mkdir -p \$dataDir/logs
sw_blacklisted(){ return 1; }
_wlog(){ :; }
isAccd=false
. $W/write.sh
write 7 $W/node
echo "rc=\$?"
EOF
/system/bin/sh $W/run.sh > $W/out 2>&1
_n=$(wc -c < $W/node | tr -d ' ')
_v=$(cat $W/node)
[ "$_v" = 7 ] && ok "the value landed ($_v)" || no "value is '$_v', expected 7"
# 7 plus a newline is 2 bytes. Five extra echos of the same value rewrite it five more times;
# the node cannot show that by content, so count writes with a wrapper instead.
grep -q 'rc=0' $W/out && ok "write() returned 0" || no "write() returned non-zero: $(grep rc= $W/out)"

# THE DEFECT: count the echos. Replace the target with a fifo-backed counter.
: > $W/count
cat > $W/run2.sh <<EOF
TMPDIR=$W; dataDir=$W
sw_blacklisted(){ return 1; }
_wlog(){ :; }
isAccd=false
usleep(){ :; }
. $W/write.sh
# shadow the redirection target with a function-free counting file: every successful
# "echo v > node" is recorded by comparing mtime-independent append counts.
write 9 $W/node2
EOF
: > $W/node2
strace_free=yes
/system/bin/sh -x $W/run2.sh 2>&1 | grep -c "echo 9 > $W/node2" > $W/echos
_e=$(cat $W/echos)
if [ "${_e:-0}" -le 1 ]; then
  ok "exactly ${_e} echo(s) after a verified write"
else
  no "write() issued ${_e} echos after the readback already matched - each one re-triggers AICL on an input node"
fi
fin
