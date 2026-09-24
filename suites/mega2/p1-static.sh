#!/system/bin/sh
# P1 - static. Every source-level suite, plus the audit that makes "everything is tested" a checkable
# claim rather than an assurance.
#
# THE COVERAGE AUDIT IS THE POINT OF THIS PHASE.
#   rc21 -> rc22 touched 41 functions across 9 shipped files. "We tested rc22" is meaningless unless
#   each of those has something pointed at it. This phase reads the changed-function list generated
#   from the rc21 tag and FAILS for any changed function no suite mentions. A change nobody wrote a
#   test for is exactly where the next silent regression lives.

hdr "P1 STATIC"

SD=$SELF/../accd
[ -d "$SD" ] || SD=$execDir/suites/accd

# ---- 1: every t-suite ---------------------------------------------------------------------------------
_ran=0; _failed=0; _skipped_mode=
for _t in $SD/t*.sh; do
  [ -f "$_t" ] || continue
  _name=$(basename "$_t" .sh)

  # A suite that needs the cable in one state must not be RUN in the other. Left to run
  # anyway it either invents a verdict from hardware that is not there, or quietly skips its
  # own body and reports a pass over nothing - and a pass over nothing is what makes an
  # all-green unplugged run mean less than it looks. The requirement is declared in the
  # suite, next to the assertions that need it, and the phase reports the mismatch as a SKIP
  # with the reason rather than dropping it.
  _req=$(sed -n 's/^#[[:space:]]*requires:[[:space:]]*//p' "$_t" 2>/dev/null | head -1)
  case "${_req:-any}" in
    plugged)
      if [ "${EXPECT_PLUGGED:-no}" != yes ]; then
        _skipped_mode="${_skipped_mode} ${_name}"
        skip "${_name} (declares: requires plugged - this run has the cable OUT)"
        continue
      fi ;;
    unplugged)
      if [ "${EXPECT_PLUGGED:-no}" = yes ]; then
        _skipped_mode="${_skipped_mode} ${_name}"
        skip "${_name} (declares: requires unplugged - this run has the cable IN)"
        continue
      fi ;;
  esac
  _ran=$(( _ran + 1 ))
  # DC too: t72 reads $DC for diag-collect.sh and only falls back to $execDir/diag-collect.sh. That
  # fallback resolved somewhere without the file here, so t72 reported "could not extract the
  # battery-auth block" while the installed diag-collect.sh had it and t72 passed 28/0 standalone.
  # Pass it explicitly rather than relying on a default that depends on the caller's environment.
  _t0=$(date +%s 2>/dev/null || echo 0)
  execDir=$execDir DC=${DC:-$execDir/diag-collect.sh} suite_tmo sh "$_t" > $WORK/.out.$_name 2>&1
  _rc=$?
  _t1=$(date +%s 2>/dev/null || echo 0)
  _el=$(( ${_t1:-0} - ${_t0:-0} ))
  # A timeout is recognised by the CLOCK, not by the exit status. Measured on the two phones:
  # bluejay's toybox timeout returns 124, laurus's returns 143 (128+SIGTERM) and overshoots the
  # bound by 16s because mksh defers SIGTERM until its current child returns. Reading the status
  # would have filed laurus's wedge as an ordinary suite failure - a false product finding of
  # exactly the kind this harness keeps manufacturing.
  if [ "$_rc" = 0 ]; then
    _l=$(grep -E '^t[0-9]+:' $WORK/.out.$_name 2>/dev/null | tail -1)
    ok "${_name}  ${_l:-passed}"
  elif [ "$_el" -ge "$SUITE_TMO" ]; then
    _failed=$(( _failed + 1 ))
    no "${_name}  TIMEOUT: killed after ${_el}s against a ${SUITE_TMO}s bound (rc=$_rc), so its verdict is unknown"
    tail -3 $WORK/.out.$_name 2>/dev/null | sed 's/^/        /'
  else
    _failed=$(( _failed + 1 ))
    _l=$(grep -E '^t[0-9]+:' $WORK/.out.$_name 2>/dev/null | tail -1)
    no "${_name}  ${_l:-FAILED}"
    grep '  FAIL' $WORK/.out.$_name 2>/dev/null | head -4 | sed 's/^/        /'
  fi
done
note "$_ran suites ran, $_failed with failures"
if [ -n "${_skipped_mode:-}" ]; then
  note "NOT COVERED BY THIS RUN (cable state):${_skipped_mode}"
fi

# ---- 2: coverage of every rc21->rc22 change -------------------------------------------------------------
CHANGED=$execDir/suites/mega2/changed-functions.txt
_changed_for_prev=$execDir/suites/mega2/changed-functions-${PREVLBL:-}.txt
[ -n "${PREVLBL:-}" ] && [ -f "$_changed_for_prev" ] && CHANGED=$_changed_for_prev
if [ -f "$CHANGED" ]; then
  _tot=0; _cov=0; _unc=
  # The list is generated on a PC and arrives with CRLF endings. A trailing carriage return makes
  # every function name unmatchable, which reported 0 of 41 covered and looked like a catastrophic
  # product finding rather than a line-ending bug. Strip it.
  tr -d '\r' < "$CHANGED" | sed 's/^\([^ :]*\) /\1:/' > $WORK/.changed 2>/dev/null \
    || cp -f "$CHANGED" $WORK/.changed 2>/dev/null
  # One concatenated blob, searched once per function. The obvious nesting (every function against
  # every suite file) is 41 x 35 greps and took minutes on a Mi A3; this is 41.
  # Comments stripped. A name that appears only in a comment is not even a pointer, and counting it
  # produced a false clean bill: set_ch_curr's rc22 changes were graded covered on the strength of
  # the word appearing in the PROSE HEADERS of t35 and t43, neither of which asserts anything about
  # them. An audit of the rc21->rc22 diff later found 43 of 92 behavioural changes with no assertion
  # behind them while this gate reported full coverage.
  # suites/amps/ counts too. AMPS ships as amps.sh AND acc-compat.sh - the same file under two
  # names - so every AMPS function appears TWICE in the changed list, and with only suites/accd
  # scanned the gate reported 53 uncovered of which 46 were those 23 functions double-counted,
  # against a suite directory it simply never opened. A coverage number that large and that wrong
  # teaches people to ignore the gate.
  cat $SD/t*.sh $execDir/suites/amps/t*.sh $execDir/suites/mega2/p*.sh 2>/dev/null | sed 's/#.*//' > $WORK/.allsuites 2>/dev/null
  while IFS=: read -r _file _fn; do
    [ -n "${_fn:-}" ] || continue
    _tot=$(( _tot + 1 ))
    # A function counts here when a suite names it in CODE. Still generous on purpose: this catches
    # changes with nothing pointed at them. It does NOT measure whether the behaviour is asserted -
    # a grep of the source passes on an inverted comparison - so read it as a floor, never a score.
    if grep -q "$_fn" $WORK/.allsuites 2>/dev/null; then
      _cov=$(( _cov + 1 ))
    else
      _unc="${_unc}${_file}:${_fn} "
    fi
  done < $WORK/.changed
  note "changed functions: $_tot   named by a suite: $_cov   (a floor, not a coverage score)"
  if [ -z "${_unc:-}" ]; then
    ok "every rc21->rc22 changed function is named in the code of at least one suite"
  else
    no "UNCOVERED changed functions: ${_unc}- each is an rc22 change with no test pointed at it"
  fi
else
  no "changed-functions.txt missing - cannot prove rc22 changes are covered"
fi

# ---- 3: no debug instrumentation in shipped source -------------------------------------------------------
# The thermal investigation added DIAG probes to accd.sh. They were temporary by construction and must
# never reach a user: they write to the ledger every 20s on a hot pack.
#
# Matches the PROBE, not the word. AMPS logs a legitimate WARN_DIAG field in amps.sh and
# acc-compat.sh, and a bare 'DIAG' search reported those as shipped debug code - a false alarm on a
# release gate is worse than no gate, because the next person learns to ignore it.
_diag=0
for _f in $execDir/*.sh; do
  [ -f "$_f" ] || continue
  _n=$(cnt -E '_wlog "DIAG|DIAG2 entry' "$_f")
  _diag=$(( _diag + _n ))
done
[ "${_diag:-0}" -eq 0 ] \
  && ok "no DIAG debug probes in shipped source" \
  || no "${_diag} DIAG probe line(s) still shipped - temporary instrumentation must not release"

# ---- 4: device-shell syntax, not bash ---------------------------------------------------------------------
# bash on the PC accepts constructs mksh/toybox reject. The only syntax check that counts is the one
# run by the shell that will execute it.
_bad=0
for _f in $execDir/*.sh; do
  [ -f "$_f" ] || continue
  sh -n "$_f" 2>/dev/null || { no "syntax error under the device shell: $(basename $_f)"; _bad=$(( _bad + 1 )); }
done
[ "${_bad:-0}" -eq 0 ] && ok "every shipped script parses under this phone's own shell"

# ---- 5: house rules ------------------------------------------------------------------------------------------
# Em-dashes in user-visible strings are a standing prohibition across this project.
_em=0
for _f in $execDir/*.sh; do
  [ -f "$_f" ] || continue
  _n=$(cnt -F '—' "$_f"); _em=$(( _em + _n ))
  _n=$(cnt -F '–' "$_f"); _em=$(( _em + _n ))
done
[ "${_em:-0}" -eq 0 ] \
  && ok "no em-dashes or en-dashes in shipped strings" \
  || no "${_em} em/en-dash(es) in shipped source"

# ---- 6: the module declares what we think it declares ------------------------------------------------------
_vc=$(grep -m1 '^versionCode=' $execDir/module.prop 2>/dev/null | cut -d= -f2)
_ver=$(grep -m1 '^version=' $execDir/module.prop 2>/dev/null | cut -d= -f2)
note "module: ${_ver:-unknown}  versionCode=${_vc:-unknown}"
case "${_vc:-}" in
  ''|*[!0-9]*) no "versionCode is not numeric - the updater cannot compare it" ;;
  *) ok "versionCode is numeric (${_vc})" ;;
esac
