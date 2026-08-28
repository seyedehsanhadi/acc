#!/system/bin/sh
# The suites that never ran this session and need no charger.
P=/data/local/tmp/suites
L=/data/local/tmp/EXTRA.log
exec > $L 2>&1
echo "started $(date '+%H:%M:%S')  level=$(cat /sys/class/power_supply/battery/capacity)% present=$(cat /sys/class/power_supply/usb/present)"
for s in rc24-coverage.sh preflight.sh harness.sh snapshot.sh; do
  [ -f "$P/$s" ] || { echo "== $s  (not staged)"; continue; }
  echo
  echo "== $s"
  # One output file PER SUITE. Sharing one meant each suite erased the previous one's evidence,
  # so a result that needed a second look was already gone.
  _o=/data/local/tmp/.extra.$s.out
  execDir=/data/adb/vr25/acc timeout 1500 sh "$P/$s" > "$_o" 2>&1
  rc=$?
  [ $rc = 124 ] && echo "  !! TIMED OUT after 1500s"
  grep -E '^  (FAIL|SKIP)' "$_o" | head -10
  v=$(grep -E '[a-zA-Z0-9_-]+: [0-9]+ passed' "$_o" | tail -1)
  # NOT EVERY SUITE ENDS IN "N passed". preflight logs to its own report and drops a marker with
  # four stage verdicts; reporting "(no summary)" for it hid a real inv=FAIL until it was chased
  # by hand. Fall back to the markers and to a raw PASS/FAIL count before giving up.
  if [ -z "$v" ]; then
    if [ -f /dev/.vr25/acc/.preflight-done ] && [ "$s" = preflight.sh ]; then
      v="preflight: $(cat /dev/.vr25/acc/.preflight-done)"
      case "$(cat /dev/.vr25/acc/.preflight-done)" in *FAIL*) v="$v  <<< FAILED";; esac
    else
      # NOT `grep -c ... || echo 0`: grep -c PRINTS its count and ALSO exits non-zero when the
      # count is zero, so that shape emits TWO values and any arithmetic on it breaks. t57 exists
      # to catch exactly this and caught it here. Take the count, then coerce a non-number.
      _p=$(grep -cE '^  (PASS|ok  )' "$_o" 2>/dev/null); case ${_p:-x} in ''|*[!0-9]*) _p=0;; esac
      _f=$(grep -cE '^  FAIL' "$_o" 2>/dev/null); case ${_f:-x} in ''|*[!0-9]*) _f=0;; esac
      [ "${_p:-0}" -gt 0 ] 2>/dev/null && v="counted: ${_p} passed, ${_f} failed (no summary line)"
    fi
  fi
  echo "  => ${v:-(no summary, rc=$rc)}"
done
echo
echo "EXTRA DONE $(date '+%H:%M:%S')"
