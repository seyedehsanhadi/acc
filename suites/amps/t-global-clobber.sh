#!/system/bin/sh
# AMPS: leaf helpers must not clobber their caller's variables.
#
# In sh, a variable assigned inside a function is GLOBAL unless declared local. AMPS had 23 helpers
# assigning bare one- and two-letter scratch names, and they are called from inside loops that use
# the same names. Two consequences were confirmed by reading the call sites:
#
#   THE SCAN DIES AT THE "PLUG THE CHARGER IN" PROMPT. That wait loop counts in `i`:
#       i=0; while [ "$i" -lt 120 ]; do if plugged; then ...; fi; sleep 2; i=$(( i+2 )); done
#   plugged -> present_now, whose own loop is `for i in $PSY/*/present`. So on any phone that is NOT
#   already plugged in, `i` comes back holding /sys/class/power_supply/usb/present and the next line
#   asks the shell to add 2 to a filesystem path. That is a fatal arithmetic error, at the first
#   thing the script ever asks the user to do.
#
#   THE FCC-ZERO LAYER TESTS ONE SUPPLY AND SILENTLY STOPS. Its loop is `for d in $PSY/*`, and
#   present_now also assigns `d`. After the first test_switch, `$d` is a .../present path, so
#   "$d/$nm" names nothing and every remaining supply is skipped with no message.
#
# A third was found the same way: test_level saves the level node's original value in `o`, and
# online_now's loop variable is also `o` - so the "restore" wrote a sysfs path into a charge-limit
# node.
#
# NO HARDWARE. The helpers are executed with the caller's variables pre-set.

ID=t-global-clobber
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

# acc-compat.sh is NOT installed at that path - the module keeps it under acc-data/backup and the
# repo ships it in suites/. A single hardcoded default made three of these abort with
# "acc-compat.sh not found" on every installed phone, which reads as a product failure and is not.
# t-layer-crash already had a two-step fallback; give every suite the same search.
_amps_find(){
  for _ac in "${AMPS:-}" /data/adb/vr25/acc/acc-compat.sh              /data/adb/vr25/acc-data/backup/acc-compat.sh              /data/local/tmp/suites/acc-compat.sh /data/local/tmp/amps.sh; do
    [ -n "$_ac" ] && [ -f "$_ac" ] && { echo "$_ac"; return 0; }
  done
  return 1
}
AMPS=$(_amps_find)
[ -f "$AMPS" ] || { no "amps not found (set AMPS=)"; fin; }

PSY=/sys/class/power_supply

lift(){ sed -n "/^$1()/,/^}/p" "$AMPS"; }
lift1(){ grep -m1 "^$1()" "$AMPS"; }

# ---- 1: present_now must not touch i, d, pv or seen -------------------------------------------------
_r=$( ( PSY=$PSY
        eval "$(lift present_now)"
        ex(){ [ -e "$1" ]; }
        rd(){ cat "$1" 2>/dev/null; }
        i=41; d=DEE; pv=PEE; seen=SEEN
        present_now >/dev/null 2>&1
        printf 'i=%s d=%s pv=%s seen=%s' "$i" "$d" "$pv" "$seen" ) 2>/dev/null )
[ "$_r" = "i=41 d=DEE pv=PEE seen=SEEN" ] \
  && ok "present_now leaves i, d, pv and seen alone" \
  || no "present_now clobbered its caller: [$_r]"

# ---- 2: THE REAL FAILURE - the charger-wait loop must survive an unplugged phone ---------------------
# Reproduces the actual loop from the plug prompt. If present_now leaks `i`, the arithmetic aborts.
_r=$( ( PSY=$PSY
        eval "$(lift present_now)"
        ex(){ [ -e "$1" ]; }
        rd(){ echo 0; }                       # nothing reports present -> the unplugged case
        online_now(){ return 1; }             # present_now's fallbacks, stubbed to "nothing plugged"
        read_st(){ echo Discharging; }
        plugged(){ present_now; }
        i=0
        while [ "$i" -lt 6 ]; do
          plugged && break
          i=$(( i+2 ))
        done
        echo "survived i=$i" ) 2>/dev/null )
case "$_r" in
  "survived i=6") ok "the charger-wait loop counts to its limit on an unplugged phone" ;;
  *)              no "the wait loop died or miscounted: [$_r] - this is the scan aborting at the plug prompt" ;;
esac

# ---- 3: online_now must not touch o (test_level keeps the level node's ORIGINAL value there) ----------
_r=$( ( PSY=$PSY
        eval "$(lift online_f)"; eval "$(lift online_now)"
        ex(){ [ -e "$1" ]; }
        rd(){ echo 0; }
        o=80; any=ANY; ov=OV
        online_now >/dev/null 2>&1
        printf 'o=%s any=%s ov=%s' "$o" "$any" "$ov" ) 2>/dev/null )
[ "$_r" = "o=80 any=ANY ov=OV" ] \
  && ok "online_now leaves o alone, so test_level's saved original survives" \
  || no "online_now clobbered its caller: [$_r] - a sysfs path would be written into a charge-limit node"

# ---- 4: the fcc-zero outer loop variable survives a nested helper call --------------------------------
_r=$( ( PSY=$PSY
        eval "$(lift present_now)"
        ex(){ [ -e "$1" ]; }
        rd(){ echo 0; }
        _n=0
        for d in one two three; do
          present_now >/dev/null 2>&1
          [ "$d" = one ] || [ "$d" = two ] || [ "$d" = three ] || { echo "LOST at $d"; break; }
          _n=$((_n+1))
        done
        echo "visited $_n" ) 2>&1 )
[ "$_r" = "visited 3" ] \
  && ok "a supply loop still visits every supply after calling a helper" \
  || no "the loop variable was destroyed: [$_r] - later supplies are silently never tested"

# ---- 5: san() must not eat a caller's v ---------------------------------------------------------------
_r=$( ( eval "$(lift1 san)"
        v=KEEP; san -0042 >/dev/null 2>&1; printf 'v=%s' "$v" ) 2>/dev/null )
[ "$_r" = "v=KEEP" ] && ok "san leaves v alone" || no "san clobbered v: [$_r]"

# ---- 6: is_charging / is_idle keep their own scratch ---------------------------------------------------
_r=$( ( THR=50000; IDLE=10000; CHGDIR=p
        abs(){ printf '%s' "${1#-}"; }
        sgn(){ case "$1" in -*) echo n;; *) echo p;; esac; }
        eval "$(lift1 is_idle)"
        m=EMM
        is_idle 5 >/dev/null 2>&1
        printf 'm=%s' "$m" ) 2>/dev/null )
[ "$_r" = "m=EMM" ] && ok "is_idle keeps its own scratch" || no "is_idle clobbered m: [$_r]"

_r=$( ( THR=50000; CHGDIR=p
        sgn(){ case "$1" in -*) echo n;; *) echo p;; esac; }
        eval "$(sed -n '/^is_charging()/,/echo 0; }/p' "$AMPS")"
        c=CEE; m=EMM
        is_charging 900000 >/dev/null 2>&1
        printf 'c=%s m=%s' "$c" "$m" ) 2>/dev/null )
[ "$_r" = "c=CEE m=EMM" ] && ok "is_charging keeps c and m to itself" || no "is_charging clobbered: [$_r]"

# ---- 7: no leaf helper is left leaking (source-level sweep) ---------------------------------------------
# Every helper in the list must declare every short scratch name it assigns.
_leak=
for _fn in san state_dump batt_temp vmv inp_online online_f online_now present_now chgin_node \
           med_cur is_charging is_idle gate st_notchg classify_held resume_check expand_paths \
           pick1 pick_usable label_path compute_reco; do
  sed -n "/^$_fn()/,/^}/p" "$AMPS" | grep -q 'local ' || _leak="$_leak $_fn"
done
[ -z "$_leak" ] && ok "every leaf helper declares its scratch local" \
                || no "no local declaration in:$_leak"

fin
