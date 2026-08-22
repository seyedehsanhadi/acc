#!/system/bin/sh
# t114 - `acc -t`'s wait ceiling must be a number of SECONDS, not a number of loop iterations.
#
# THE DEFECT, measured on both test phones with rc24 installed, unplugged:
#     ACC_T_WAIT=20 acc -t   ->  ran 178s, printed one line, never reached its give-up message
#
# rc23 spun on not_charging forever and needed Ctrl-C. rc24 added `_twmax=${ACC_T_WAIT:-180}` and a
# give-up branch, which is the fix and it works - the command does end. But the counter it compares
# is incremented once per LOOP ITERATION:
#
#     while { _acc_nopromo=1; not_charging; }; do ... sleep 1; _tw=$(( _tw + 1 )); done
#
# and one iteration is not one second. not_charging walks its own confirmation window - `for i in
# $(seq $_STI)` with _STI=35, one second apart - so an iteration costs about 36 seconds on a phone
# that is not charging. A ceiling of 180 is therefore about 108 minutes, and the user-facing message
# says "still waiting for charging to start (15s of 180s)" while roughly nine minutes have passed.
#
# The number is wrong in the only two places a user ever sees it: the progress line and the give-up
# line. This suite pins it to the clock.
#
# EXECUTED, not grepped. The shipped loop is cut out of acc.sh and run against a not_charging that
# takes a known, deliberately long time, so the assertion is about elapsed wall-clock seconds.
#
# NO HARDWARE. Nothing is read from sysfs and no daemon is signalled.

ID=t114
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AS=$execDir/acc.sh
W=${W:-/data/local/tmp/t114}
[ -f "$AS" ] || { no "acc.sh not found at $AS"; fin; }
rm -rf $W 2>/dev/null; mkdir -p $W 2>/dev/null

# ---- cut the shipped wait loop out of acc.sh -------------------------------------------------------
# From the line that sets the ceiling through the `done` that closes the while.
_from=$(grep -n '_twmax=\${ACC_T_WAIT' "$AS" | head -1 | cut -d: -f1)
if [ -z "$_from" ]; then
  no "could not find the ACC_T_WAIT ceiling in acc.sh - has the wait been removed?"
  fin
fi
_to=$(awk -v s="$_from" 'NR >= s && /^      done$/ { print NR; exit }' "$AS")
if [ -z "$_to" ]; then
  no "could not find the end of the wait loop"
  fin
fi
sed -n "${_from},${_to}p" "$AS" > $W/loop.sh
ok "extracted the shipped wait loop, lines $_from-$_to ($(wc -l < $W/loop.sh) lines)"

# The extractor is the usual way this kind of suite goes quietly vacuous, so prove it caught the
# parts under test rather than an empty range.
grep -q 'Giving up after' $W/loop.sh \
  && ok "the extract contains the give-up branch" \
  || { no "the extract does not contain the give-up branch - it is truncated"; fin; }
grep -q 'still waiting for charging to start' $W/loop.sh \
  && ok "the extract contains the progress line" \
  || { no "the extract does not contain the progress line"; fin; }

# ---- the harness ------------------------------------------------------------------------------------
# not_charging is stubbed to take SLOW seconds and always answer "not charging", which is exactly
# what an unplugged phone does. Everything else the loop touches is stubbed to nothing.
#   run <ceiling> <not_charging cost in seconds>  -> prints "<elapsed> <reported>"
run(){
  _cap=$1; _slow=$2
  {
    echo "SLOW=$_slow"
    echo 'not_charging(){ sleep $SLOW; return 0; }'
    echo '_t_plugged(){ return 1; }'
    echo 'print_unplugged(){ printf "unplugged\n"; }'
    echo 'exitCode_=0'
    echo '_logOn=:'
    echo "ACC_T_WAIT=$_cap"
    echo 'set +x'
    cat $W/loop.sh
  } > $W/run.sh
  _t0=$(date +%s)
  _out=$(/system/bin/sh $W/run.sh 2>/dev/null)
  _t1=$(date +%s)
  _said=$(printf '%s\n' "$_out" | sed -n 's/.*Giving up after \([0-9]*\)s.*/\1/p' | head -1)
  echo "$(( _t1 - _t0 )) ${_said:-none}"
}

# ---- 1: THE DEFECT. A 10s ceiling against a 4s not_charging must end in about 10s. -----------------
# Counting iterations, the loop needs 10 of them at ~5s each and takes about 50s. Counting seconds,
# it gives up on the third pass, at about 12s. The bar is set at 25s: comfortably above the honest
# answer, comfortably below the iteration-counting one, so neither a slow phone nor a fast one
# changes the verdict.
set -- $(run 10 4)
_el=$1; _said=$2
echo "  (ceiling 10s, not_charging costs 4s: ran ${_el}s, reported '${_said}')"
if [ "$_said" = none ]; then
  no "the loop never reached its give-up message inside the run"
elif [ "$_el" -le 25 ] 2>/dev/null; then
  ok "a 10s ceiling ended the wait in ${_el}s - the ceiling is wall-clock seconds"
else
  no "a 10s ceiling took ${_el}s - the ceiling is counting ITERATIONS, not seconds (each costs ~4s here)"
fi

# ---- 2: the number it TELLS the user must be the number of seconds that passed --------------------
# "Giving up after 10s" while 50 seconds have passed is worse than no message: it sends the next
# person debugging this at the wrong thing entirely.
if [ "$_said" = none ]; then
  no "no give-up figure to check"
elif [ "$_said" -ge "$(( _el - 8 ))" ] 2>/dev/null && [ "$_said" -le "$(( _el + 8 ))" ] 2>/dev/null; then
  ok "the give-up message reported ${_said}s against ${_el}s actually elapsed"
else
  no "the give-up message reported ${_said}s but ${_el}s actually elapsed - the figure shown to the user is not seconds"
fi

# ---- 3: the ceiling must still be honoured when not_charging is fast -------------------------------
# The fix must not work only for slow calls. With a cheap not_charging the loop is dominated by its
# own `sleep 1`, and a 6s ceiling must still stop at about 6s rather than running on.
set -- $(run 6 0)
_el2=$1; _said2=$2
echo "  (ceiling 6s, not_charging is free: ran ${_el2}s, reported '${_said2}')"
if [ "$_said2" = none ]; then
  no "the fast case never reached the give-up message"
elif [ "$_el2" -le 20 ] 2>/dev/null; then
  ok "a 6s ceiling with a cheap not_charging ended in ${_el2}s"
else
  no "a 6s ceiling with a cheap not_charging took ${_el2}s"
fi

# ---- 4: a phone that IS charging must not be delayed at all -----------------------------------------
# The whole loop exists for the failure case. If not_charging answers false the wait must not run,
# and no ceiling, message or sleep may be paid by the case that works.
{
  echo 'not_charging(){ return 1; }'
  echo '_t_plugged(){ return 0; }'
  echo 'print_unplugged(){ printf "unplugged\n"; }'
  echo 'exitCode_=0'
  echo '_logOn=:'
  echo 'ACC_T_WAIT=300'
  echo 'set +x'
  cat $W/loop.sh
} > $W/fast.sh
_t0=$(date +%s)
_out=$(/system/bin/sh $W/fast.sh 2>/dev/null)
_el3=$(( $(date +%s) - _t0 ))
if [ "$_el3" -le 3 ] 2>/dev/null && [ -z "$(printf '%s' "$_out" | tr -d '[:space:]')" ]; then
  ok "a charging phone falls straight through in ${_el3}s and prints nothing"
else
  no "a charging phone was delayed ${_el3}s or printed something: [$(printf '%s' "$_out" | tr '\n' ' ')]"
fi

# ---- 5: can this suite still fail? -------------------------------------------------------------------
# Take the clock away. The loop keeps a documented fallback for a device with no usable `date`, and
# that fallback is the old per-pass count - so blanking _tstart reproduces exactly the timing this
# suite exists to reject. If case 1 cannot see that, it cannot see anything, and the greens above
# would only mean the harness never drove the loop.
#
# On an unfixed build there is no _tstart to blank, the mutation is a no-op, and the run is already
# slow: either way this case ends up asserting the same thing, which is why it is written against
# elapsed time rather than against the presence of a particular line.
{
  echo 'SLOW=4'
  echo 'not_charging(){ sleep $SLOW; return 0; }'
  echo '_t_plugged(){ return 1; }'
  echo 'print_unplugged(){ printf "unplugged\n"; }'
  echo 'exitCode_=0'; echo '_logOn=:'; echo 'ACC_T_WAIT=10'; echo 'set +x'
  # Neutralise the clock read wherever the loop takes it.
  sed 's/^      _tstart=\$(date +%s 2>\/dev\/null).*/      _tstart=/' $W/loop.sh
} > $W/mutrun.sh
_t0=$(date +%s)
/system/bin/sh $W/mutrun.sh >/dev/null 2>&1
_elm=$(( $(date +%s) - _t0 ))
[ "$_elm" -gt 25 ] 2>/dev/null \
  && ok "mutation caught: with no clock the loop counts passes again and takes ${_elm}s, past the 25s bar" \
  || no "mutation NOT caught: the pass-counting loop finished in ${_elm}s, so case 1 cannot fail"

fin
