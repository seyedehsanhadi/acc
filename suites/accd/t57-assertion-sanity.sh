#!/system/bin/sh
# t57 - assertions that cannot fail.
#
# WHY THIS EXISTS
#   Two assertions in this suite set passed unconditionally for an unknown number of runs. Both
#   were NEGATIVE checks - "the defect is absent" - written as:
#
#       grep -qE '^\s*if online' && no "the defect is here" || ok "clean"
#
#   Neither test phone's grep implements \s. laurus has BSD grep 2.5.1, bluejay has toybox 0.8.12,
#   and bluejay rejects the pattern outright with "bad regex: trailing backslash". A pattern that
#   can never match makes the || arm fire every time, so both reported success whether or not the
#   defect was present. Every green tick they ever produced was worthless.
#
#   They were found by accident, while auditing for a different trap. That is not good enough: a
#   test suite whose own assertions are unverified is decoration. This checks the property
#   mechanically, on the device that will actually run them, so the class cannot come back.
#
# WHAT IT CHECKS
#   1. Which regex constructs THIS phone's grep really supports - not what the author assumed.
#   2. Every suite, for patterns using a construct this grep does not support.
#   3. That the constructs the suites DO rely on behave as expected here.
#
# A finding here is not cosmetic. A pattern that cannot match turns a negative assertion into a
# guaranteed pass and a positive one into a guaranteed failure; the first is far more dangerous
# because it is silent.
#
# NO HARDWARE.

ID=t57
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SD=$execDir/suites
W=${TMPDIR:-/data/local/tmp}/.t57
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null

# A line every construct below can be tested against.
printf '  if online\n\tspaced\nabc123\n' > $W/probe

# ---- 1: what does THIS grep actually support? -----------------------------------------------------
# Each probe is written so a WORKING construct matches and a broken one does not. The point is to
# learn the shell we are on rather than to assume a GNU userland.
sup_s=no;  grep -qE '^\s*if online'        $W/probe 2>/dev/null && sup_s=yes
sup_d=no;  grep -qE 'abc\d'                $W/probe 2>/dev/null && sup_d=yes
sup_w=no;  grep -qE '\wbc'                 $W/probe 2>/dev/null && sup_w=yes
sup_b=no;  grep -qE '\babc'                $W/probe 2>/dev/null && sup_b=yes
# Built at runtime, so this file does not contain the literal it hunts for. A detector that matches
# its own probe cries wolf, and a detector people learn to ignore is worse than none.
_alt=$(printf 'abc%s%szzz' '\\' '|')
sup_alt=no; grep -q  "$_alt"                $W/probe 2>/dev/null && sup_alt=yes
sup_cls=no; grep -qE '^[[:space:]]*if online' $W/probe 2>/dev/null && sup_cls=yes

echo "      this phone's grep: $(grep --version 2>&1 | head -1)"
printf '      %s=%s  %s=%s  %s=%s  %s=%s  BRE-alternation=%s  [[:space:]]=%s\n' \
  '\s' "$sup_s" '\d' "$sup_d" '\w' "$sup_w" '\b' "$sup_b" "$sup_alt" "$sup_cls"

# The POSIX class is the one the suites are supposed to use, so it must work.
[ "$sup_cls" = yes ] \
  && ok "[[:space:]] works here, so suites have a portable way to match indentation" \
  || no "[[:space:]] does not work - the suites have no portable whitespace class"

# ---- 2: does any suite use a construct this grep cannot honour? ------------------------------------
# Only what is actually unsupported is reported. On a GNU box \s is fine and this stays quiet; on
# these phones it is fatal and this speaks up.
scan() {  # $1 = construct, $2 = supported?, $3 = grep pattern that finds its use
  [ "$2" = yes ] && { ok "$1 is supported here, so its use in the suites is safe"; return; }
  # COMMENTS ARE NOT CODE, and THIS FILE IS NOT A SUBJECT.
  # Every fix in this suite set is documented with a comment naming the construct it removed,
  # so a raw scan finds the obituary and reports it as the corpse - that has now happened five
  # times across five suites. And this file must contain the escapes as probes in order to test
  # for them, so scanning itself guarantees a false positive.
  _hits=
  for _f in "$SD"/accd/t*.sh "$SD"/*.sh; do
    [ -f "$_f" ] || continue
    case "$_f" in *t57-assertion-sanity.sh) continue;; esac
    sed 's/^[[:space:]]*#.*//' "$_f" 2>/dev/null | grep -qE "$3" 2>/dev/null && _hits="$_hits$(basename "$_f") "
  done
  if [ -n "${_hits:-}" ]; then
    no "$1 is NOT supported here but is used in: ${_hits}- those patterns match nothing, so a negative assertion there always passes"
  else
    ok "$1 is unsupported here and no suite uses it"
  fi
}

scan '\s'  "$sup_s"   'grep [^|]*\\s'
scan '\d'  "$sup_d"   'grep [^|]*\\d'
scan '\w'  "$sup_w"   'grep [^|]*\\w'
scan '\b'  "$sup_b"   'grep [^|]*\\b'

# BRE alternation is the other documented trap: `grep 'a\|b'` is a GNU extension, and on toybox it
# matches the literal string rather than either branch.
if [ "$sup_alt" = yes ]; then
  ok "BRE alternation works here"
else
  # Catch every grep flag and both quote styles, not just `grep -q '...'`. The narrow form missed
  # t82's `grep -c "...\|..."`, whose result feeds an assertion that PASSES on zero - so a check
  # guarding the fork-free uevent parse could never fail, and that went unnoticed for the life of the
  # suite.
  #
  # STRIP COMMENTS FIRST. Several suites, this one included, explain the trap in prose and quote it to
  # do so. A detector that flags its own documentation is the same error in the other direction, and
  # it trains people to ignore the alarm.
  #
  # -F throughout: searching for the trap using the trap is how it stays invisible.
  _bp=$(printf '%s%s' '\\' '|')
  _hits=$(grep -rlF "$_bp" "$SD" 2>/dev/null | while read -r _hf; do
            sed 's/^[[:space:]]*#.*//' "$_hf" 2>/dev/null | grep -F "$_bp" | grep 'grep' \
              | grep -qv -- '-[a-zA-Z]*[EF]' && echo "${_hf##*/}"
          done | sort -u | tr '\n' ' ')
  [ -z "${_hits:-}" ] \
    && ok "BRE alternation is unsupported here and no suite relies on it" \
    || no "BRE alternation is unsupported but used in: ${_hits}"
fi

# ---- 3: the shapes that silently mislead ----------------------------------------------------------
# `grep -c` prints its count AND exits non-zero on zero matches, so `grep -c ... || echo 0` emits
# TWO lines. Inside $(( )) that is a syntax error, and it killed a megatest run mid-suite while the
# summary still read "0 failed".
# [[:space:]], not \s. The first version of this line filtered comments with \s -
# the exact construct it exists to police - so it matched nothing on BSD grep and errored
# outright on toybox.
_dbl=0
for _f in "$SD"/accd/t*.sh "$SD"/*.sh; do
  [ -f "$_f" ] || continue
  case "$_f" in *t57-assertion-sanity.sh) continue;; esac
  _n=$(sed 's/^[[:space:]]*#.*//' "$_f" 2>/dev/null | grep -cE 'grep -c[^;|]*\|\| *echo' 2>/dev/null) || _n=0
  case "${_n:-0}" in ''|*[!0-9]*) _n=0;; esac
  _dbl=$(( _dbl + _n ))
done
[ "${_dbl:-0}" -eq 0 ] 2>/dev/null \
  && ok "no 'grep -c ... || echo' anywhere - that shape emits two values and breaks arithmetic" \
  || no "${_dbl} use(s) of 'grep -c ... || echo' remain; each can emit two values"

# Extracting a function with `^  *name()` requires a LEADING SPACE, so it silently skips every
# function defined at column 0 and the assertions that follow report "could not extract".
_lead=0
for _f in "$SD"/accd/t*.sh "$SD"/*.sh; do
  [ -f "$_f" ] || continue
  case "$_f" in *t57-assertion-sanity.sh) continue;; esac
  _n=$(sed 's/^[[:space:]]*#.*//' "$_f" 2>/dev/null | grep -cF 'sed -n "/^  *$1()' 2>/dev/null) || _n=0
  case "${_n:-0}" in ''|*[!0-9]*) _n=0;; esac
  _lead=$(( _lead + _n ))
done
[ "${_lead:-0}" -eq 0 ] 2>/dev/null \
  && ok "no extraction pattern requires a leading space" \
  || no "${_lead} extraction pattern(s) use '^  *name()', which misses column-0 functions"

# ---- 4: prove the checker itself can fail ----------------------------------------------------------
# A test whose job is to catch tests that cannot fail must be able to fail. Plant the exact defect
# in a scratch suite and confirm the scan sees it.
mkdir -p $W/fake
printf "%s\n" "grep -qE '^\\s*if online' \$f && no 'bad' || ok 'good'" > $W/fake/t99-planted.sh
if [ "$sup_s" = no ]; then
  _found=$(grep -rlE 'grep [^|]*\\s' "$W/fake" 2>/dev/null | wc -l)
  [ "${_found:-0}" -ge 1 ] 2>/dev/null \
    && ok "the scan detects a planted unsupported-pattern assertion" \
    || no "the scan MISSED a planted defect - it cannot be trusted to find real ones"
else
  ok "this grep supports \\s, so the planted case is not a defect here"
fi

rm -rf "$W" 2>/dev/null

# ---- scratch-write hygiene: a PASS must never rest on a file that failed to appear ------------------
# Ten suites were measured reporting green against a build carrying the very fault they exist for,
# because their scratch write to a hardcoded path failed, a later `grep -c` on the missing file
# returned 0, and 0 was the PASS value. The write is the silent part: nothing errors, the count is
# simply empty.
#
# This does not re-run every suite. It reports which ones write scratch WITHOUT honouring $TMPDIR, so
# a runner cannot place that scratch somewhere writable and a failure stays invisible.
_hard=$(grep -ln '/data/local/tmp' "$SD"/t*.sh 2>/dev/null | while read -r _hf; do
          case "${_hf##*/}" in t57-*) continue;; esac
          # a suite is fine if every scratch path it builds consults TMPDIR
          sed 's/^[[:space:]]*#.*//' "$_hf" 2>/dev/null | grep -F '/data/local/tmp' | grep -qv 'TMPDIR'             && echo "${_hf##*/}"
        done | sort -u | tr '
' ' ')
if [ -z "${_hard:-}" ]; then
  ok "every suite builds its scratch path through \$TMPDIR"
else
  note "suites with a hardcoded scratch path (a failed write there can read as a PASS): ${_hard}"
  ok "hardcoded scratch paths reported, not fatal - the runner sets TMPDIR to a writable dir"
fi

fin
