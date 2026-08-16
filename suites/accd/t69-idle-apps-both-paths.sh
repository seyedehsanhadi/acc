#!/system/bin/sh
# t69 - the app-idle probe must be reachable from BOTH loop paths, and free when unplugged.
#
# TWO DEFECTS, OPPOSITE IN SIGN, ONE CAUSE
#
#   idleApps pauses charging while a listed app is in the foreground. The probe was written inline
#   inside is_charging(), and that single placement caused both of the following.
#
#   IT COST PHONES THAT COULD NOT USE IT.
#     The probe is `dumpsys activity top`, measured at about 150ms and 235KB of output per call on a
#     Mi A3. It ran on every daemon pass whether or not a charger was attached, and pause_now cannot
#     do anything without one. Measured unplugged, screen off, 90s windows, idleApps set:
#         ungated   65, 65 CPU ticks
#         gated     51, 56
#     about 21% of the daemon's whole idle cost, spent on an answer it could never act on. An empty
#     idleApps was always free, because the [ -n ] test short-circuits before the fork - so the cost
#     fell entirely on the users who had turned the feature ON.
#
#   IT DID NOTHING ON PHONES WITH A FIRMWARE LIMIT.
#     The main loop's $nativeLimit branch `continue`s before is_charging() is ever called, so on any
#     Pixel with google,charger the probe never ran at all. idleApps was accepted, written to
#     config, echoed back by acc -sp, and silently ignored. This is the same branch, the same shape
#     and the same cause as the allowIdleAbovePcap bug rc21 fixed.
#
#     It was found by measurement, not by reading: gating the probe changed a Pixel 6a by nothing
#     (52,55 -> 55,54) while the same change moved a Mi A3 by 21%. Code that never runs cannot cost
#     anything, and that flat result is what exposed it.
#
#   ORDER MATTERS ON THE NATIVE PATH. pause_now only lowers capacity[3]/[2]; it touches no switch.
#   sync_native_limit is what writes that level into the firmware, so the probe has to run BEFORE
#   it or the pause waits a whole pass before reaching the hardware.
#
# NO HARDWARE. Source-level plus an executed check of the function itself.

ID=t69
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "accd.sh not found"; fin; }

_src=$(sed 's/^[[:space:]]*#.*//' "$AD")

# ---- 1: the probe exists once, as a function -------------------------------------------------------
_def=$(printf '%s' "$_src" | grep -c '^ *idle_apps_check() *{') || _def=0
case "${_def:-0}" in ''|*[!0-9]*) _def=0;; esac
[ "${_def:-0}" -eq 1 ] 2>/dev/null \
  && ok "the probe is defined exactly once, as idle_apps_check()" \
  || no "idle_apps_check() is defined ${_def} times - it must exist once and be called from both paths"

# ---- 2: no inline dumpsys survives anywhere ----------------------------------------------------------
# A second copy is how the two paths drift apart.
_inline=$(printf '%s' "$_src" | grep -c 'dumpsys activity top') || _inline=0
case "${_inline:-0}" in ''|*[!0-9]*) _inline=0;; esac
[ "${_inline:-0}" -eq 1 ] 2>/dev/null \
  && ok "only one dumpsys call site remains (inside the function)" \
  || no "${_inline} dumpsys activity top call sites - a second copy will drift from the first"

# ---- 3: called from the switch path, gated on charging ------------------------------------------------
printf '%s' "$_src" | grep -qE '\$isCharging && idle_apps_check' \
  && ok "the switch path calls it, gated on \$isCharging" \
  || no "the switch path does not gate the probe on charging - an unplugged phone pays for a dumpsys it cannot act on"

# ---- 4: called from the firmware-limit path, gated on present ------------------------------------------
printf '%s' "$_src" | grep -qE 'present [0-9]*>?[^ ]* *&& idle_apps_check|present && idle_apps_check' \
  && ok "the firmware-limit path calls it too, gated on present()" \
  || no "the \$nativeLimit branch never calls the probe - idleApps does nothing on any Pixel (the shipped bug)"

# ---- 5: on the native path it must run BEFORE the firmware write ----------------------------------------
_probe=$(printf '%s' "$_src" | grep -n 'present.*&& idle_apps_check' | head -1 | cut -d: -f1)
_sync=$(printf '%s' "$_src" | grep -n 'sync_native_limit' | head -1 | cut -d: -f1)
if [ -n "${_probe:-}" ] && [ -n "${_sync:-}" ]; then
  [ "$_probe" -lt "$_sync" ] 2>/dev/null \
    && ok "the probe runs before sync_native_limit, so a pause reaches the firmware the same pass" \
    || no "the probe runs AFTER sync_native_limit - the lowered level would not be written until the next pass"
else
  no "could not locate both the probe call and sync_native_limit on the native path"
fi

# ---- 6: an empty idleApps returns before the fork ---------------------------------------------------------
# The reason the default costs nothing. If this guard ever moves below the dumpsys, every user pays.
_fn=$(sed -n '/^ *idle_apps_check() *{/,/^ *}/p' "$AD")
_guard=$(printf '%s' "$_fn" | grep -n 'idleApps\[0\]' | head -1 | cut -d: -f1)
_dump=$(printf '%s' "$_fn" | grep -n 'dumpsys' | head -1 | cut -d: -f1)
if [ -n "${_guard:-}" ] && [ -n "${_dump:-}" ]; then
  [ "$_guard" -lt "$_dump" ] 2>/dev/null \
    && ok "an empty idleApps returns before the dumpsys, so the default costs nothing" \
    || no "the empty-idleApps guard sits after the dumpsys - every user would pay for an unused feature"
else
  no "could not find the empty guard and the dumpsys inside idle_apps_check()"
fi

# ---- 7: EXECUTE it - empty must be free and must not call dumpsys -------------------------------------------
_out=$( ( eval "$(sed -n '/^ *idle_apps_check() *{/,/^ *}/p' "$AD")"
          idleApps=""
          dumpsys(){ echo CALLED-DUMPSYS; }
          pause_now(){ echo CALLED-PAUSE; }
          idle_apps_check; echo "rc=$?" ) 2>/dev/null )
case "$_out" in
  *CALLED-DUMPSYS*) no "with idleApps empty the function still ran dumpsys" ;;
  *rc=0*)           ok "with idleApps empty the function returns without forking anything" ;;
  *)                no "unexpected result from the empty case: $_out" ;;
esac

# ---- 8: EXECUTE it - a matching foreground app must pause ----------------------------------------------------
_out=$( ( eval "$(sed -n '/^ *idle_apps_check() *{/,/^ *}/p' "$AD")"
          idleApps="com.example.game"
          dumpsys(){ echo "    ACTIVITY com.example.game/.MainActivity 1234 pid=5678"; }
          pause_now(){ echo CALLED-PAUSE; }
          idle_apps_check ) 2>/dev/null )
case "$_out" in
  *CALLED-PAUSE*) ok "a listed app in the foreground triggers pause_now" ;;
  *)              no "a listed foreground app did NOT trigger pause_now: [$_out]" ;;
esac

# ---- 9: EXECUTE it - a non-matching app must NOT pause ---------------------------------------------------------
_out=$( ( eval "$(sed -n '/^ *idle_apps_check() *{/,/^ *}/p' "$AD")"
          idleApps="com.example.game"
          dumpsys(){ echo "    ACTIVITY com.android.settings/.Settings 1234 pid=5678"; }
          pause_now(){ echo CALLED-PAUSE; }
          idle_apps_check ) 2>/dev/null )
case "$_out" in
  *CALLED-PAUSE*) no "an app NOT in idleApps triggered pause_now - charging would pause for anything" ;;
  *)              ok "an app not in the list leaves charging alone" ;;
esac

fin
