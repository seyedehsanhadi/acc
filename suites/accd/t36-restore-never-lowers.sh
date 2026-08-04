#!/system/bin/sh
# t36 - clearing a current limit must never LOWER a live negotiated node.
#
# apply_on_plug default writes the value recorded when the control files were first identified.
# Those snapshots are taken whenever the probe happened to run: on a computer's USB port
# usb/current_max reads 500000, and writing that back later over a wall charger's negotiated
# 2450000 holds the phone at 500mA for the rest of the session.
#
# The rc21 back-off guard cannot catch this. It is deliberately APPLY-only ([ "$arg" = value ]),
# because a skipped RESTORE would strand a node capped -- so nothing bounded a restore at all.
#
# This is the same mistake as the curtana init restore, which accd already bounds (t32,
# _ccn -le 100000). Field values from that report, all far above any plausible snapshot:
#   usb/current_max 2450000   main/current_max 3000000   pc_port/current_max 2400000
#
# Fails toward WRITING: an unreadable live value or a non-numeric default still restores, because
# leaving a node capped is the failure this whole path exists to prevent.
#
# Pure unit test: the decision is reproduced against fake values. No node is read or written.

ID=t36
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
MF=$execDir/misc-functions.sh
[ -f "$MF" ] || { no "misc-functions.sh not found"; fin; }

# ---- source level ----------------------------------------------------------------------------------
# The guard must live in apply_on_plug, NOT in its neighbour apply_on_boot, which restores a
# different set of nodes on a different trigger.
_ap=$(sed -n '/^apply_on_plug() {/,/^  wait/p' "$MF")
printf '%s' "$_ap" | grep -q '"\$arg" = default' \
  && ok "apply_on_plug has a restore-only guard" \
  || no "no restore guard in apply_on_plug - a probe-time snapshot can still cap a wall charger"

printf '%s' "$_ap" | grep -q '\-lt "\$default"' \
  && ok "the guard compares live against the recorded default" \
  || no "the guard does not compare against the default"

# Input nodes are owned by charger negotiation, so their recorded "default" is meaningless -- it is
# whatever they read when ACC first looked. Restoring it caps the phone at that number. Measured on
# a Mi A3 on a 2A HVDCP-3 charger: a clear wrote 500000 to five input nodes and the phone dropped to
# 4836mV/500mA. Write high and let the driver clamp, as the uninstaller already does.
printf '%s' "$_ap" | grep -q 'default=5000000' \
  && ok "input nodes are restored high, not to a probe-time snapshot" \
  || no "input nodes still get the recorded snapshot - a clear can cap the phone at 500mA"

printf '%s' "$_ap" | grep -q '\*/input_current_settled' \
  && ok "input_current_settled is covered (it was one of the five that capped the A3)" \
  || no "input_current_settled is not covered"

_ab=$(sed -n '/^apply_on_boot() {/,/^  wait/p' "$MF")
printf '%s' "$_ab" | grep -q '"\$arg" = default' \
  && no "the guard landed in apply_on_boot instead of apply_on_plug" \
  || ok "apply_on_boot is untouched"

grep -q 'local _rk= _rv= _rc= _lv=' "$MF" \
  && ok "the live-value variable is declared local" \
  || no "_lv is not local - it would leak between loop iterations and across callers"

# ---- behavioural -----------------------------------------------------------------------------------
# $1 = live value on the node, $2 = recorded default, $3 = arg -> 0 means "write it"
wr() {
  _live=$1; _def=$2; _arg=$3
  [ "$_arg" = default ] || return 0        # an APPLY is never affected by this guard
  case "${_live:-x}" in
    ''|*[!0-9]*) return 0;;
    *) case "${_def:-x}" in
         ''|*[!0-9]*) return 0;;
         *) [ "$_live" -lt "$_def" ] && return 0 || return 1;;
       esac;;
  esac
}

# The field bug: live negotiated values must survive a clear.
wr 2450000 500000 default && no "a live 2450000 was lowered to a 500000 probe snapshot" \
                          || ok "live usb/current_max 2450000 vs snapshot 500000 -> left alone"
wr 3000000 1500000 default && no "a live 3000000 was lowered to 1500000" \
                           || ok "live main/current_max 3000000 vs 1500000 -> left alone"
wr 2400000 500000 default && no "a live pc_port 2400000 was lowered" \
                          || ok "live pc_port 2400000 -> left alone"

# What the restore exists for must still work.
wr 0 2600000 default      && ok "a node ACC zeroed IS restored (the case this path exists for)" \
                          || no "a zeroed node is no longer un-capped - 'the cap won't clear' is back"
wr 500000 2600000 default && ok "a node ACC capped low IS raised" || no "a low cap is no longer lifted"
wr 10000 3000000 default  && ok "a 10000 cap token IS raised"     || no "a cap token is no longer lifted"

# Never write when there is nothing to gain.
wr 2600000 2600000 default && no "an equal value was rewritten" || ok "equal value -> no write"

# Fail toward writing: never strand a capped node because a read went wrong.
wr abc 2600000 default && ok "an unreadable live value still restores" \
                       || no "an unreadable live value blocked the restore - a node could stay capped"
wr '' 2600000 default  && ok "an empty live value still restores" || no "an empty read blocked the restore"
wr 500000 '' default   && ok "a non-numeric default still restores" || no "a garbage default blocked the restore"

# An APPLY must be completely unaffected, in both directions.
wr 2450000 500000 value && ok "an APPLY still writes, even downward (that is what a cap IS)" \
                        || no "the guard leaked into the apply path and broke current capping"
wr 0 500000 value       && ok "an APPLY writes upward too" || no "the guard blocked an apply"

# ---- input nodes: restored high regardless of the snapshot -------------------------------------------
inp() {   # $1 = node path -> the value a RESTORE writes
  case "$1" in
    */current_max|*/input_current|*/input_current_limit|*/input_current_settled) echo 5000000;;
    *) echo snapshot;;
  esac
}
[ "$(inp /sys/class/power_supply/usb/current_max)" = 5000000 ]   && ok "usb/current_max restored high" || no "usb/current_max still gets the snapshot"

# An input node the DRIVER owns must be left alone. Writing over a live negotiated value re-triggers
# AICL and it settles lower: measured on a Mi A3, a restore wrote 5000000 over a healthy live
# 1200000 and the driver came back at 200000.
grep -q '\-le 100000' "$MF"   && ok "the input lift is bounded to nodes ACC could have capped"   || no "the lift is unbounded - it will disturb a live negotiation"

lift() {   # $1 = live value, $2 = what ACC applied -> 0 means "write 5000000"
  case "${1:-x}" in ''|*[!0-9]*) return 0;; esac
  [ "$1" = "${2:-}" ] && return 0
  [ "$1" -le 100000 ]
}
lift 0 v000        && ok "a zeroed input node IS lifted"      || no "a zeroed node is not lifted"
lift 10000 v000    && ok "a 10000 cap token IS lifted"        || no "a cap token is not lifted"
lift 100000 v000   && ok "exactly 100mA is lifted (boundary)" || no "the 100mA boundary excludes itself"
lift abc v000      && ok "an unreadable live value still lifts" || no "an unreadable value blocked the lift"

# The regression this rule exists for, measured on a Pixel 6a: ACC capped usb/current_max to
# 1000000 on a 2200000 charger, and a clear left it there because 1000000 is above the near-zero
# bound. "The cap will not clear" is a field report this whole path exists to prevent.
lift 1000000 1000000 && ok "a node still holding ACC's own 1000000 cap IS released"                      || no "ACC's own cap is not released - the cap will not clear"
lift 2200000 1000000 && no "a live 2200000 was overwritten while ACC had applied 1000000"                      || ok "a value the driver has since raised is left alone"
lift 1200000 v000    && no "a live negotiated 1200000 was overwritten (the A3 AICL collapse)"                      || ok "a live negotiated 1200000 is left alone"
lift 2450000 v000    && no "a live 2450000 was overwritten"   || ok "a live 2450000 is left alone"
[ "$(inp /sys/class/power_supply/main/input_current_settled)" = 5000000 ]   && ok "input_current_settled restored high" || no "input_current_settled still gets the snapshot"
[ "$(inp /sys/class/power_supply/pc_port/current_max)" = 5000000 ]   && ok "pc_port/current_max restored high" || no "pc_port/current_max still gets the snapshot"
[ "$(inp /sys/class/power_supply/battery/constant_charge_current)" = snapshot ]   && ok "the battery-side charge current keeps the never-lower rule, not the high write"   || no "constant_charge_current was wrongly treated as an input node"

fin
