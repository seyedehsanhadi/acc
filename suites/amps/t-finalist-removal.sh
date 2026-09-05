#!/system/bin/sh
# No hardware writes: exercise the shipped recommendation helpers against files.
AMPS=${AMPS:-./amps.sh}
W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
F=0
check(){ if "$@"; then echo "PASS $*"; else echo "FAIL $*"; F=$((F+1)); fi; }
eval "$(sed -n '/^list_drop()/,/^finalist_stress()/{ /^finalist_stress()/!p; }' "$AMPS")"
eval "$(sed -n '/^emit_alts()/,/^le_enf=/{ /^le_enf=/!p; }' "$AMPS")"
eval "$(sed -n '/^conf_resume()/,/^unit_pick()/{ /^unit_pick()/!p; }' "$AMPS")"
check test "$(conf_resume verified cut na)" = needs-test
BK=$W; REG=$W/switches.tsv
BYPASS='|bad|good'; BYPASS_HELD=$BYPASS; LONGOK=$BYPASS
CUT=; DRAIN=; THROTTLE=; WORKING='bad (BYPASS)'
CFG_BYPASS='/mock/bad 1 0'; CFG_CUT=; CFG_DRAIN=; CFG_LEVEL='/mock/bad 1 0'
ADDLINES='/mock/bad 1 0 (BYPASS)'
printf 'bypass\t/mock/bad 1 0\tholds-alone\tbad\nbypass\t/mock/good 1 0\tholds-alone\tgood\n' > "$REG"
drop_finalist bad '/mock/bad 1 0'
check test "$WORKING" = 'good (BYPASS)'
check test -z "$CFG_LEVEL"
check test "$(awk -F '\t' '$4=="bad"{n++} END{print n+0}' "$REG")" = 0
# A later stress failure must not be masked by an earlier successful resume.
RECO_LBL=good; SUGGEST='/mock/good 1 0'; RESUMES='|bad=OK|bad=STUCK'; STUCKS='|bad'
pump_conf(){ echo "$1"; }; note_for(){ :; }
emit_alts > "$W/alts"
check test "$(sed -n 's/^alt_count=//p' "$W/alts")" = 0
printf 'cut\t/mock/untested 1 0\tholds-alone\tuntested\n' > "$REG"
emit_alts > "$W/alts"
check test "$(sed -n 's/^alt1_conf=//p' "$W/alts")" = needs-test
# The retry branch must preserve a measured NOT-HELD verdict.
eval "$(sed -n '/^test_switch()/,/^test_level()/{ /^test_level()/!p; }' "$AMPS")"
ACTIVE=1; DANGER_RE='^NEVER$'; SUPERDENY_RE=$DANGER_RE; BLINDV=1; TEACH_P=
POLL=0; : > "$BK/dead"; printf '1\n' > "$W/node"
over(){ return 1; }; ex(){ test -e "$1"; }; gate(){ :; }; stop_check(){ :; }
rd(){ cat "$1"; }; read1(){ echo 0; }; san(){ echo "$1"; }; snap_add(){ :; }
wr(){ printf '%s\n' "$2" > "$1"; }; sleep(){ :; }; log(){ :; }
chg_now(){ echo 1; }; med_cur(){ echo 0; }; vmv(){ echo 0; }
hold_probe(){ SAMP_FIRST=0; SAMP_LAST=1; SAMP_N=1; C1=0; CL=1; }
classify_held(){ echo NOT-HELD; }; route_stab(){ routed=$1; }
routed=
test_switch retry "$W/node" 1 0
check test "$routed" != CUT
check test "$routed" != BYPASS
# Candidate identity must survive from detection to the resume result lookup.
for group in pixel-group acc-group firmware-combo teach-combo; do
  detected=$(sed -n "s/.*route_hit [^ ]* \"\($group[^\"]*\)\".*/\1/p" "$AMPS")
  resumed=$(sed -n "s/.*resume_check \"\($group[^\"]*\)\".*/\1/p" "$AMPS")
  check test -n "$detected"
  check test "$detected" = "$resumed"
done
# Trusted textual switches and relative ACC paths must actually reach the stress test.
eval "$(sed -n '/^fstress_verdict()/,/^note_for()/{ /^note_for()/!p; }' "$AMPS")"
PSY=$W/power; mkdir "$PSY"; BATT=$W; echo 50 > "$BATT/capacity"
CAP=50; ACC_DEFER=0; STRESS_FINALIST=1; STRESS_HITS=1; STRESS_CYCLES=1; STRESS_CYCLE_HOLD=0
read1(){ sed -n '1p' "$1"; }; recover_online(){ :; }
chg_now(){ [ "$(cat "$PSY/toggle")" = enabled ] && echo 1 || echo 0; }
wr(){ writes=$((writes+1)); printf '%s\n' "$2" > "$1"; }
for path in "$PSY/toggle" toggle; do
  echo enabled > "$PSY/toggle"; writes=0; _FS_SEEN=
  finalist_stress toggle "$path enabled disabled" cut
  check test "$writes" -ge 4
  check test "$(cat "$PSY/toggle")" = enabled
done
# ACC encodes spaces as :: in compound node values.
echo '0 0' > "$PSY/toggle"; writes=0; _FS_SEEN=
chg_now(){ [ "$(cat "$PSY/toggle")" = '0 0' ] && echo 1 || echo 0; }
finalist_stress toggle "$PSY/toggle 0::0 0::1" cut
check test "$writes" -ge 4
check test "$(cat "$PSY/toggle")" = '0 0'
: > "$PSY/toggle"; writes=0; _FS_SEEN=
finalist_stress toggle "$PSY/toggle enabled disabled" cut
check test "$writes" = 0
check test "$_FS_UNVERIFIED" = toggle
# Three rejected picks must not let the fourth bypass the same functional test.
loop=$(awk '/^_fsr=0$/{p=1} p{print} p && /^done$/{exit}' "$AMPS")
RECO_LBL=bad1; RECO_CLS=cut; RECO_LATCH=0; SUGGEST='/mock/node 1 0'; calls=0
finalist_stress(){ calls=$((calls+1)); [ "$calls" -ge 4 ]; }
compute_reco(){ RECO_LBL=next$calls; }
eval "$loop"
check test "$calls" = 4
echo "finalist-removal: $F failed"
[ "$F" = 0 ]
