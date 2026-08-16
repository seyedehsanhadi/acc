#!/system/bin/sh
# t78 - a firmware-limit phone must take the deep idle nap when it is unplugged.
#
# THE DEFECT
#
#   The main loop's $nativeLimit branch `continue`s in three places. The deep-nap block that lets
#   an unplugged phone drop into CPU deep sleep sits at the BOTTOM of the loop, so none of the
#   three ever reached it. Every Pixel with google,charger polled at the plugged-in 9s cadence all
#   night, with no cable attached and the firmware holding the limit - there is nothing for the
#   daemon to enforce in that state.
#
#   Measured on rc23, screen off, no cable, two 120s windows, the same build on both phones:
#       Mi A3     (switch path, reaches the deep nap)    11, 11 CPU ticks
#       Pixel 6a  (native path, never reached it)        84, 87 CPU ticks
#   Roughly eight times the idle cost for polling nothing.
#
#   FOUND BY INSTRUMENTATION, NOT BY READING. A first fix went into the exit the code reads as the
#   obvious one and changed the measurement by nothing: 87, 83 ticks. Tagging every nap call site
#   with its line number and running that copy as the daemon for 70s showed 8 of 8 naps leaving
#   through a different exit entirely - the one a DEFAULT config takes, since allowIdleAbovePcap
#   defaults true and short-circuits the test above it. Two of the three exits were still wrong.
#
#   Hence one shared _nap_native() rather than a copy at each exit: the bug is one path missing
#   what another does, and a copy is a second chance to drift.
#
# NO HARDWARE. Source-level placement checks plus the function executed against stubs.

ID=t78
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "accd.sh not found"; fin; }

_src=$(sed 's/^[[:space:]]*#.*//' "$AD")

# ---- 1: the helper exists, exactly once ------------------------------------------------------------
_def=$(printf '%s' "$_src" | grep -c '^ *_nap_native() *{') || _def=0
case "${_def:-0}" in ''|*[!0-9]*) _def=0;; esac
[ "${_def:-0}" -eq 1 ] 2>/dev/null \
  && ok "_nap_native() is defined exactly once" \
  || no "_nap_native() is defined ${_def} times - it must exist once and be shared by every native exit"

# ---- 2: NO short nap survives anywhere inside the firmware-limit branch ------------------------------
# This is the assertion that fails on the shipped rc23: it had `_nap ${loopDelay[1]:-9}` at each of
# the three exits, and the default config leaves through the first one on every single pass.
_start=$(printf '%s' "$_src" | grep -n '^ *if \$nativeLimit; then' | head -1 | cut -d: -f1)
if [ -z "${_start:-}" ]; then
  no "could not find the 'if \$nativeLimit; then' branch in the main loop"
else
  # the branch ends at the first `fi` indented to match its `if`
  _ind=$(printf '%s' "$_src" | sed -n "${_start}p" | sed 's/[^ ].*//')
  _rel=$(printf '%s' "$_src" | tail -n +$((_start + 1)) | grep -n "^${_ind}fi\$" | head -1 | cut -d: -f1)
  if [ -z "${_rel:-}" ]; then
    no "could not find the end of the \$nativeLimit branch"
  else
    _end=$((_start + _rel))
    _blk=$(printf '%s' "$_src" | sed -n "${_start},${_end}p")
    _short=$(printf '%s' "$_blk" | grep -c '_nap \${loopDelay') || _short=0
    case "${_short:-0}" in ''|*[!0-9]*) _short=0;; esac
    [ "${_short:-0}" -eq 0 ] 2>/dev/null \
      && ok "no short nap remains inside the firmware-limit branch (lines $_start-$_end)" \
      || no "${_short} short nap(s) still inside the firmware-limit branch - an unplugged Pixel polls at the plugged cadence (the shipped bug)"

    # ---- 3: EVERY exit out of that branch naps through the helper -----------------------------------
    _cont=$(printf '%s' "$_blk" | grep -c '^ *continue$') || _cont=0
    _via=$(printf '%s' "$_blk" | grep -c '^ *_nap_native$') || _via=0
    case "${_cont:-0}" in ''|*[!0-9]*) _cont=0;; esac
    case "${_via:-0}" in ''|*[!0-9]*) _via=0;; esac
    [ "${_cont:-0}" -gt 0 ] 2>/dev/null && [ "${_via:-0}" -eq "${_cont:-0}" ] 2>/dev/null \
      && ok "all ${_cont} exits out of the branch nap through _nap_native" \
      || no "${_cont} exits but only ${_via} call _nap_native - an exit that skips it keeps the old cost"
  fi
fi

# ---- 4: the guard has not drifted from the generic call site ------------------------------------------
# Same test, same words, in the helper and in the loop-bottom block the switch path uses. If one is
# ever edited without the other, the two paths diverge again - which is the whole bug.
_g='! present && { ! _le_shutdown_cap || \[ "\${capacity\[0\]:-0}" -lt 1 \] 2>/dev/null; }'
_n=$(printf '%s' "$_src" | grep -c "if $_g; then") || _n=0
case "${_n:-0}" in ''|*[!0-9]*) _n=0;; esac
[ "${_n:-0}" -ge 2 ] 2>/dev/null \
  && ok "the helper's guard is textually identical to the generic call site's" \
  || no "found ${_n} copies of the guard - the helper and the generic site have drifted apart"

# ---- 5..8: EXECUTE the helper against stubs ------------------------------------------------------------
# The daemon reads ${capacity[0]}; in mksh a scalar `capacity=5` answers that as 5, so the cases
# set a scalar and stub the two predicates by return code.
_case(){ # _case <label> <present-rc> <le-rc> <cap0> <idleDelay> <expect>
  _out=$( ( eval "$(sed -n '/^ *_nap_native() *{/,/^  }/p' "$AD")"
            eval "present(){ return $2; }"
            eval "_le_shutdown_cap(){ return $3; }"
            capacity=$4
            loopDelay=9
            idleDelay=$5
            _nap_idle(){ echo "DEEP:${1:-}"; }
            _nap(){ echo "SHORT:${1:-}"; }
            _nap_native ) 2>/dev/null )
  case "$_out" in
    $6*) ok "$1" ;;
    *)   no "$1 - expected $6, got [${_out:-empty}]" ;;
  esac
}

# unplugged (present false=1), nothing near shutdown (_le_shutdown_cap false=1) -> deep nap
_case "unplugged with no shutdown pending takes the deep nap" 1 1 5 120 DEEP

# plugged (present true=0) -> short nap, the plugged cadence is untouched
_case "a plugged phone keeps the short 9s cadence" 0 1 5 120 SHORT

# unplugged but AT/BELOW shutdown_capacity, and it is enabled -> short nap, shutdown not delayed
_case "unplugged at the shutdown level keeps the short nap so shutdown is not delayed" 1 0 5 120 SHORT

# unplugged, at the level, but shutdown_capacity DISABLED (capacity[0] < 1) -> deep nap
_case "shutdown_capacity disabled still takes the deep nap" 1 0 0 120 DEEP

# the configured idleDelay is what gets used, not a hardcoded constant
_out=$( ( eval "$(sed -n '/^ *_nap_native() *{/,/^  }/p' "$AD")"
          present(){ return 1; }
          _le_shutdown_cap(){ return 1; }
          capacity=5; loopDelay=9; idleDelay=300
          _nap_idle(){ echo "DEEP:${1:-}"; }
          _nap(){ echo "SHORT:${1:-}"; }
          _nap_native ) 2>/dev/null )
case "$_out" in
  DEEP:300*) ok "the deep nap honours the configured idleDelay" ;;
  *)         no "idleDelay=300 was not passed through: [${_out:-empty}]" ;;
esac

# ---- 9: the whole file still parses --------------------------------------------------------------------
sh -n "$AD" 2>/dev/null \
  && ok "accd.sh parses" \
  || no "accd.sh does not parse"

fin
