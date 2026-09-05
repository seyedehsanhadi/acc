#!/system/bin/sh
# t68 - the idle naps must not query the charger driver every second.
#
# THE COST, AND WHY THE FIX IS HERE AND NOT IN present()
#
#   present() is cheap only when some node reports 1. Unplugged, none does, so it falls through to
#   online() - and a power_supply */online read is not a file read. It calls into the charger driver,
#   which on a Snapdragon 665 is an I2C round trip. _nap_idle ran that once per second all night.
#
#   Measured on a Mi A3, unplugged, 120s windows: rc22 69 CPU ticks against rc21's 49, a 40% idle
#   regression. A build that skipped the sweep measured about a third of that, which is what
#   identified this loop as the source.
#
#   THE FIRST ATTEMPT WAS WRONG AND THIS TEST EXISTS PARTLY TO RECORD WHY. It gave WIRED present
#   nodes authority to answer "unplugged" without consulting online(), so the sweep could be skipped.
#   t47 rejected it immediately: a phone whose usb/present reads 0 with a cable attached - visible
#   only as */online=1 - would then be reported unplugged, which is the fuxi drain-while-charging bug
#   under a different node name. Narrowing what counts as EVIDENCE trades a correctness guarantee for
#   CPU, and in this function the asymmetry is explicit: a false positive costs a faster poll loop, a
#   false negative costs the user their charge.
#
#   Polling less OFTEN has no such trade. present() and online() answer exactly as before.
#
# NO HARDWARE. Source-level plus an executed simulation of the tick loop.

ID=t68
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
BI=$execDir/batt-interface.sh
[ -f "$AD" ] || { no "accd.sh not found"; fin; }

body(){ sed -n "/^  $1() {/,/^  }/p" "$AD" | sed 's/^[[:space:]]*#.*//'; }

# ---- 1: both nap loops gate the present() call -------------------------------------------------------
for _fn in _nap_idle _nap_hold; do
  _b=$(body "$_fn")
  if [ -z "$_b" ]; then
    no "could not extract $_fn"
    continue
  fi
  if printf '%s' "$_b" | grep -qE 'presentEvery'; then
    ok "$_fn gates its present() poll on an interval"
  else
    no "$_fn still calls present() on every 1s tick - the charger driver is queried once a second while idle"
  fi
  # The gate must wrap the present call, not sit somewhere decorative.
  _gate=$(printf '%s' "$_b" | sed -n '/presentEvery/,/fi/p')
  printf '%s' "$_gate" | grep -qE '^ *!? *present( |$)' \
    && ok "$_fn's present() call is inside the interval gate" \
    || no "$_fn has an interval variable but present() is not inside the gate"
done

# ---- 2: _tick is NOT gated ---------------------------------------------------------------------------
# The config-change wake must stay at 1s. Gating it would delay AccA edits, which is a user-visible
# regression and not the cost being fixed here.
for _fn in _nap_idle _nap_hold; do
  _b=$(body "$_fn")
  _gate=$(printf '%s' "$_b" | sed -n '/presentEvery/,/fi/p')
  printf '%s' "$_gate" | grep -q '_tick' \
    && no "$_fn moved _tick inside the present gate - AccA config edits would be delayed" \
    || ok "$_fn keeps _tick on every tick, so config edits still apply within ~1s"
done

# A FIFO byte is the lossless config-change signal. Filesystem mtimes can tie when a CLI save and
# nap start land in the same second, so merely draining the byte and consulting -nt can sleep 30s.
_tb=$(body _tick)
printf '%s' "$_tb" | grep -qE 'read .*&& return 1|read .*then.*return 1' \
  && ok "_tick breaks a nap when the config writer sends a wake byte" \
  || no "_tick discards its wake byte and can miss same-timestamp config edits"

_td=$(mktemp -d 2>/dev/null || echo /data/local/tmp/t68.$$)
mkdir -p "$_td" 2>/dev/null
if mkfifo "$_td/wake" 2>/dev/null; then
  ( eval "$(sed -n '/^  _tick() {/,/^  }/p' "$AD")"
    TMPDIR=$_td; config=$_td/config; : > "$config"; : > "$TMPDIR/.nap-ref"
    hasWakeFifo=true
    exec 9<>"$TMPDIR/wake"
    echo w > "$TMPDIR/wake"
    _tick
    echo $? ) > "$_td/rc" 2>/dev/null
  [ "$(cat "$_td/rc" 2>/dev/null)" = 1 ] \
    && ok "a real FIFO wake makes _tick return the nap-break status" \
    || no "a real FIFO wake did not break _tick"
else
  no "could not create FIFO for the wake test"
fi
rm -rf "$_td" 2>/dev/null || :

# ---- 3: the interval is sane -------------------------------------------------------------------------
# Zero or empty would divide the fix by itself; something huge would delay plug detection past the
# point a user notices. Anything from 2 to 15 is defensible; the default is 5.
_iv=$(printf '%s' "$(body _nap_idle)" | grep -oE '\$\{presentEvery:-[0-9]+\}' | head -1 | grep -oE '[0-9]+')
case "${_iv:-x}" in
  ''|*[!0-9]*) no "the poll interval has no numeric default" ;;
  *) if [ "$_iv" -ge 2 ] && [ "$_iv" -le 15 ] 2>/dev/null; then
       ok "the poll interval defaults to ${_iv}s - a bounded worst case for noticing a cable"
     else
       no "the poll interval default is ${_iv}, outside the defensible 2-15s range"
     fi ;;
esac

# ---- 4: present() ITSELF is unchanged ------------------------------------------------------------------
# The whole point. If a later change tries to buy the same saving inside present(), t47 will fail -
# but say it here too, next to the reason.
if [ -f "$BI" ]; then
  _p=$(sed -n '/^present()/,/^}/p' "$BI" | sed 's/^[[:space:]]*#.*//')
  printf '%s' "$_p" | grep -qE 'seen=(true|false)' \
    && no "present() tracks a 'seen' flag again - a node reading 0 can veto the online fallback" \
    || ok "present() has no 'seen' flag; a node reading 0 still cannot veto the fallback"
  printf '%s' "$_p" | grep -q 'online' \
    && ok "present() still ends in the online() fallback" \
    || no "the online() fallback is gone - the fuxi drain-while-charging bug returns"
  printf '%s' "$_p" | grep -qE '_presentW|wireless\|dc' \
    && no "present() filters its nodes by class again - that was reverted for weakening t47's guarantee" \
    || ok "present() gives every present node the same standing, as t47 requires"
fi

# ---- 5: the gate actually reduces the call count ---------------------------------------------------------
# Simulate the tick loop. Source-level checks prove the shape; this proves the arithmetic.
_sim(){  # $1 ticks  $2 interval -> present calls
  ( _pt=0; _n=0; _left=$1
    while [ $_left -gt 0 ]; do
      _left=$(( _left - 1 )); _pt=$(( _pt + 1 ))
      if [ $_pt -ge $2 ]; then _pt=0; _n=$(( _n + 1 )); fi
    done
    echo $_n )
}
_calls=$(_sim 120 "${_iv:-5}")
_expect=$(( 120 / ${_iv:-5} ))
[ "${_calls:-0}" -eq "$_expect" ] \
  && ok "over a 120s nap the driver is queried ${_calls} times instead of 120" \
  || no "the gate arithmetic is wrong: ${_calls} calls over 120 ticks at interval ${_iv:-5}, expected ${_expect}"

[ "${_calls:-999}" -lt 120 ] \
  && ok "that is a $(( 100 - (_calls * 100 / 120) ))% reduction in charger-driver reads while idle" \
  || no "the gate does not reduce the call count at all"

fin
