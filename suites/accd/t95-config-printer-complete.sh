#!/system/bin/sh
# t95 - every setting a user can change must be readable back.
#
# THE REPORT. A user found uiRefresh (ur) in config.txt, settable with `acc -s ur=45`, honoured by
# the daemon, and absent from `acca -sp` / `acc -s p`. It had been added to default-config.txt and to
# write-config.sh, and never to print-config.sh, which is a hardcoded list rather than a dump of the
# config. Nothing catches that at build time, so the next key added lands the same way.
#
# THIS SUITE IS STRUCTURAL ON PURPOSE. It does not check a list of known keys - it derives the list
# from default-config.txt every run, so a key added tomorrow is covered without editing this file.
#
# The only permitted omission is configVerCode, which default-config.txt documents as internal
# ("This is checked during updates ... Do NOT modify"). Anything else missing is a defect.
#
# NO HARDWARE.

ID=t95
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
DC=$execDir/default-config.txt
PC=$execDir/print-config.sh
[ -f "$DC" ] || { no "default-config.txt not found at $DC"; fin; }
[ -f "$PC" ] || { no "print-config.sh not found at $PC"; fin; }

# keys the printer is allowed not to expose
INTERNAL="configVerCode"

# every assignable key at the top of default-config.txt
_keys=$(grep -E '^[a-zA-Z][a-zA-Z0-9_]*=' "$DC" | sed 's/=.*//' | sort -u)
_n=$(printf '%s\n' "$_keys" | grep -c .)
if [ "${_n:-0}" -lt 10 ]; then
  no "only ${_n:-0} keys parsed out of default-config.txt - the extraction is wrong, no verdict"
  fin
fi
ok "parsed $_n assignable keys from default-config.txt"

# the printer must reference each one. Arrays are expanded into several printed names
# (capacity -> shutdown_capacity, pause_capacity, ...), so the check is that the VARIABLE is
# referenced, not that a particular label exists.
# Extract the variables the printer actually references, rather than probing one regex per key.
# The first version built a pattern per key and one of them was an unbalanced character class, so
# toybox grep errored on every call and reported all 26 keys missing - a broken check reading as a
# catastrophic finding. Deriving the printed set once has no such failure mode.
_printed=$(grep -oE '\$\{?[a-zA-Z][a-zA-Z0-9_]*' "$PC" | tr -d '${' | sort -u)
_np=$(printf '%s\n' "$_printed" | grep -c .)
if [ "${_np:-0}" -lt 10 ]; then
  no "only ${_np:-0} variable references found in print-config.sh - extraction is wrong, no verdict"
  fin
fi
ok "print-config.sh references $_np variables"

_missing=
for k in $_keys; do
  case " $INTERNAL " in *" $k "*) continue;; esac
  printf '%s\n' "$_printed" | grep -qx "$k" || _missing="$_missing $k"
done

if [ -z "$_missing" ]; then
  ok "every user-settable key is referenced by print-config.sh"
else
  no "settable but NOT printable:$_missing - each can be written and honoured, and cannot be read back"
fi

# the specific report, pinned so it cannot regress quietly
grep -q 'uiRefresh' "$PC" \
  && ok "ui_refresh is exposed (the reported key)" \
  || no "ui_refresh is still missing - the reported bug"

# and the deliberate omission stays omitted, so nobody "fixes" it by exposing an internal
grep -q 'configVerCode' "$PC" \
  && no "configVerCode is exposed - default-config.txt marks it internal, Do NOT modify" \
  || ok "configVerCode stays internal, as documented"

# guard: the printer must still be a single well-formed echo, not silently truncated
_open=$(grep -c '^echo "' "$PC")
[ "${_open:-0}" -ge 1 ] && ok "print-config.sh still emits its block" \
                        || no "print-config.sh has no echo block - extraction or file is wrong"

fin
