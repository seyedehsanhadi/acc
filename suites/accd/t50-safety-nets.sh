#!/system/bin/sh
# t50 - the safety nets: pause_now, leak_backstop, config_sanity, mask_capacity, sw_blacklisted.
#
# The last tranche from the coverage audit. What links these is that they are all BACKSTOPS - code
# that only ever runs when something else has already gone wrong. That makes them the least likely
# to be noticed when broken and the most expensive when they are, because by the time they matter
# the normal path has already failed.
#
#   pause_now        emergency pause: pin the pause level to right here, right now
#   leak_backstop    release a node some OTHER path cut and forgot about
#   config_sanity    warn when a voltage limit will silently break the fuel gauge
#   mask_capacity    rescale the reported percentage so the UI reads 100% at the pause level
#   sw_blacklisted   never re-probe a switch known to hang or brick this device
#
# THE CLAMP THAT MATTERS MOST
#   pause_now sets resume to pause-5, and clamps at 0. Without the clamp a phone paused at 3% gets a
#   resume level of -2, which no comparison can ever satisfy - the phone would never resume.
#
# NO HARDWARE. Every reading and every file is synthetic.

ID=t50
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
MF=$execDir/misc-functions.sh
W=${TMPDIR:-/data/local/tmp}/.t50
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null

xf() {
  awk -v fn="$1" '
    !f { if ($0 ~ "^[ \t]*" fn "\\(\\)[ \t]*\\{") { f=1; ind=""; s=$0
           while (substr(s,1,1)==" " || substr(s,1,1)=="\t") { ind=ind substr(s,1,1); s=substr(s,2) }
           closer=ind "}"; print } next }
    { print; if ($0==closer) exit }' "$2"
}
chk(){ [ "$3" = "$2" ] && ok "$1" || no "$1  (expected '$2', got '$3')"; }
local(){ :; }

# ---- pause_now -----------------------------------------------------------------------------------
_s=$(xf pause_now "$AD")
[ -n "$_s" ] || { no "could not extract pause_now"; fin; }
eval "$_s"
CAP=50
batt_cap(){ echo $CAP; }
pn(){ CAP=$1; capacity[3]=; capacity[2]=; pause_now 2>/dev/null; echo "${capacity[3]}/${capacity[2]}"; }

chk "pause at 80% -> pause 80, resume 75"      "80/75" "$(pn 80)"
chk "pause at 50% -> pause 50, resume 45"      "50/45" "$(pn 50)"
chk "pause at 5%  -> resume clamps to 0"       "5/0"   "$(pn 5)"
chk "pause at 3%  -> resume clamps to 0"       "3/0"   "$(pn 3)"
chk "pause at 0%  -> resume clamps to 0"       "0/0"   "$(pn 0)"
chk "pause at 100% -> resume 95"               "100/95" "$(pn 100)"
# A negative resume is unsatisfiable by every comparator, so the phone would never charge again.
# This is the single assertion the clamp exists for.
_r=$(pn 2); _rv=${_r#*/}
[ "${_rv:-x}" -ge 0 ] 2>/dev/null && ok "resume is never negative at very low SOC (${_r})" \
                                  || no "resume went negative: $_r - the phone could never resume"

# ---- leak_backstop -------------------------------------------------------------------------------
# Releases sibling cut-nodes that some earlier path left off, but must NEVER touch the configured
# switch itself - that is the one node ACC is deliberately holding.
_s=$(xf leak_backstop "$AD")
[ -n "$_s" ] || { no "could not extract leak_backstop"; fin; }
printf '%s' "$_s" | grep -q 'sw0' \
  && ok "leak_backstop identifies the configured switch before sweeping" \
  || no "leak_backstop does not identify the configured switch"
printf '%s' "$_s" | grep -q '\[ "$n" = "$sw0" \] && continue' \
  && ok "and SKIPS it, so the deliberate hold is never released" \
  || no "leak_backstop could release the very switch ACC is holding"
printf '%s' "$_s" | grep -q 'leakcut' \
  && ok "gated on the .leakcut marker, so it only acts after a cut it recorded" \
  || no "leak_backstop is not gated on its own marker"
# It must only sweep in the ENABLE direction - writing 0 to a disable-node.
printf '%s' "$_s" | grep -q 'echo 0 >' \
  && ok "sweeps in the enable direction only (writes 0 to disable-nodes)" \
  || no "leak_backstop does not write the enable value"
printf '%s' "$_s" | grep -qE '\! present \|\| \[ "\$cap" -le "\$pause" \]' \
  && ok "only runs when unplugged or below the pause level - never mid-hold" \
  || no "leak_backstop is not gated on the unplugged/below-pause condition"

# ---- config_sanity -------------------------------------------------------------------------------
# A voltage limit far below the pack's design voltage stops the gauge ever recalibrating, so the
# reported percentage drifts. It must WARN, never silently adjust the user's setting.
_s=$(xf config_sanity "$AD")
[ -n "$_s" ] || { no "could not extract config_sanity"; fin; }
printf '%s' "$_s" | grep -q 'warn_once_per' \
  && ok "config_sanity warns rather than changing the user's value" \
  || no "config_sanity does not warn"
printf '%s' "$_s" | grep -q '_orig / 1000' \
  && ok "normalises microvolt gauge entries to millivolts before comparing" \
  || no "config_sanity compares uV against mV"
printf '%s' "$_s" | grep -q '_orig - 200' \
  && ok "uses a 200mV margin, so an ordinary limit does not nag" \
  || no "config_sanity has no margin and would warn on any limit"
_n=$(printf '%s' "$_s" | grep -c 'maxChargingVoltage\[0\]=' || :)
case "${_n:-0}" in 0) ok "never writes the voltage setting back";; *) no "config_sanity MUTATES maxChargingVoltage";; esac

# ---- mask_capacity -------------------------------------------------------------------------------
# Rescales the reported percentage. It must be opt-in and must refuse nonsensical ranges, because a
# bad rescale makes every number the user sees wrong.
_s=$(xf mask_capacity "$AD")
[ -n "$_s" ] || { no "could not extract mask_capacity"; fin; }
printf '%s' "$_s" | grep -q 'capacity\[4\]:-false' \
  && ok "mask_capacity is opt-in (capacity[4], default false)" \
  || no "mask_capacity is not gated on the opt-in flag"
printf '%s' "$_s" | grep -q 'capacity\[3\]} -le 100' \
  && ok "refuses to mask when the pause level is in the millivolt domain" \
  || no "mask_capacity would rescale against a millivolt pause"
printf '%s' "$_s" | grep -q 'capacity\[3\]:-0} -gt ${capacity\[0\]:-0}' \
  && ok "refuses when pause is not above shutdown (an empty or inverted range)" \
  || no "mask_capacity does not guard against an inverted range"
printf '%s' "$_s" | grep -q 'is_android' \
  && ok "no-ops outside Android, where there is no UI to mask" \
  || no "mask_capacity runs even with no Android UI"

# ---- sw_blacklisted ------------------------------------------------------------------------------
# A switch that hung or bricked a device must never be probed again. The list is user- and
# field-supplied, so it has to survive CRLF, comments, blank lines and three path spellings.
_s=$(xf sw_blacklisted "$MF")
[ -n "$_s" ] || { no "could not extract sw_blacklisted"; fin; }
eval "$_s"
dataDir=$W
printf '# a comment\n\nbattery/input_suspend\t reason here\r\n/sys/class/power_supply/battery/foo\tx\n' > $W/.acc-compat-blacklist
swb(){ if sw_blacklisted "$1" 2>/dev/null; then echo yes; else echo no; fi; }

chk "a bare relative path matches"                    yes "$(swb 'battery/input_suspend')"
chk "the same node as a full path matches"            yes "$(swb '/sys/class/power_supply/battery/input_suspend')"
chk "a full-path entry matches its bare form"         yes "$(swb 'battery/foo')"
chk "an unlisted node is not blacklisted"             no  "$(swb 'battery/charge_disable')"
chk "empty input is not blacklisted"                  no  "$(swb '')"
chk "a comment line is not treated as an entry"       no  "$(swb '# a comment')"
# CRLF is the one that actually bites: a list edited on Windows or pasted from a chat carries \r,
# and an unstripped \r makes every entry fail to match while the file looks correct.
printf 'battery/crlf_node\treason\r\n' > $W/.acc-compat-blacklist
chk "an entry with a trailing CR still matches"       yes "$(swb 'battery/crlf_node')"
: > $W/.acc-compat-blacklist
chk "an empty blacklist blocks nothing"               no  "$(swb 'battery/input_suspend')"
rm -f $W/.acc-compat-blacklist
chk "a missing blacklist blocks nothing"              no  "$(swb 'battery/input_suspend')"

rm -rf "$W" 2>/dev/null
fin
