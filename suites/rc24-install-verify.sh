#!/system/bin/sh
# rc24-install-verify.sh - prove a FRESH INSTALL actually works, not a hot-patched tree.
#
#   su -c 'sh /data/local/tmp/suites/rc24-install-verify.sh'
#
# WHY THIS EXISTS
#   Every other suite in this repo grades files that were copied over an already-installed module.
#   That skips the entire install path: the zip's permission bits, customize.sh, install.sh,
#   post-fs-data.sh, service.sh, first-boot config creation and boot auto-start. A build can pass
#   all 90 unit suites and still fail to install, or install and never start at boot - which is an
#   open rc22 issue, so it is exactly the thing that needs a real check rather than an assumption.
#
# RUN IT AFTER A REBOOT, on a phone where the zip was flashed and nothing was hand-copied.

ID=rc24-install
P=0; F=0; S=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
sk(){ S=$((S+1)); echo "  SKIP  $*"; }
info(){ echo "  ....  $*"; }
fin(){ echo "$ID: $P passed, $F failed, $S skipped"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

MD=/data/adb/modules/acc
ED=/data/adb/vr25/acc
DD=/data/adb/vr25/acc-data
A=/dev/.vr25/acc

echo "===== 1  THE MODULE IS INSTALLED ====="
[ -d "$MD" ] && ok "module dir present ($MD)" || { no "module dir missing - the flash did not land"; fin; }
[ -f "$MD/module.prop" ] && ok "module.prop present" || no "module.prop missing"
info "$(grep -E '^version(Code)?=' $MD/module.prop 2>/dev/null | tr '\n' ' ')"

# KernelSU refuses a module whose scripts carry no mode bits, and Magisk hides the fault by
# installing anyway - so check the bits on disk rather than trusting that the flash reported OK.
_ne=0
for f in $ED/accd.sh $ED/acc.sh $ED/acca.sh $MD/service.sh $MD/post-fs-data.sh; do
  [ -f "$f" ] || continue
  [ -x "$f" ] || { _ne=$((_ne+1)); info "not executable: $f"; }
done
[ "$_ne" = 0 ] && ok "every installed script carries its executable bit" \
                || no "$_ne installed script(s) lost their mode bits - a KernelSU install would vanish on reboot"

echo
echo "===== 2  FIRST-BOOT INITIALISATION ====="
[ -d "$DD" ] && ok "data dir created ($DD)" || no "data dir missing - install-time init did not run"
[ -f "$DD/config.txt" ] && ok "config.txt created" || no "config.txt missing after install"
_cap=$(grep '^capacity=' $DD/config.txt 2>/dev/null)
case "$_cap" in
  capacity=\(*\)) ok "config parses: $_cap" ;;
  *) no "config.txt has no usable capacity= line (got: ${_cap:-nothing})" ;;
esac

echo
echo "===== 3  THE DAEMON STARTED ON ITS OWN ====="
# The point of the check: nobody ran accd by hand after this boot. A daemon that only ever runs
# because a human started it is not a working install.
_n=0; _pid=
for p in $(pgrep -f accd 2>/dev/null); do
  c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
  set -f; set -- $c; set +f
  case "${1:-}" in sh|*/sh|mksh|*/mksh|busybox|*/busybox) ;; *) continue;; esac
  [ "${1##*/}" = busybox ] && shift
  case "${2:-}" in */accd.sh|accd.sh) _n=$((_n+1)); _pid=$p;; esac
done
[ "$_n" = 1 ] && ok "exactly one daemon running (pid $_pid)" \
              || no "$_n daemons running - expected exactly 1"

_up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
if [ -n "$_pid" ] && [ -n "$_up" ]; then
  _age=$(( _up - $(awk '{print int($22/100)}' /proc/$_pid/stat 2>/dev/null || echo 0) ))
  info "uptime ${_up}s, daemon age ~${_age}s"
  [ "$_up" -lt 900 ] 2>/dev/null \
    && ok "this is a fresh boot (${_up}s) so the daemon start was automatic, not hand-run" \
    || sk "uptime ${_up}s - cannot prove the start was automatic; reboot and re-run for that claim"
fi

# alive is not looping. flight.log is the only honest heartbeat.
_F=$DD/logs/flight.log
if [ -f "$_F" ]; then
  h0=$(wc -l < "$_F" 2>/dev/null); i=0
  while [ $i -lt 12 ]; do sleep 10; i=$((i+1)); h1=$(wc -l < "$_F" 2>/dev/null); [ "$h1" != "$h0" ] && break; done
  [ "${h1:-$h0}" != "$h0" ] && ok "flight recorder advancing (after $((i*10))s) - the daemon is LOOPING" \
                            || no "flight.log frozen for 120s - the daemon is alive but not looping"
else
  no "no flight.log - the daemon never completed a pass"
fi

echo
echo "===== 4  THE FRONT-ENDS WORK ====="
[ -x "$A/acc" ] && ok "runtime link $A/acc present" || no "runtime link missing - post-fs-data did not run"
# head -1 gets a BLANK line: acc -v prints an empty line before the version, so the naive read
# reported "produced nothing" against a front-end that answers correctly. Take the first
# non-empty line instead of the first line.
_v=$("$A/acc" -v 2>/dev/null | grep -m1 .)
[ -n "$_v" ] && ok "acc -v answers: $_v" || no "acc -v produced nothing"
"$A/acc" -s 2>/dev/null | grep -q . && ok "acc -s prints the config" || no "acc -s printed nothing"
"$A/acca" --state 2>/dev/null | grep -q '"battery"' \
  && ok "acca --state exports a battery object (AccA's contract)" \
  || no "acca --state does not export a battery object - the app would show nothing"

echo
echo "===== 5  THE FIX FROM THIS CYCLE SHIPPED ====="
grep -q '_pgLast' $ED/accd.sh 2>/dev/null \
  && ok "the missed-unplug guard is in the INSTALLED accd.sh" \
  || no "the installed accd.sh predates the missed-unplug fix - the zip is stale"

fin
