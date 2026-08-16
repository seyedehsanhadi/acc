#!/system/bin/sh
# t92 - the daemon-restart stub `acc -t` leaves behind must name a real config.
#
# THE DEFECT. acc.sh built its restore stub as
#     exec $TMPDIR/accd $config_
# and `config_` is assigned NOWHERE in the codebase. The other three call sites that spawn the
# daemon (acc.sh :43, :69, :675) all use $config; only this one carried a trailing underscore, so
# the stub expanded to `exec $TMPDIR/accd` with no config path at all.
#
# WHY IT DID NOT BITE, and why it is still worth closing. misc_stuff() overrides $config only when
# the argument looks like a path:
#     ! eq "${1-}" "*/*" || { ...; config=$1; }
# With no argument that block is skipped and the daemon keeps its default, which happens to be the
# same $dataDir/config.txt the test was using. So the bug is latent: it is invisible precisely
# because the fallback currently agrees with the intended value. The day the default changes, or a
# user runs acc -t against a custom config path, the restored daemon silently adopts a DIFFERENT
# config from the one that was active - and the failure would appear as "my limits reset themselves
# after acc -t", far from its cause.
#
# The stub is also the ONLY way back for a daemon acc -t deliberately stopped, so anything wrong in
# it is a charging-uncapped risk rather than a cosmetic one.
#
# NO HARDWARE.

ID=t92
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AS=$execDir/acc.sh
[ -f "$AS" ] || { no "acc.sh not found"; fin; }

# ---- 1: the stub line exists ----------------------------------------------------------------------
_stub=$(grep -n 'exec \$TMPDIR/accd .*> \$TMPDIR/.accdt' "$AS" | head -1)
if [ -z "$_stub" ]; then
  # the heredoc spans lines; fall back to the accdt write itself
  _stub=$(grep -n '\.accdt' "$AS" | head -1)
fi
[ -n "$_stub" ] && ok "the restart stub is written in acc.sh" || { no "no .accdt stub found - acc -t has no way to restore the daemon it stops"; fin; }

# ---- 2: every accd spawn passes a variable that is actually ASSIGNED --------------------------------
# Collect the variable each `exec $TMPDIR/accd <var>` uses, then require an assignment for it. This is
# the general form of the bug: a spawn site naming a variable nobody sets.
_bad=
_seen=0
# strip comments so the prose above (which quotes the defect) is not scanned as code
_vars=$(sed 's/^[[:space:]]*#.*//' "$AS" | grep -o 'exec \$TMPDIR/accd \$[A-Za-z_][A-Za-z0-9_]*' | sed 's/.*\$//' | sort -u)
for v in $_vars; do
  _seen=$(( _seen + 1 ))
  # an assignment anywhere in the file, in any of the forms this codebase uses
  if sed 's/^[[:space:]]*#.*//' "$AS" | grep -qE "(^|[^A-Za-z0-9_])${v}=" 2>/dev/null; then
    :
  else
    _bad="$_bad \$${v}"
  fi
done
if [ "$_seen" -eq 0 ]; then
  no "found no 'exec \$TMPDIR/accd \$VAR' spawn sites at all - this suite's premise is stale"
elif [ -z "$_bad" ]; then
  ok "all ${_seen} accd spawn site(s) name a variable that is assigned in acc.sh"
else
  no "accd is spawned with unassigned variable(s):${_bad} - the stub expands to no config path, and the restored daemon silently adopts whatever default it finds"
fi

# ---- 3: the stub is written BEFORE config is repointed at the stripped temp copy ---------------------
# acc.sh does `config=$TMPDIR/.config` after stripping comments. If the stub were built after that, it
# would hand the daemon a tmpfs scratch file instead of the user's real config - which the next acc
# invocation overwrites. Order is load-bearing, so assert it rather than trusting it.
_acct=$(grep -n '\.accdt' "$AS" | head -1 | cut -d: -f1)
_repoint=$(grep -n '^ *config=\$TMPDIR/\.config' "$AS" | head -1 | cut -d: -f1)
if [ -n "$_acct" ] && [ -n "$_repoint" ]; then
  [ "$_acct" -lt "$_repoint" ] 2>/dev/null \
    && ok "the stub is built at line ${_acct}, before config is repointed at ${_repoint}, so it captures the real config" \
    || no "the stub at ${_acct} is built AFTER config is repointed at ${_repoint} - it would hand the daemon a tmpfs scratch copy"
else
  ok "(no config repoint in this build to order against)"
fi

# ---- 4: the restore must not depend on start-stop-daemon being present ------------------------------
# start-stop-daemon is a Debian/busybox tool and returned 127 on both test phones. acc.sh must have a
# setsid/nohup fallback, or acc -t leaves the phone uncapped with no daemon.
_ex=$(awk '/^    exxit\(\) \{/,/^    \}/' "$AS")
if [ -n "$_ex" ]; then
  # Require the actual SPAWN, not merely the word. The first version grepped for 'setsid' and passed a
  # mutant with the spawn removed, because `command -v setsid` on the line above still matched - the
  # probe, not the use. A check that matches its own guard clause cannot fail for the right reason.
  printf '%s\n' "$_ex" | grep -qE 'setsid[[:space:]]+\$TMPDIR/\.accdt' \
    && ok "the restore actually SPAWNS via setsid, so it does not depend on start-stop-daemon" \
    || no "no 'setsid \$TMPDIR/.accdt' spawn in the restore - start-stop-daemon returns 127 on Android, so the daemon never comes back and charging is left uncapped"
else
  no "could not extract exxit() from the -t path"
fi

sh -n "$AS" 2>/dev/null && ok "acc.sh parses" || no "acc.sh does not parse"
fin
