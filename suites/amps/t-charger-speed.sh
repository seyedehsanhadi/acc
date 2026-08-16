#!/system/bin/sh
# AMPS CHARGER / SPEED box, run against this phone's real nodes.
#
# THE DEFECT
#   The input ceiling was the FIRST non-zero current_max found, and usb came first in the list.
#   On a Pixel 6a that is usb/current_max = 500000, the SDP default, which never moves - while
#   main-charger/current_max carries the real 3200000 and main-charger was not in the list at all.
#   The box therefore printed
#       -> INPUT-CAPPED ~500mA = USB SDP (PC port / data tether / weak cable)
#   on a phone measured drawing 858 mA. Sending someone to buy a cable over a number their phone is
#   already exceeding is worse than printing nothing.
#
#   A guard for exactly this existed (_iinbad, added after a Mi A3 printed "Imax=500mA Iin=4378mA")
#   and was DEAD: the INPUT-CAPPED branch is tested first and matched on the ceiling alone.
#
# Runs the real block out of amps.sh, against live sysfs. Read the verdict line it prints.

ID=t-charger-speed
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

AMPS=${AMPS:-/data/local/tmp/amps.sh}
[ -f "$AMPS" ] || { no "amps not found (set AMPS=)"; fin; }

PSY=/sys/class/power_supply
BLOCK=$(sed -n '/^_csr()/,/^log "+===/p' "$AMPS" | sed '$d')
[ -n "$BLOCK" ] || { no "could not lift the CHARGER/SPEED block"; fin; }

OUT=$( ( PSY=$PSY
         log(){ printf '%s\n' "$*"; }
         eval "$BLOCK"
         printf 'VARS imax=%s iin=%s ib=%s iinbad=%s src=%s\n' "$_imax" "$_iin" "$_ib" "${_iinbad:-0}" "$_src" ) 2>&1 )
printf '%s\n' "$OUT" | sed 's/^/    /'

IMAX=$(printf '%s' "$OUT" | sed -n 's/.*VARS imax=\([0-9]*\).*/\1/p')
IB=$(printf '%s' "$OUT"   | sed -n 's/.*VARS imax=[0-9]* iin=[0-9-]* ib=\([0-9-]*\).*/\1/p')

# ---- 1: main-charger is consulted -----------------------------------------------------------------
# THIS ASSERTION NEEDS A CABLE. It lifts the real _csr() block and runs it against live sysfs, so it
# reads whatever the charger driver currently holds. The defect it guards is a stale SDP default
# (usb voting 500 mA) beating the charger's real vote WHILE CHARGING.
#
# Unplugged the comparison inverts and becomes meaningless: usb/current_max reads 0 because there is
# no supply -- which is the truthful value -- while main-charger can still hold a leftover 3000 mA
# from the last session, and that leftover is the stale one. Graded unplugged this reported
# "usb's stale SDP default won again" on a bluejay that was simply sitting on a table.
# NOT battery/present -- that reports whether the BATTERY is fitted, which is 1 on every phone with
# a battery in it, cable or no cable. Using it here marked an unplugged bluejay as plugged and the
# assertion below failed on a phone sitting on a table. Ask about the PORT.
_plugged=0
for _pf in "$PSY/usb/present" "$PSY/usb/online" "$PSY/main-charger/online" "$PSY/main/online" "$PSY/ac/online"; do
  [ -f "$_pf" ] || continue
  case "$(cat "$_pf" 2>/dev/null)" in 1) _plugged=1; break;; esac
done
case "$(cat "$PSY/battery/status" 2>/dev/null)" in Charging|Full) _plugged=1;; esac

if [ "$_plugged" = 0 ]; then
  ok "(no cable attached: the ceiling-vs-main-charger comparison is only meaningful while charging)"
elif [ -f "$PSY/main-charger/current_max" ]; then
  _mc=$(cat "$PSY/main-charger/current_max" 2>/dev/null)
  _mcm=$_mc; [ "${_mc:-0}" -gt 100000 ] 2>/dev/null && _mcm=$(( _mc / 1000 ))
  [ "${IMAX:-0}" -ge "${_mcm:-0}" ] 2>/dev/null \
    && ok "the ceiling ($IMAX mA) is at least main-charger's own vote ($_mcm mA)" \
    || no "ceiling read as $IMAX mA while main-charger votes $_mcm mA - usb's stale SDP default won again"
else
  ok "no main-charger on this phone (nothing to prefer over usb)"
fi

# ---- 2: the ceiling is never below what the pack is actually taking --------------------------------
case "${IB:-x}" in
  ''|*[!0-9]*) ok "battery current is not positive right now, so there is nothing to contradict" ;;
  *) _st=$(printf '%s' "$OUT" | sed -n 's/.*status=\([^ ]*\).*/\1/p' | head -1)
     case "$_st" in
       Charging|Full)
         if [ "${IB:-0}" -gt "$(( ${IMAX:-0} * 3 / 2 ))" ] 2>/dev/null; then
           printf '%s' "$OUT" | grep -q 'INPUT-CAPPED' \
             && no "the pack is taking ${IB}mA against a ${IMAX}mA ceiling and it STILL says INPUT-CAPPED" \
             || ok "the pack out-draws the ceiling and the box does NOT claim INPUT-CAPPED"
         else
           ok "ceiling ${IMAX}mA is consistent with the pack drawing ${IB}mA"
         fi ;;
       *)
         # THE DEFECT: _csn strips the sign, so a discharging pack reads as a huge positive draw.
         # Measured on a Pixel on a real slow PC USB 2 port: ib=3437 against a true 500mA ceiling,
         # which vetoed the correct "INPUT-CAPPED = USB SDP, use a wall charger" advice.
         if [ "${IB:-0}" -gt "$(( ${IMAX:-0} * 3 / 2 ))" ] 2>/dev/null && [ "${IMAX:-0}" -gt 0 ] 2>/dev/null && [ "${IMAX:-0}" -le 510 ] 2>/dev/null; then
           printf '%s' "$OUT" | grep -q 'INPUT-CAPPED' \
             && ok "a NOT-charging pack does not veto the SDP advice on a genuine ${IMAX}mA port" \
             || no "the SDP advice was suppressed by a battery magnitude (${IB}mA) on a pack that is '$_st', not charging"
         else
           ok "battery magnitude ${IB}mA does not contradict the ${IMAX}mA ceiling while '$_st'"
         fi ;;
     esac ;;
esac
# the battery line must not present a magnitude as if it had direction
_st=$(printf '%s' "$OUT" | sed -n 's/.*status=\([^ ]*\).*/\1/p' | head -1)
case "$_st" in
  Charging|Full) ok "pack is charging, so the battery current needs no direction caveat" ;;
  *) if [ "${IB:-0}" -gt 0 ] 2>/dev/null; then
       printf '%s' "$OUT" | grep -q 'magnitude only' \
         && ok "a non-charging pack's current is labelled as a magnitude, not a draw" \
         || no "battery reads I=${IB}mA with status '$_st' and no caveat - that is current leaving the pack"
     else
       ok "no battery current to mislabel" ; fi ;;
esac

# ---- 3: the SDP advice is gated on the sanity flag --------------------------------------------------
grep -q 'le 510 .*_iinbad' "$AMPS" \
  && ok "the INPUT-CAPPED branch is gated on the sanity flag (the guard is live, not dead)" \
  || no "INPUT-CAPPED still matches on the ceiling alone - _iinbad can never reach it"

# ---- 3b: no impossible ceiling ----------------------------------------------------------------------
# A Pixel 6a whose usb/current_max sat at exactly 100000 (100 mA, unconfigured USB) printed
# "Imax=100000mA" because the micro-unit test was -gt rather than -ge.
case "${IMAX:-0}" in
  ''|*[!0-9]*) no "the ceiling is not a number: [$IMAX]" ;;
  *) [ "${IMAX:-0}" -le 20000 ] 2>/dev/null \
       && ok "the ceiling (${IMAX}mA) is a number a phone charger can actually be" \
       || no "ceiling reported as ${IMAX}mA - no phone charger delivers that; a micro-unit value went unconverted" ;;
esac

# ---- 3c: a negotiated fast port is never called a PC port ---------------------------------------------
# Caught live on a Mi A3 on a QC3 charger: usb/real_type read USB_HVDCP_3, charge_type read Fast, and
# the box still printed "INPUT-CAPPED ~200mA = USB SDP (PC port / data tether / weak cable)" -- while
# ACC's own ledger, on the same phone at the same second, had it right: "contract collapsed:
# USB_HVDCP_3 advertised, vbus 4398mV". A phone on HVDCP3 is not on a PC port by definition.
PTYPE=$(printf '%s' "$OUT" | sed -n 's/.*negotiated=\([^ ]*\).*/\1/p' | head -1)
case "${PTYPE:-}" in
  *HVDCP*|*PD*|*QC*|*SCP*|*VOOC*|*WARP*|*DASH*|*DCP*|Mains|AC)
    printf '%s' "$OUT" | grep -q 'USB SDP' \
      && no "the port negotiated $PTYPE and the box still blames a PC port / weak cable" \
      || ok "a negotiated $PTYPE port is not called USB SDP" ;;
  *) ok "this port has not negotiated a fast contract (${PTYPE:-unknown}); the SDP wording is allowed" ;;
esac
grep -q '_fastport" = 1 \] && \[ "\$_imax" -gt 0' "$AMPS" \
  && ok "the collapsed-contract branch is tested before the SDP branch" \
  || no "the fast-port branch does not precede the SDP branch, so SDP still wins"

# ---- 3d: the kernel's enum node lists every type it SUPPORTS, active one in brackets ------------------
# A Pixel 6a reads "Unknown [SDP] CDP DCP" -- active SDP. Matching the raw string sees DCP and calls an
# ordinary PC port a wall charger, which then suppresses the SDP advice that WAS correct.
_enum() {
  ( _ptype="$1"
    case "$_ptype" in *'['*']'*) _pt2=${_ptype#*[}; _ptype=${_pt2%%]*} ;; esac
    case "$_ptype" in ''|Unknown|unknown|USB|usb|SDP|CDP|USB_SDP|USB_CDP|USB_FLOAT|Battery|BMS) _ptype=;; esac
    _f=0
    case "$_ptype" in *HVDCP*|*hvdcp*|*PD*|*pps*|*PPS*|*QC*|*SCP*|*VOOC*|*WARP*|*DASH*|*DCP*|Mains|AC|ac) _f=1;; esac
    printf '%s/%s' "${_ptype:-none}" "$_f" )
}
_r=$(_enum 'Unknown [SDP] CDP DCP')
[ "$_r" = none/0 ] && ok "an SDP-active enum node reads as SDP, not as the DCP it merely supports" \
                    || no "'Unknown [SDP] CDP DCP' resolved to [$_r] - an ordinary PC port read as a wall charger"
_r=$(_enum 'Unknown SDP CDP [DCP] PD')
[ "$_r" = "DCP/1" ] && ok "a DCP-active enum node is a fast port" || no "DCP-active resolved to [$_r]"
_r=$(_enum 'USB_HVDCP_3')
[ "$_r" = "USB_HVDCP_3/1" ] && ok "a plain single-value node (the Mi A3's QC3) still works" || no "USB_HVDCP_3 resolved to [$_r]"
_r=$(_enum 'Unknown [PD] PD_PPS')
[ "$_r" = "PD/1" ] && ok "an active PD contract is a fast port" || no "PD-active resolved to [$_r]"

# ---- 4: wireless votes do not inflate a wired ceiling -----------------------------------------------
grep -q 'dc|wireless) \[ "$_src" = "$_u" \] || continue' "$AMPS" \
  && ok "dc/wireless are only consulted when the charge is actually arriving that way" \
  || no "the wireless ceiling is counted on a wired charge"

fin
