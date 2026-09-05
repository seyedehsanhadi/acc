#!/system/bin/sh
# t113 - the parts of the rc23->rc24 delta that t111 does not grade.
#
# t111 covers the contract policy, the unit normalisers, the plug edge and the packaging changes.
# Six edits fall outside it, and an ungraded edit is an unproven one:
#
#   the collapse WARNING still compared a raw microvolt literal
#   aim-high could fire while ACC was holding a pause, and at or above the pause level
#   the fast-charge session guard compared a raw microvolt literal
#   enable_charging's fallback re-arm sweep had no ceiling
#   write()'s retry loop never re-read the node it had just written
#   the per-plug kick marker had to die with the cable
#
# SAME CONTRACT AS t111. Every case is executed or matched against BOTH trees and is only credited
# when rc23 answers UNSAFE and rc24 answers SAFE. BOTH-SAFE is reported as a failure, because a case
# that passes on the old build has demonstrated nothing about the new one.
#
# NO HARDWARE. Scratch fixtures under /data/local/tmp; the daemon is never signalled and no charge
# node is read or written.
#
#   ARM23=/data/local/tmp/rc23tree ARM24=/data/local/tmp/rc24tree sh t113-rc24-delta-remainder.sh

ID=t113
P=0; F=0
ARM23=${ARM23:-/data/local/tmp/rc23tree}
ARM24=${ARM24:-/data/local/tmp/rc24tree}
W=${W:-/data/local/tmp/t113}

ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
nd(){ F=$((F+1)); echo "  FAIL  $* [NON-DISCRIMINATING: passes on rc23 too - this case proves nothing]"; }
sec(){ echo; echo "-- $*"; }

rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

sec "PREFLIGHT"
_pf=0
for a in "$ARM23" "$ARM24"; do
  [ -f "$a/accd.sh" ] && [ -f "$a/misc-functions.sh" ] || { echo "  ABORT: $a is not an ACC tree"; _pf=1; }
done
[ "$_pf" = 0 ] || { echo "$ID: preflight failed, no verdict"; exit 1; }
if cmp -s "$ARM23/misc-functions.sh" "$ARM24/misc-functions.sh" 2>/dev/null; then
  echo "  ABORT: the two arms carry the same misc-functions.sh"
  echo "$ID: preflight failed, no verdict"; exit 1
fi
ok "two distinct arms staged"

dual() {
  _lbl=$1; _fn=$2
  _r23=$($_fn "$ARM23" 2>/dev/null | tail -1)
  _r24=$($_fn "$ARM24" 2>/dev/null | tail -1)
  case "${_r23:-?}/${_r24:-?}" in
    UNSAFE/SAFE)   ok "$_lbl" ;;
    SAFE/SAFE)     nd "$_lbl" ;;
    UNSAFE/UNSAFE) no "$_lbl [BOTH-UNSAFE: the fix is absent or does not cover this case]" ;;
    SAFE/UNSAFE)   no "$_lbl [INVERTED: rc24 regressed against rc23]" ;;
    *)             no "$_lbl [NO VERDICT: rc23='$_r23' rc24='$_r24' - the case body failed to run]" ;;
  esac
}

src() { sed 's/#.*//' "$1/$2" 2>/dev/null; }
fnx() { sed -n "/^$3() {/,/^}/p" "$1/$2" 2>/dev/null; }
fni() { sed -n "/^  $3() {/,/^  }/p" "$1/$2" 2>/dev/null; }

# The aim-high entry condition, cut out of whichever tree is being graded and evaluated as written.
# The block spans four physical lines joined by backslashes in both builds; taking the whole span
# and stripping the continuations is what keeps this honest when the guard is on line two or three.
aimcond() {
  _a=$1
  # grep -F, not a pattern: ${sawUnplug:-false} is full of regex metacharacters and a BRE match
  # against it returns nothing, which reads exactly like "the guard is absent".
  _l=$(src "$_a" accd.sh | grep -nF 'freshPlug && ${sawUnplug:-false}' | head -1 | cut -d: -f1)
  [ -n "$_l" ] || return 1
  # The condition is a backslash-continued run: two lines in rc23, three in rc24. Take a window
  # wide enough for either, join it, and cut at the `then` that closes it - whichever line that
  # lands on. The leading `if` goes too, or the caller ends up with `if if`.
  src "$_a" accd.sh | sed -n "${_l},$(( _l + 3 ))p" | sed 's/[\\]$//' | tr '\n' ' ' \
    | sed 's/then.*//; s/^[ 	]*if //; s/;[ 	]*$//'
}

# Evaluate that condition in a stated world. Prints FIRED or WITHHELD.
aimrun() {
  _c=$1; _held=$2; _below=$3; _tag=$4
  mkdir -p "$W/$_tag/tmp" "$W/$_tag/data" 2>/dev/null
  {
    echo "freshPlug=true; sawUnplug=true; _aimStall=false"
    echo "chDisabledByAcc=$_held"
    if [ "$_below" = yes ]; then echo "_lt_pause_cap(){ return 0; }"; else echo "_lt_pause_cap(){ return 1; }"; fi
    echo "TMPDIR=$W/$_tag/tmp; dataDir=$W/$_tag/data"
    echo "if $_c; then echo FIRED; else echo WITHHELD; fi"
  } > "$W/$_tag.sh"
  /system/bin/sh "$W/$_tag.sh" 2>/dev/null | tail -1
}

# ============================================================================================
sec "1  THE TWO REMAINING RAW MICROVOLT LITERALS"
# Both are the same defect as the contract latch: a threshold written in microvolts is unreachable
# on a kernel that reports millivolts, so the check silently never fires on half the fleet.

c_collapse_units() { A=$1
  # The HVDCP/PD/QC collapse warning. rc23 compared the raw node against 5500000. On a millivolt
  # phone a 4.4V bus reads 4400 and a healthy 9V bus reads 9000 - both are below 5500000, so the
  # warning fires on a working contract and distinguishes nothing at all.
  if src $A accd.sh | grep -F 'lt 5500000' >/dev/null 2>&1; then echo UNSAFE; return; fi
  src $A accd.sh | grep -qF 'hvPeakMaxMv' || { echo UNSAFE; return; }
  echo SAFE
}
dual "the collapse warning compares mV, not a raw microvolt literal" c_collapse_units

c_fastcharge_units() { A=$1
  # fast_session()'s "is this a high-voltage supply" guard. Same literal, same consequence: on a
  # millivolt phone it can never be true, so every QC/PD plug is treated as a plain 5V one and the
  # fast-charge guard that exists to protect a pump contract stops protecting anything.
  b=$(fni $A accd.sh fast_session)
  [ -n "$b" ] || b=$(fnx $A accd.sh fast_session)
  [ -n "$b" ] || { echo UNSAFE; return; }
  printf '%s\n' "$b" | sed 's/#.*//' | grep -qF '6000000' && { echo UNSAFE; return; }
  printf '%s\n' "$b" | sed 's/#.*//' | grep -qF '_mv ' || { echo UNSAFE; return; }
  echo SAFE
}
dual "the fast-charge session guard compares mV" c_fastcharge_units

# ============================================================================================
sec "2  AIM-HIGH MUST YIELD TO AN ACTIVE PAUSE  (B2)"
# The aim-high block runs at the TOP of the daemon loop, ahead of the capacity pause below it.
# rc23 entered it knowing nothing about whether ACC was currently holding a cut, so a re-plug at
# 79% with the limit at 80% could lift the input ceiling and then spend up to 17 seconds - a
# 2-second settle plus a 15-second poll - with the pause unenforced.

c_aim_yields_hold() { A=$1
  c=$(aimcond $A) || { echo UNSAFE; return; }
  r=$(aimrun "$c" true yes yield_hold)
  [ "$r" = WITHHELD ] && echo SAFE || echo UNSAFE
}
dual "a fresh plug during an ACC-held pause does not trigger aim-high" c_aim_yields_hold

c_aim_yields_cap() { A=$1
  c=$(aimcond $A) || { echo UNSAFE; return; }
  r=$(aimrun "$c" false no yield_cap)
  [ "$r" = WITHHELD ] && echo SAFE || echo UNSAFE
}
dual "a fresh plug at or above the pause level does not trigger aim-high" c_aim_yields_cap

# Not a dual, and deliberately so: this is the direction that must NOT change. A guard that closes
# the path outright is not a fix, it is a different bug, and only a both-builds check can see that.
_c23=$(aimcond "$ARM23"); _c24=$(aimcond "$ARM24")
_f23=$(aimrun "$_c23" false yes reach23); _f24=$(aimrun "$_c24" false yes reach24)
if [ "$_f23" = FIRED ] && [ "$_f24" = FIRED ]; then
  ok "a genuine fresh plug below the pause still reaches aim-high in both builds"
else
  no "aim-high reachability changed: rc23='$_f23' rc24='$_f24' - the guard closed the path"
fi

# ============================================================================================
sec "3  THE FALLBACK RE-ARM SWEEP HAS A CEILING"
# enable_charging falls back to a full candidate sweep when flip_sw cannot re-arm. Unbounded, an
# empty chargingSwitch held a plugged Mi A3 off charge for over five minutes while the sweep walked
# the whole list. The ceiling is a local of a helper, so mksh's dynamic scoping hands it to
# cycle_switches for that call alone - accd's exit-trap restore sweep stays unbounded, which is
# what lets a stranded phone get its switch back.

c_rearm_bounded() { A=$1
  b=$(fnx $A misc-functions.sh enable_charging)
  [ -n "$b" ] || { echo UNSAFE; return; }
  printf '%s\n' "$b" | sed 's/#.*//' | grep -qF 'present && cycle_switches on' && { echo UNSAFE; return; }
  printf '%s\n' "$b" | sed 's/#.*//' | grep -qF '_rearm_sweep' || { echo UNSAFE; return; }
  echo SAFE
}
dual "enable_charging's fallback sweep goes through the bounded helper" c_rearm_bounded

c_rearm_budget_local() { A=$1
  # Executed, not read. The helper must hand cycle_switches a budget, and that budget must be gone
  # the moment the helper returns - otherwise the exit-trap restore sweep inherits a ceiling and a
  # phone with a latched switch never gets it released.
  h=$(fnx $A misc-functions.sh _rearm_sweep)
  [ -n "$h" ] || { echo UNSAFE; return; }
  {
    printf '%s\n' "$h"
    echo 'cycle_switches(){ echo "budget=${_swEnd:-none}"; }'
    echo '_rearm_sweep'
    echo 'echo "after=${_swEnd:-none}"'
  } > $W/rearm.sh
  r=$(/system/bin/sh $W/rearm.sh 2>/dev/null | tr '\n' ' ')
  case "$r" in
    *budget=none*) echo UNSAFE;;
    *after=none*)  echo SAFE;;
    *)             echo UNSAFE;;
  esac
}
dual "the re-arm budget reaches cycle_switches and does not outlive the call" c_rearm_budget_local

# ============================================================================================
sec "4  write() RETRIED THE WRONG BRANCH  (B8, second half)"
# t111 proves the retry now runs only for an ATTEMPTED, unverified write. This measures the other
# half - which branch the retry loop was actually attached to - and it is worse than it reads.
#
#   rc23:  [ $i = x ] && return ${3-1} || { five more echoes }
#
# i=x means the write did NOT verify. So rc23 returned immediately on the case that needed
# retrying, and fired five EXTRA echoes into a node that had already taken the value - the exact
# re-assertion rc14 made write() idempotent to avoid, because re-writing a live charge node
# re-triggers AICL and the charge-pump state machine on QC/PD/PPS phones.
#
# rc24 swaps them: a verified write returns after one echo, and only an unverified one spends the
# retry budget, re-reading the node after each attempt.
#
# Both directions are counted here, by instrumenting usleep - the retry loop is its only caller in
# this function, so the count IS the number of retry iterations. Nothing is inferred from source.

# Build a write() harness in $W and run one scenario. Prints the usleep count and the verdict.
#   wrun <arm> <verify|clamp>
wrun() {
  _a=$1; _mode=$2
  _d=$W/w_$_mode
  rm -rf $_d 2>/dev/null; mkdir -p $_d/logs 2>/dev/null
  echo 1000 > $_d/node
  : > $_d/ticks
  b=$(fnx $_a misc-functions.sh write)
  [ -n "$b" ] || { echo "noverdict:nofunction"; return; }
  {
    echo "TMPDIR=$_d; dataDir=$_d; lastNode="
    echo "_wlog(){ :; }"
    echo "usleep(){ echo t >> $_d/ticks; }"
    echo 'seq(){ _si=1; while [ $_si -le $1 ]; do echo $_si; _si=$((_si+1)); done; }'
    printf '%s\n' "$b"
    if [ "$_mode" = verify ]; then
      # An ordinary write that lands: the node ends up holding exactly what was asked for.
      echo "write 5000000 $_d/node && _rc=ok || _rc=fail"
    else
      # A write that cannot verify, using write()'s own documented value-from-a-file form: when the
      # value argument is a path, write() compares the node against that file's CONTENTS. The node
      # receives the path string, so the readback can never match. No stubbing of echo, cat or the
      # filesystem is involved - this is the shipped comparison, given inputs it cannot satisfy.
      echo "7777" > $_d/want
      echo "write $_d/want $_d/node && _rc=ok || _rc=fail"
    fi
    echo "echo \"ticks=\$(wc -l < $_d/ticks | tr -d ' ') rc=\$_rc\""
  } > $_d/run.sh
  /system/bin/sh $_d/run.sh 2>/dev/null | tail -1
}

c_write_one_echo() { A=$1
  # A write that verifies must cost ONE echo. rc23 spends four more.
  r=$(wrun $A verify)
  case "$r" in
    "ticks=0 rc=ok") echo SAFE;;
    ticks=*)         echo UNSAFE;;
    *)               echo "noverdict:$r";;
  esac
}
dual "a write that verifies costs one echo, not six" c_write_one_echo

c_write_retries_unverified() { A=$1
  # And the case that genuinely needs the budget must now get it. rc23 returns without retrying.
  r=$(wrun $A clamp)
  case "$r" in
    ticks=0*)  echo UNSAFE;;
    ticks=*rc=fail) echo SAFE;;
    *)         echo "noverdict:$r";;
  esac
}
dual "an unverified write spends the retry budget and still reports failure" c_write_retries_unverified

c_write_verifies() { A=$1
  b=$(fnx $A misc-functions.sh write)
  [ -n "$b" ] || { echo UNSAFE; return; }
  printf '%s\n' "$b" | sed 's/#.*//' | sed -n '/for i in \$(seq \$seq)/,/done/p' > $W/retry.txt
  [ -s $W/retry.txt ] || { echo UNSAFE; return; }
  grep -qF 'cat $2' $W/retry.txt || { echo UNSAFE; return; }
  grep -qF '"$f" = "$one"' $W/retry.txt || { echo UNSAFE; return; }
  echo SAFE
}
dual "the retry loop re-reads the node and compares it to the target" c_write_verifies

# ============================================================================================
sec "5  THE PER-PLUG KICK MARKER DIES WITH THE CABLE"
# .hvkicked is what makes "one repair per plug" true. If the unplug branch does not remove it, a
# phone gets exactly one repair for the rest of the boot; if anything else removes it, the
# once-per-plug budget stops being a budget.

c_kicked_unplug() { A=$1
  s=$(src $A accd.sh | grep -F 'rm -f $TMPDIR/.hvaim')
  [ -n "$s" ] || { echo UNSAFE; return; }
  case "$s" in *.hvkicked*) echo SAFE;; *) echo UNSAFE;; esac
}
dual "the unplug branch clears .hvkicked alongside the other per-plug markers" c_kicked_unplug

c_kicked_with_plug_identity() { A=$1
  # A missed unplug can now clear the marker too: if the daemon slept through a whole cable cycle,
  # keeping the old plug's budget is just as wrong as keeping it after an observed unplug. Do not
  # count sites. Require every clear to travel with the plug-identity markers instead, and forbid a
  # second owner in misc-functions.sh. rc23 still answers UNSAFE because it has no clear at all.
  _r=$(src $A accd.sh | grep -F '.hvkicked' | grep 'rm ')
  [ -n "$_r" ] || { echo UNSAFE; return; }
  printf '%s\n' "$_r" | grep -vF '.hvpeak' | grep -q . && { echo UNSAFE; return; }
  printf '%s\n' "$_r" | grep -vF '.hvaim' | grep -q . && { echo UNSAFE; return; }
  src $A misc-functions.sh | grep -F '.hvkicked' | grep -q 'rm ' && { echo UNSAFE; return; }
  echo SAFE
}
dual ".hvkicked is cleared only with the rest of the plug identity" c_kicked_with_plug_identity

# ============================================================================================
sec "6  MUTATION - can this suite still fail?"
# Every case above claims rc24 differs from rc23. Prove the graders can still say no, by handing
# them an rc24 tree with the fix taken back out.

rm -rf $W/mut 2>/dev/null; mkdir -p $W/mut 2>/dev/null
cp "$ARM24/misc-functions.sh" "$ARM24/accd.sh" $W/mut/ 2>/dev/null

sed 's/_rearm_sweep; }/cycle_switches on; }/' "$ARM24/misc-functions.sh" > $W/mut/misc-functions.sh 2>/dev/null
if [ "$(c_rearm_bounded $W/mut)" = UNSAFE ]; then
  ok "mutation caught: putting the unbounded sweep back is seen"
else
  no "mutation NOT caught: the bounded-sweep case cannot fail"
fi
cp "$ARM24/misc-functions.sh" $W/mut/ 2>/dev/null

sed 's/\$TMPDIR\/.hvpeak \$TMPDIR\/.hvkicked/$TMPDIR\/.hvpeak/' "$ARM24/accd.sh" > $W/mut/accd.sh 2>/dev/null
if [ "$(c_kicked_unplug $W/mut)" = UNSAFE ]; then
  ok "mutation caught: dropping .hvkicked from the unplug clear is seen"
else
  no "mutation NOT caught: the per-plug marker case cannot fail"
fi
cp "$ARM24/accd.sh" $W/mut/ 2>/dev/null

sed 's/hvPeakMaxMv:-5500}"/hvPeakMaxMv:-5500}" ; : lt 5500000/' "$ARM24/accd.sh" > $W/mut/accd.sh 2>/dev/null
if [ "$(c_collapse_units $W/mut)" = UNSAFE ]; then
  ok "mutation caught: a microvolt literal back in the collapse path is seen"
else
  no "mutation NOT caught: the collapse-units case cannot fail"
fi

echo
echo "$ID: $P passed, $F failed"
[ "$F" -eq 0 ] && exit 0 || exit 1
