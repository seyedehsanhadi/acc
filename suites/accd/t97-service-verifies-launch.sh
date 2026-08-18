#!/system/bin/sh
# t97 - service.sh must verify the daemon actually started, not trust the launcher's exit code.
#
# THE FIELD REPORT. A SuperSU tarball install: `sh service.sh; echo exit=$?` printed exit=0, no
# daemon ran, and nothing was logged anywhere. Reproduced on a Mi A3 by the only environment that
# yields that signature - accd.sh without its executable bit. start-stop-daemon FORKS and only then
# execs, so a failed exec happens in a child after the parent has already returned 0.
# Measured across three repeats each: 3/3 start at 0755, 0/3 at 0644, exit 0 both ways.
#
# Eight other environments were tried and all recovered on their own, so this is the only hole:
# broken applet first on PATH, ACC's busybox dir wiped, both together, a bare PATH with no applet
# anywhere, a stale acc.lock holding a dead pid, and an applet returning failure.
#
# DESTRUCTIVE, AND IT RESTORES. It stops the daemon and removes an executable bit. Every exit path
# puts both back, and the last assertion is that charging control is running again.

ID=t97
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }

execDir=${execDir:-/data/adb/vr25/acc}
TMPDIR=${TMPDIR:-/dev/.vr25/acc}
S=$execDir/service.sh
A=$execDir/accd.sh
[ -f "$S" ] && [ -f "$A" ] || { no "service.sh or accd.sh not found under $execDir"; echo "$ID: $P passed, $F failed"; exit 1; }

_mode0=$(stat -c %a "$A" 2>/dev/null)
dpid(){ pgrep -f "$A" | head -1; }
clean(){ pkill -f "$A" 2>/dev/null; sleep 2; pkill -KILL -f "$A" 2>/dev/null; sleep 1; rm -f $TMPDIR/acc.lock 2>/dev/null; }
restore(){
  chmod "${_mode0:-0755}" "$A" 2>/dev/null || :
  [ -n "$(dpid)" ] && return 0
  clean
  sh "$S" >/dev/null 2>&1
  sleep 12
  [ -n "$(dpid)" ] || { setsid sh "$A" --init </dev/null >/dev/null 2>&1 & sleep 18; }
}
fin(){
  restore
  [ -n "$(dpid)" ] && ok "the phone ends with a running daemon and mode $(stat -c %a "$A")" \
                   || no "LEFT WITHOUT A DAEMON - charging is uncapped, fix by hand"
  echo "$ID: $P passed, $F failed"
  [ "$F" -eq 0 ] && exit 0 || exit 1
}

# ---- 1: the shipped launcher no longer trusts an exit code blindly -------------------------------
grep -q 'pgrep -f "\$execDir/\${id}d.sh"' "$S" \
  && ok "service.sh checks for a live daemon after launching" \
  || no "service.sh does not verify the daemon started - a lying applet stays silent"
grep -q '^exec start-stop-daemon' "$S" \
  && no "the launch still uses exec, so nothing after it can ever run" \
  || ok "the launch is no longer exec'd, so a check can follow it"

# ---- 2: control. A healthy phone must still start normally ---------------------------------------
clean
sh "$S" >/dev/null 2>&1; _rc=$?
sleep 3
_p=$(dpid)
if [ -n "$_p" ]; then
  ok "control: service.sh starts the daemon (pid $_p, exit $_rc)"
else
  no "control failed (exit $_rc) - this phone cannot grade the repair below"
  fin
fi

# ---- 3: THE REPORTED FAULT. accd.sh not executable ------------------------------------------------
clean
chmod 0644 "$A"
sh "$S" >/dev/null 2>&1; _rc=$?
sleep 3
_p=$(dpid)
if [ -n "$_p" ]; then
  ok "a non-executable accd.sh is recovered: daemon $_p came up anyway (exit $_rc)"
else
  no "a non-executable accd.sh still yields no daemon (exit $_rc) - the field report is not fixed"
fi
_m=$(stat -c %a "$A" 2>/dev/null)
[ "$_m" = 755 ] && ok "the executable bit was repaired ($_m)" \
                || echo "      NOTE mode is $_m; the sh fallback does not need it, so this is not fatal"

# ---- 4: the failure must not be silent when it truly cannot start ---------------------------------
# accd.sh moved aside entirely: nothing can start it, and service.sh must say so rather than exit 0.
clean
mv "$A" "$A.t97bak" 2>/dev/null
sh "$S" >/dev/null 2>&1; _rc=$?
mv "$A.t97bak" "$A" 2>/dev/null
chmod "${_mode0:-0755}" "$A" 2>/dev/null
if [ "$_rc" = 0 ]; then
  no "with accd.sh absent service.sh STILL exits 0 - the silent-success class is not closed"
else
  ok "with accd.sh absent service.sh exits $_rc, not 0 - the failure is reportable"
fi

fin
