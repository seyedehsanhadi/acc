#!/system/bin/sh
# t96 - acca's argument forms. AccA drives ACC entirely through acca, so a form that aborts is a
# front-end failure, not a cosmetic one.
#
# THE DEFECT. The case glob is `-sp*`, so `-spcapacity` MATCHES, but the branch then tests for
# exactly `-sp`:
#     [ $1 = -sp ] && shift || shift 2
# A glued filter is not equal to -sp, so it takes `shift 2` holding a single argument, and under
# `set -eu` that aborts:  acca.sh[160]: shift: nothing to shift
# Same shape in the -sd twin. Measured on a Mi A3: glued exits 1, spaced exits 0.
#
# Runs the SHIPPED acca.sh. Printing config cannot change charging, so this is safe on any phone.
# NO HARDWARE STATE NEEDED.

ID=t96
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
A=$execDir/acca.sh
[ -f "$A" ] || { no "acca.sh not found at $A"; fin; }

rc(){ sh "$A" $@ >/dev/null 2>&1; echo $?; }
out(){ sh "$A" $@ 2>&1; }

# control first: if the plain form is broken, nothing below means anything
_base=$(rc -sp)
_lines=$(out -sp | grep -c '=')
if [ "$_base" = 0 ] && [ "${_lines:-0}" -gt 5 ]; then
  ok "control: 'acca -sp' exits 0 and prints $_lines keys"
else
  no "control failed (exit=$_base lines=$_lines) - this phone cannot grade the rest"
  fin
fi

# every documented form must exit 0
for f in "-sp" "-s p" "--set --print" "-sd" "-s d" "--set --print-default"; do
  _r=$(rc $f)
  [ "$_r" = 0 ] && ok "'acca $f' exits 0" || no "'acca $f' exits $_r"
done

# spaced filters
for f in "-sp capacity" "-sd capacity" "-sp capacity,temp"; do
  _r=$(rc $f)
  [ "$_r" = 0 ] && ok "'acca $f' exits 0" || no "'acca $f' exits $_r"
done

# THE DEFECT: glued filters. The glob accepts them, so they must work or not be accepted at all.
for f in -spcapacity -sdcapacity; do
  _r=$(rc $f)
  if [ "$_r" = 0 ]; then
    ok "'acca $f' (glued filter) exits 0"
  else
    no "'acca $f' exits $_r - the glob matches it but the shift branch aborts: $(out $f | head -1)"
  fi
done

# a glued filter that works must actually FILTER, not just avoid crashing
_g=$(out -spcapacity 2>/dev/null | grep -c '=')
_s=$(out -sp capacity 2>/dev/null | grep -c '=')
if [ "$(rc -spcapacity)" = 0 ]; then
  [ "$_g" = "$_s" ] && [ "${_g:-0}" -gt 0 ] \
    && ok "glued and spaced filters return the same $_g lines" \
    || no "glued returned $_g lines, spaced returned $_s - they disagree"
fi

# a filter matching nothing must still exit 0: AccA refreshes config with these and must not
# treat "no match" as a failure
_r=$(rc -sp zzzznosuchkey)
[ "$_r" = 0 ] && ok "a filter matching nothing still exits 0" \
              || no "no-match filter exits $_r - AccA's refresh would report failure"

# comma really becomes an alternation
_c=$(out -sp capacity | grep -c '=')
_t=$(out -sp temp | grep -c '=')
_ct=$(out -sp capacity,temp | grep -c '=')
[ "${_ct:-0}" -gt "${_c:-0}" ] && [ "${_ct:-0}" -gt "${_t:-0}" ] \
  && ok "comma filter widens the match ($_c + $_t -> $_ct)" \
  || no "comma filter did not widen: capacity=$_c temp=$_t combined=$_ct"

fin
