#!/system/bin/sh
# t32 - the init current-restore must not overwrite a LIVE negotiated current.
#
# accd restores input-current nodes at init to undo a cap ACC itself left behind, but only when
# the user configured no current limit. It decided what to lift on "is this below the default I
# recorded", which is not the same question. During an HVDCP/QC ramp the charger driver holds
# those nodes at real intermediate values, legitimately below a default captured in an earlier
# session, and lifting them fights the negotiation.
#
# Field report, curtana (Redmi Note 9S), one pass of this block:
#   usb/current_max            2450000 -> 2600000
#   main/current_max           1600000 -> 3000000
#   main/input_current_settled 1850000 -> 2600000
#   pc_port/current_max        2150000 -> 2600000
# After it the phone sat on USB_DCP at 4.59V charging 1.5A, no fast charge. Upstream ACC has no
# such restore, which is why that build was unaffected - the giveaway that this was ours.
#
# The rule now: lift only a node ACC could plausibly have zeroed (<=100mA). A cut writes 0, or a
# token like 10000 on a current-cap switch. Anything above is the driver mid-negotiation.
#
# Pure unit test: the decision is reproduced against fake values. No node is written.

ID=t32
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/accd.sh
[ -f "$SRC" ] || { no "accd.sh not found"; fin; }

# ---- source level -----------------------------------------------------------------------------
grep -q '_ccn" -le 100000' "$SRC" \
  && ok "the restore is bounded to near-zero nodes" \
  || no "no near-zero bound - a live negotiated current can still be overwritten"

grep -q '_ccn" -lt "\$_ccd"' "$SRC" \
  && ok "the never-lower rule is still in place" \
  || no "the never-lower rule went missing"

grep -q 'maxChargingCurrent\[0\]-' "$SRC" \
  && ok "still gated on no user current limit being configured" \
  || no "the no-user-limit gate went missing"

# ---- behavioural ------------------------------------------------------------------------------
# $1 = live value on the node, $2 = ACC's recorded default -> 0 means "would lift"
lift() {
  _ccn=$1; _ccd=$2
  # the product guards both values as numeric before comparing; mirror that or this helper
  # diverges from what it claims to reproduce
  case "${_ccd:-x}" in ''|*[!0-9]*) return 1;; esac
  case "${_ccn:-x}" in ''|*[!0-9]*) return 1;; esac
  [ "$_ccn" -lt "$_ccd" ] 2>/dev/null || return 1
  [ "$_ccn" -le 100000 ] 2>/dev/null || return 1
  return 0
}

# The bug: live negotiated values must be left alone.
lift 2450000 2600000 && no "usb/current_max 2450000 still overwritten (the curtana bug)" \
                     || ok "live 2450000 vs default 2600000 -> left alone"
lift 1600000 3000000 && no "main/current_max 1600000 still overwritten" \
                     || ok "live 1600000 vs default 3000000 -> left alone"
lift 1850000 2600000 && no "input_current_settled 1850000 still overwritten" \
                     || ok "live 1850000 vs default 2600000 -> left alone"
lift 2150000 2600000 && no "pc_port 2150000 still overwritten" \
                     || ok "live 2150000 vs default 2600000 -> left alone"

# What the block exists for must still work: a node ACC zeroed gets lifted.
lift 0 2600000     && ok "a node ACC zeroed IS restored (the case this block exists for)" \
                   || no "a zeroed node is no longer restored - the original bug is back"
lift 10000 3000000 && ok "a current-cap token (10000) IS restored" \
                   || no "a 10000 cap is no longer restored"
lift 100000 2600000 && ok "exactly 100mA is restored (boundary inclusive)" \
                    || no "the 100mA boundary excludes a value it should lift"
lift 100001 2600000 && no "100001 was lifted - above the near-zero bound" \
                    || ok "just above 100mA is left alone"

# Never lower, at any value.
lift 2600000 2600000 && no "an equal value was written" || ok "equal value -> no write"
lift 3000000 2600000 && no "a HIGHER value was lowered" || ok "higher than default -> never lowered"

# Garbage must not be acted on.
lift abc 2600000 && no "a non-numeric live value was acted on" || ok "non-numeric live value ignored"

# ---- rc22: the lift must go HIGH, not back to the captured number --------------------------------
# The captured default is only whatever the node read when ACC first identified it. Captured on a
# weak source that is 500000, so "restoring" it caps the phone at 500mA on a 2A charger -- and it
# repeats every time the driver zeroes the node. Device-proven on a Mi A3 on HVDCP-3: three input
# nodes written to 500000 within one second, reason "no current limit configured", phone at 5V/500mA.
grep -q '_ccd=5000000' "$SRC"   && ok "input nodes are lifted high, letting the driver clamp"   || no "the lift still writes the captured snapshot - it can cap a fast charger at 500mA"

lift_to() {   # $1 = node path, $2 = captured default -> the value actually written
  case "$1" in
    */current_max|*/input_current|*/input_current_limit|*/input_current_settled) echo 5000000;;
    *) echo "$2";;
  esac
}
[ "$(lift_to /sys/class/power_supply/usb/current_max 500000)" = 5000000 ]   && ok "usb/current_max lifted high, not to 500000" || no "usb/current_max still gets 500000"
[ "$(lift_to /sys/class/power_supply/main/input_current_settled 500000)" = 5000000 ]   && ok "input_current_settled lifted high" || no "input_current_settled still gets the snapshot"
[ "$(lift_to /sys/class/power_supply/battery/constant_charge_current 3000000)" = 3000000 ]   && ok "a battery-side charge current keeps its recorded default"   || no "a battery-side node was wrongly treated as an input node"

fin
