#!/system/bin/sh
# t63 - the flight recorder's contract fields must actually be produced.
#
# THE DEFECT THIS ENCODES
#   rc22 added vbus, ICL and the negotiated supply type to the flight recorder so a collapsed
#   fast-charge contract would be answerable from the log alone. The change shipped as THREE HALVES
#   THAT NEVER MET:
#
#     1. init resolved $_psVolt / $_psIcl / $_psType once, with a comment explaining that the
#        recorder reads them every loop. Nothing ever read them.
#     2. the printf still wrote 8 fields, while the comment directly above it said the three new
#        ones had been added.
#     3. the collapse detector branched on `case "${_ft:-}"` and compared "${_fv:-0}" - and no line
#        anywhere in install/ assigned _ft or _fv. So the case always fell through to `*) _lowV=0`
#        and the detector could not fire on any device, ever.
#
#   Every existing check passed. suites/ab.sh graded the block FLIP against rc21 - rc21 has no such
#   block, so "differs from absent" scored a pass. The mega2 coverage audit counts a changed function
#   as covered when any suite NAMES it. Nothing asserted the code could run.
#
#   That is the shape of defect this file exists to catch: a feature whose producer is missing, which
#   is invisible to every test that greps for a name rather than for a value reaching a consumer.
#
# NO HARDWARE for parts 1-3. Part 4 runs only where a flight.log exists.

ID=t63
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "accd.sh not found"; fin; }

_fr=$(sed -n '/flight_rec()/,/^  }/p' "$AD")
[ -n "$_fr" ] || { no "could not extract flight_rec"; fin; }
_code=$(printf '%s' "$_fr" | sed 's/#.*//')

# ---- 1: every variable the recorder consumes has a producer ------------------------------------------
# The general rule, not the three names. Any variable the detector reads must be assigned somewhere in
# the same function, or the branch that reads it is dead.
for _v in _ft _fv; do
  if printf '%s' "$_code" | grep -q "^ *${_v}=" || printf '%s' "$_code" | grep -q "; *${_v}="; then
    ok "${_v} is assigned inside flight_rec, so the branch that reads it can be taken"
  else
    no "${_v} is READ but never assigned - the collapse detector is dead code on every device"
  fi
done

# ---- 2: the producers read the nodes init resolved --------------------------------------------------
# Assigning them from anywhere is not enough: they have to come from the paths the init scan went to
# the trouble of resolving, otherwise that scan is still dead and the values are someone else's.
for _pair in "_fv:_psVolt" "_fi:_psIcl" "_ft:_psType"; do
  _var=${_pair%%:*}; _src=${_pair#*:}
  printf '%s' "$_code" | grep -q "read $_var < \"\$$_src\"" \
    && ok "$_var is read from \$$_src, the path init resolved" \
    || no "$_var does not come from \$$_src - the init supply scan is still dead"
done

# ---- 3: the reads cost no fork ----------------------------------------------------------------------
# rc19 removed the per-loop stat calls because they cost 26% of a core at idle. This runs at loop rate
# on a sleeping phone, so $(cat) here would re-introduce exactly that regression.
_reads=$(printf '%s' "$_code" | grep -c 'read _f[vit] <') || _reads=0
case "${_reads:-0}" in ''|*[!0-9]*) _reads=0;; esac
[ "${_reads:-0}" -eq 3 ] 2>/dev/null \
  && ok "all three contract fields use the read builtin - no fork at loop rate" \
  || no "only ${_reads} of 3 contract reads use the read builtin"

printf '%s' "$_code" | grep -qE '\$\(cat "\$_ps(Volt|Icl|Type)"' \
  && no "a contract field is read with \$(cat) - a fork per loop, the rc19 regression" \
  || ok "no \$(cat) on the resolved supply paths"

# ---- 4: the printf writes as many fields as it has arguments -----------------------------------------
# The mismatch that hid the whole thing: the format string kept its 8 placeholders while the comment
# above claimed 11 fields. Count both and compare, so neither can drift again.
_fmt=$(printf '%s' "$_code" | grep -o "'%s\(,%s\)*\\\\n'" | head -1)
if [ -n "$_fmt" ]; then
  _ph=$(printf '%s' "$_fmt" | tr ',' '\n' | grep -c '%s') || _ph=0
  case "${_ph:-0}" in ''|*[!0-9]*) _ph=0;; esac
  [ "${_ph:-0}" -eq 11 ] 2>/dev/null \
    && ok "the flight record writes 11 fields, including vbus, ICL and supply type" \
    || no "the flight record writes ${_ph} fields - the three contract fields are not in the format string"
else
  no "could not find the flight_rec format string"
fi

# Scope this to the printf STATEMENT, not the whole function.
#
# Grepping the function body for '"${_fv:-}"' passes on the broken build: the detector's own guard
# `[ -n "${_fv:-}" ]` and its `case "${_ft:-}" in` contain that exact text. Run against the shipped
# rc22 this reported two fields as "passed to the record" while the printf had neither - the same
# mention-is-not-coverage trap this whole file exists to close, reproduced inside the test for it.
_pf=$(printf '%s' "$_code" | sed -n '/{ printf /,/flight\.log/p')
if [ -n "$_pf" ]; then
  for _f in '"${_fv:-}"' '"${_fi:-}"' '"${_ft:-}"'; do
    printf '%s' "$_pf" | grep -qF "$_f" \
      && ok "$_f is an argument to the record printf" \
      || no "$_f is not an argument to the record printf - the field would never be written"
  done
else
  no "could not isolate the record printf statement"
fi

# ---- 5: on a device with a flight log, the lines really carry the fields ------------------------------
# Source structure is not proof the values arrive. Where a log exists, read it.
FL=${dataDir:-/data/adb/vr25/acc-data}/logs/flight.log
if [ -s "$FL" ]; then
  _last=$(tail -1 "$FL")
  _n=$(printf '%s' "$_last" | tr ',' '\n' | grep -c .) || _n=0
  case "${_n:-0}" in ''|*[!0-9]*) _n=0;; esac
  [ "${_n:-0}" -ge 9 ] 2>/dev/null \
    && ok "a live flight.log line carries ${_n} fields" \
    || no "a live flight.log line carries only ${_n} fields - the recorder is still writing the old format"
  # Field 9 is vbus. Unplugged it may legitimately be 0 or empty, so only its SHAPE is asserted:
  # whatever is there must be a number, because a path or an error string means the read went wrong.
  _v9=$(printf '%s' "$_last" | cut -d, -f9)
  case "${_v9:-}" in
    ''|*[!0-9]*) [ -z "${_v9:-}" ] && ok "vbus field present and empty (no supply node on this device)" \
                                  || no "vbus field is not numeric: ${_v9}" ;;
    *) ok "vbus field is numeric (${_v9}uV)" ;;
  esac
else
  echo "      note  no flight.log on this device yet; parts 1-4 still apply"
fi

fin
