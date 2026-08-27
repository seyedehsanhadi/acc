#!/system/bin/sh
# t127 - `acc -f` must give the daemon a way back to the real config.
#
# WHAT WENT WRONG
#   `acc -f N` copies config.txt to a throwaway, rewrites it with pause=N, and execs the daemon
#   onto that file. Nothing ever loaded the real config again. Without -a the override survived the
#   charge it was made for, so `acc -f 100` parked a phone at 100% until someone restarted the
#   daemon by hand. AccA's "charge once to N%" sends `acca -f N` with no -a, which made this the
#   normal path, not an edge case. Reproduced on a Mi A3: the live daemon was
#     accd.sh /dev/.vr25/acc/.acc-f-config      capacity=(5 101 88 90 false)
#   while config.txt still read 75.
#
#   -a is not the fix and never was: it restores on UNPLUG, so a phone left plugged after reaching
#   the target keeps the override even with -a. The fix is a second ':' hook that watches the one
#   event that always happens, reaching the target.
#
# WHY THE GUARD MATTERS AS MUCH AS THE HOOK
#   ':' lines are shell, and the daemon is not the only thing that sources a config -- acca does
#   too, during `acc -f 90 -s mcc=500`. A hook that fired there would exec a daemon out of a
#   front-end. The guard is that _ge_pause_cap exists ONLY in accd.sh, the same reason acca.sh
#   stubs at() and online() to no-ops. If that function is ever moved to a shared file, the guard
#   silently stops guarding, so this suite asserts where it is defined, not just that it is called.
#
# NO HARDWARE for the source assertions; the behavioural block stubs both gauges.

ID=t127
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AC=$execDir/acc.sh
AD=$execDir/accd.sh
AA=$execDir/acca.sh
for _f in "$AC" "$AD"; do [ -f "$_f" ] || { no "missing $_f"; fin; }; done

# Comments quote the hook and the option it replaces, so every source assertion below reads the
# code with comments stripped. A test that matches its own explanation proves nothing.
_ac=$(sed 's/^[[:space:]]*#.*//' "$AC")

# ---- 1: the hook is there, and is NOT conditional on -a -----------------------------------------
_hook=$(printf '%s' "$_ac" | grep -F '_ge_pause_cap && _reexec')
if [ -n "$_hook" ]; then
  ok "the -f branch appends a restore hook"
else
  no "no restore hook in acc -f - the daemon is stranded on the throwaway config again"
  fin
fi

case "$_hook" in
  *'$auto'*) no "the restore hook is gated on -a - AccA sends no -a, so it would never fire";;
  *) ok "the restore hook is unconditional, so AccA's bare 'acca -f N' gets it too";;
esac

# ---- 2: it can never abort the source it runs inside --------------------------------------------
# The config is sourced under set -eu. A hook whose last command returns non-zero takes the daemon
# down with it, which is a far worse failure than the one being fixed.
case "$_hook" in
  *'|| :'*) ok "the hook ends in '|| :' - a false test cannot abort the config source";;
  *) no "the hook has no '|| :' terminator - a false test returns non-zero under set -eu";;
esac

# ---- 3: the guard function is daemon-only -------------------------------------------------------
_defd=$(grep -cE '^[[:space:]]*_ge_pause_cap\(\)' "$AD")
[ "${_defd:-0}" -ge 1 ] \
  && ok "_ge_pause_cap is defined in accd.sh" \
  || no "_ge_pause_cap is not defined in accd.sh - the hook can never fire"

_leak=0
for _f in "$AC" "$AA" "$execDir/misc-functions.sh" "$execDir/batt-interface.sh" "$execDir/cfg-guard.sh"; do
  [ -f "$_f" ] || continue
  grep -qE '^[[:space:]]*_ge_pause_cap\(\)' "$_f" && { _leak=1; no "_ge_pause_cap is also defined in $_f - the front-end guard is gone"; }
done
[ "$_leak" -eq 0 ] && ok "no front-end defines _ge_pause_cap, so the hook stays inert outside the daemon"

# ---- 4: the throwaway config is what gets the hook, not the real one -----------------------------
printf '%s' "$_ac" | grep -qF 'config=$TMPDIR/.acc-f-config' \
  && ok "the -f branch still redirects to the throwaway before writing" \
  || no "the -f branch no longer uses .acc-f-config - re-check where the hook lands"

# ---- 5: BEHAVIOUR - the composed condition -------------------------------------------------------
# The real _ge_pause_cap, the real hook text, stubbed gauges. `exec` is swapped for a recorder so
# the assertion can observe the decision instead of being replaced by a daemon.
xf() {
  awk -v fn="$1" '
    !f { if ($0 ~ "^[ \t]*" fn "\\(\\)[ \t]*\\{") { f=1; ind=""; s=$0
           while (substr(s,1,1)==" " || substr(s,1,1)=="\t") { ind=ind substr(s,1,1); s=substr(s,2) }
           closer=ind "}"; print } next }
    { print; if ($0==closer) exit }' "$2"
}
_fn=$(xf _ge_pause_cap "$AD")
[ -n "$_fn" ] || { no "could not extract _ge_pause_cap"; fin; }
eval "$_fn"

CAP=50; MV=3800
batt_cap(){ echo $CAP; }
volt_now(){ echo $MV; }

# The hook, run verbatim. No rewriting of the action any more: the hook calls _reexec, so the test
# simply DEFINES _reexec as a recorder. That is strictly more faithful than the old sed, which had to
# substitute the action string and would have clobbered the `command -v _reexec` guard along with it
# (both occurrences sit on one line). It also means block 6 below tests the real guard rather than a
# stand-in: unset _reexec and the hook must decline exactly as a front-end would make it decline.
_body=$(printf '%s' "$_hook" | sed "s|.*print '||; s|' >> .*||")
_body=${_body#*; }
case "$_body" in
  *_reexec*) ;;
  *) no "the extracted hook does not call _reexec - every assertion below would be meaningless"; fin;;
esac
_reexec(){ _fired=1; }
try(){ capacity[3]=$1; CAP=$2; _fired=0; eval "$_body" ; echo $_fired; }

[ "$(try 90 21)" = 0 ] && ok "target 90, level 21 -> does not fire (the charge is still running)" \
                       || no "target 90, level 21 -> fired early, the -f session is cut short"
[ "$(try 90 90)" = 1 ] && ok "target 90, level 90 -> fires at the target" \
                       || no "target 90, level 90 -> did NOT fire, the override outlives the charge"
[ "$(try 90 97)" = 1 ] && ok "target 90, level 97 -> fires above the target too" \
                       || no "target 90, level 97 -> did NOT fire above the target"
[ "$(try 100 100)" = 1 ] && ok "target 100, level 100 -> fires (the AccA button's own case)" \
                         || no "target 100, level 100 -> did NOT fire: this is the reported bug"

# ---- 6: inert without the daemon-only function ---------------------------------------------------
# What a front-end sees: _reexec undefined. The hook must decline AND return 0, or it would abort the
# config source it runs inside, under set -eu.
(
  unset -f _reexec 2>/dev/null || :
  _fired=0
  eval "$_body"
  _rc=$?
  [ "$_fired" -eq 0 ] && [ "$_rc" -eq 0 ]
) && ok "with _reexec undefined the hook does nothing and still returns 0" \
  || no "the hook misbehaves in a front-end context - it fires there, or returns non-zero"

# The other daemon-only name in the chain must still gate it too.
(
  unset -f _ge_pause_cap 2>/dev/null || :
  _fired=0
  eval "$_body"
  _rc=$?
  [ "$_fired" -eq 0 ] && [ "$_rc" -eq 0 ]
) && ok "with _ge_pause_cap undefined the hook also declines and returns 0" \
  || no "the hook fires or errors when _ge_pause_cap is missing (accd --init defines it late)"


# ---- 7: the -f argument loop --------------------------------------------------------------------
# A second, unrelated defect found while testing the hook: rc21 made every non-numeric argument to
# -f fatal, to stop `acc -f 8O` falling back to 100 and force-charging a phone to full. That also
# refused the pass-through options the help documents on the next line, so `acc -f 95 -s mcc=500`
# printed "Invalid argument for -f: -s" and the acca call further down had been unreachable code.
# Both properties are asserted together because fixing either one alone re-breaks the other.
_loop=$(printf '%s' "$_ac" | sed -n '/-f|--force|--full/,/case ${cap:-100}/p')

printf '%s' "$_loop" | grep -qE '^[[:space:]]*-\*\)[[:space:]]*break'   && ok "an option argument ends the loop, so pass-through options reach acca"   || no "nothing breaks the loop on an option - acc -f 95 -s mcc=500 is refused again"

printf '%s' "$_loop" | grep -qF '*[!0-9]*)'   && ok "a non-numeric capacity is still fatal (the rc21 typo guard survives)"   || no "the rc21 typo guard is gone - acc -f 8O would force-charge to 100%"

printf '%s' "$_loop" | grep -qE '^[[:space:]]*-a\)'   && ok "-a is still consumed by the loop rather than passed to acca"   || no "-a is no longer handled - it would be forwarded to acca as an unknown option"

printf '%s' "$_ac" | grep -qF '"$TMPDIR/acca" "$config" "$@"'   && ok "the pass-through call is still there for the options the loop now leaves behind"   || no "the acca pass-through call is gone - additional opts/args are silently dropped"

grep -qF 'additional opts/args' $execDir/strings.sh 2>/dev/null   && ok "the help still documents the pass-through the loop now accepts"   || no "the help no longer documents additional opts/args - code and help disagree again"

# ---- 7b: the daemon must never exec the service symlink directly ---------------------------------
# $TMPDIR/accd is a symlink to service.sh, which sources release-lock.sh. exec keeps the PID and the
# open fds, so a bare `exec $TMPDIR/accd` from inside the daemon hands release-lock a lock that is
# still held, by a PID that is still ours, and it SIGTERMs the process it is meant to be restarting.
# Whether that lands is a race against acquire-lock writing the PID, which is why it survived
# testing: sometimes it just costs two 10s flock timeouts instead of the daemon. _reexec drops the
# lock first. Front-ends are exempt, they hold no lock, so killing the daemon from there is correct.
# _reexec's own body is the ONE legitimate hand-off, so subtract it rather than counting it as a
# violation -- which is exactly what the first version of this assertion did.
_totalexec=$(sed 's/^[[:space:]]*#.*//' "$AD" | grep -cF 'exec $TMPDIR/accd')
_inreexec=$(xf _reexec "$AD" | sed 's/^[[:space:]]*#.*//' | grep -cF 'exec $TMPDIR/accd')
_selfexec=$(( ${_totalexec:-0} - ${_inreexec:-0} ))
if [ "${_selfexec:-0}" -eq 0 ]; then
  ok "accd.sh never execs the service symlink directly - every hand-off goes through _reexec"
else
  no "accd.sh still has $_selfexec bare exec(s) of the service symlink - it can SIGTERM itself"
fi

grep -qE '^[[:space:]]*_reexec\(\)' "$AD" \
  && ok "_reexec is defined in accd.sh" \
  || no "_reexec is not defined in accd.sh - both hooks guard on a function that does not exist"

_rleak=0
for _f in "$AC" "$AA" "$execDir/misc-functions.sh"; do
  [ -f "$_f" ] || continue
  grep -qE '^[[:space:]]*_reexec\(\)' "$_f" && { _rleak=1; no "_reexec is also defined in $_f - the front-end guard is gone"; }
done
[ "$_rleak" -eq 0 ] && ok "no front-end defines _reexec, so both config hooks stay inert outside the daemon"

# _reexec must actually release the lock, not merely exist.
_rbody=$(xf _reexec "$AD")
printf '%s' "$_rbody" | grep -qE 'flock -u 4|4>&-' \
  && ok "_reexec releases the lock fd before handing off" \
  || no "_reexec does not drop fd 4 - release-lock will still find the lock held and kill us"


# ---- 8: a throwaway config must never become the known-good fallback ----------------------------
# _srccfg caches whatever config it just parsed into $dataDir/.config-good, and $config is not
# always the user's file: -f points the daemon at $TMPDIR/.acc-f-config. That copy parsed, so the
# fallback became the one-shot profile. Device-proven on a Mi A3 before the guard: one charge-once
# to 100 left .config-good holding capacity=(5 101 98 100 false) AND the -f restore hook, so a
# config that later failed to parse would fall back to "charge to 100, no cooldown, no caps", and
# the fallback itself carried an exec.
_scblock=$(sed 's/^[[:space:]]*#.*//' "$AD" | grep -B8 -F 'cat $config > $dataDir/.config-good')

printf '%s' "$_scblock" | grep -qF '"$TMPDIR"/*'   && ok "the known-good cache refuses a config living in tmpfs"   || no "no tmpfs guard on .config-good - a -f session poisons the fallback with its own profile"

# The guard has to sit BEFORE the copy, not merely somewhere in the file.
_gline=$(sed 's/^[[:space:]]*#.*//' "$AD" | grep -nF '"$TMPDIR"/*' | head -1 | cut -d: -f1)
_cline=$(sed 's/^[[:space:]]*#.*//' "$AD" | grep -nF 'cat $config > $dataDir/.config-good' | head -1 | cut -d: -f1)
if [ -n "$_gline" ] && [ -n "$_cline" ] && [ "$_gline" -lt "$_cline" ]; then
  ok "the guard is above the copy, so the copy cannot run first"
else
  no "the tmpfs guard is not above the .config-good copy (guard=${_gline:-none} copy=${_cline:-none})"
fi

# The path -f actually uses must be under $TMPDIR, or the guard matches nothing.
printf '%s' "$_ac" | grep -qF 'config=$TMPDIR/.acc-f-config'   && ok "-f's throwaway is under \$TMPDIR, which is what the guard keys on"   || no "-f's throwaway is no longer under \$TMPDIR - the tmpfs guard no longer covers it"

fin
