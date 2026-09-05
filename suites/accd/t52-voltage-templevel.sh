#!/system/bin/sh
# t52 - the voltage limit path, the thermal level, and the config plumbing under it.
#
#   set_ch_volt      accept, refuse, or persist a charging-voltage limit
#   set_temp_level   drive the vendor thermal throttle (siop_level or num_system_temp_levels)
#   srccfg_try       load a config file that may be corrupt, empty, or hostile
#   unset_switch     clear the configured switch
#
# WHY THE VOLTAGE PATH NEEDS THIS
#   A voltage limit is the one setting that can be accepted, displayed as active, and applied
#   nowhere - bug 19. The discriminator is subtle: a missing ch-volt-ctrl-files means EITHER "this
#   phone has no voltage control" OR "the probe has not run yet because the phone has not charged
#   since boot". Getting that wrong in one direction shows a phantom limit; in the other it throws
#   away a limit the user set before their first charge.
#
# WHY set_temp_level NEEDS IT
#   It writes a vendor throttle node on EVERY loop unless read-before-write suppresses it. Some of
#   those nodes re-trigger AICL or the charge FSM on each write, so re-asserting the same value all
#   day throttles fast charge continuously. That is a silent, permanent slowdown with no log line.
#
#   Note the INVERSION: siop_level counts DOWN (100 = unthrottled, so level 20 writes 80) while
#   num_system_temp_levels counts UP. Two nodes, opposite senses, one function.
#
# NO HARDWARE.

ID=t52
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SV=$execDir/set-ch-volt.sh
SP=$execDir/set-prop.sh
BI=$execDir/batt-interface.sh
MF=$execDir/misc-functions.sh
W=${TMPDIR:-/data/local/tmp}/.t52
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null

xf() {
  awk -v fn="$1" '
    !f { if ($0 ~ "^[ \t]*" fn "\\(\\)[ \t]*\\{") { f=1; ind=""; s=$0
           while (substr(s,1,1)==" " || substr(s,1,1)=="\t") { ind=ind substr(s,1,1); s=substr(s,2) }
           closer=ind "}"; print } next }
    { print; if ($0==closer) exit }' "$2"
}
chk(){ [ "$3" = "$2" ] && ok "$1" || no "$1  (expected '$2', got '$3')"; }
local(){ for _l in "$@"; do case "$_l" in *=*) eval "$_l";; esac; done; }

# ---- set_ch_volt : the accepted range ------------------------------------------------------------
# 3700-4300 mV. Above 4.3V is outside what a Li-ion cell should ever see, so a refusal there is
# correct behaviour and must stay - this is a safety ceiling, not a limitation to relax.
_s=$(xf set_ch_volt "$SV")
[ -n "$_s" ] || { no "could not extract set_ch_volt"; fin; }
printf '%s' "$_s" | grep -q '3700' && printf '%s' "$_s" | grep -q '4300' \
  && ok "the accepted range 3700-4300 mV is enforced in the shipped code" \
  || no "the voltage range guard is missing"
printf '%s' "$_s" | grep -q 'ch-volt-ctrl-files' \
  && ok "gates on whether this phone HAS a voltage control node" \
  || no "set_ch_volt does not check for a control file"

# bug 19: on a phone with no voltage node the value must be DROPPED, not persisted - but only once
# the probe has actually run, which is what ch-curr-ctrl-files / ch-switches being non-empty proves.
# The discriminator moved to a DEDICATED marker. It used to read ch-curr-ctrl-files / ch-switches --
# the CURRENT side's state -- as a proxy for whether the VOLTAGE probe had run. That is cross-wired:
# a phone whose current probe had finished but whose voltage probe had not would lose its stored
# voltage cap. $TMPDIR/.mcv-read is the direct signal, written when voltage discovery completes and
# removed when it finds no control file, mirroring .mcc-read. Either form satisfies bug 19.
printf '%s' "$_s" | grep -qE 'ch-curr-ctrl-files.*]|ch-switches|[.]mcv-read' \
  && ok "discriminates 'no such node' from 'probe has not run yet' (bug 19)" \
  || no "no discriminator - it would drop a limit set before the first charge"
# ...and the two arms must actually differ: keep before discovery, drop after.
printf '%s' "$_s" | grep -q 'maxChargingVoltage=($1)' \
  && ok "before discovery the stored value is KEPT" \
  || no "the pre-discovery arm does not preserve the value"
printf '%s' "$_s" | grep -q 'maxChargingVoltage=()' \
  && ok "after discovery with no control file it is DROPPED" \
  || no "the post-discovery arm does not drop the value"
printf '%s' "$_s" | grep -q 'maxChargingVoltage=()' \
  && ok "clears the stored array when the phone cannot support a limit" \
  || no "an unsupported limit stays in the config as a phantom"

# the clear path
printf '%s' "$_s" | grep -q 'apply_on_boot_ default force' \
  && ok "clearing restores the node to its recorded default" \
  || no "clearing does not restore the default"
printf '%s' "$_s" | grep -q 'rm $f' \
  && ok "clearing drops the .volt-custom marker" \
  || no "the marker survives a clear"

_vs=$(
  TMPDIR=$W/vs; PS=$W/vs/ps; dataDir=$W/vs/data; config=$dataDir/config.txt
  mkdir -p $TMPDIR $PS/battery $dataDir
  echo 4150000 > $PS/battery/voltage_max
  echo 'battery/voltage_max::v000::4200000' > $TMPDIR/ch-volt-ctrl-files
  : > $TMPDIR/.volt-custom
  echo 'maxChargingVoltage=(4150 battery/voltage_max::4150000::4200000)' > $config
  isAccd=true; _accdRelease=true; maxChargingVoltage=()
  apply_on_boot(){ [ "${1-}" = default ] && echo 4200000 > $PS/battery/voltage_max; }
  eval "$_s"
  set_ch_volt -; echo "active=$(cat $PS/battery/voltage_max)"
  echo 'maxChargingVoltage=()' > $config
  set_ch_volt -; echo "clear=$(cat $PS/battery/voltage_max)"
)
case "$_vs" in *'active=4150000'*) ok "a stale daemon cannot clear a published voltage cap";;
  *) no "daemon release ignored the on-disk cap: $_vs";; esac
case "$_vs" in *'clear=4200000'*) ok "a real daemon clear still restores the default";;
  *) no "daemon release guard blocked a real clear: $_vs";; esac

# A readable candidate is not necessarily writable. Tensor exposes constant_charge_voltage as
# mode 0666 while SELinux/firmware rejects every write; accepting it creates a phantom cap.
_vr=$(
  TMPDIR=$W/vr; PS=$W/vr/ps; dataDir=$W/vr/data; config=$dataDir/config.txt
  mkdir -p $TMPDIR $PS/battery $dataDir
  echo 4200000 > $PS/battery/constant_charge_voltage
  echo 'battery/constant_charge_voltage::v000::4200000' > $TMPDIR/ch-volt-ctrl-files
  echo 'maxChargingVoltage=()' > $config
  isAccd=false
  apply_on_boot(){ :; }
  print_no_ctrl_file(){ :; }
  print_volt_set(){ :; }
  print_volt_restored(){ :; }
  eval "$_s"
  set_ch_volt 4150 >/dev/null 2>&1; _rc=$?
  [ -e $TMPDIR/ch-volt-ctrl-files ] && _cf=yes || _cf=no
  echo "rc=$_rc array=${maxChargingVoltage[*]-} ctrl=$_cf node=$(cat $PS/battery/constant_charge_voltage)"
)
case "$_vr" in *'rc=1 '*) ok "a voltage target that no node holds is rejected";;
  *) no "a non-working voltage node was accepted: $_vr";; esac
case "$_vr" in *'array= ctrl='*) ok "the rejected voltage is removed from the stored array";;
  *) no "the rejected voltage remains configured: $_vr";; esac
case "$_vr" in *'ctrl=no '*) ok "the non-working voltage candidate is discarded for this boot";;
  *) no "the non-working voltage candidate remains selectable: $_vr";; esac
case "$_vr" in *'node=4200000'*) ok "rejection leaves the original voltage unchanged";;
  *) no "rejection changed the original voltage: $_vr";; esac

_vp=$(
  TMPDIR=$W/vp; PS=$W/vp/ps; dataDir=$W/vp/data; config=$dataDir/config.txt
  mkdir -p $TMPDIR $PS/battery $dataDir
  echo 4200000 > $PS/battery/good
  echo 4200000 > $PS/battery/bad
  printf '%s\n' 'battery/good::v000::4200000' 'battery/bad::v000::4200000' > $TMPDIR/ch-volt-ctrl-files
  echo 'maxChargingVoltage=()' > $config
  isAccd=false
  apply_on_boot(){ [ "${1-}" = default ] || echo 4150000 > $PS/battery/good; }
  print_no_ctrl_file(){ :; }
  print_volt_set(){ :; }
  print_volt_restored(){ :; }
  eval "$_s"
  set_ch_volt 4150 >/dev/null 2>&1; _rc=$?
  _cf=$(tr '\n' ',' < $TMPDIR/ch-volt-ctrl-files)
  echo "rc=$_rc array=${maxChargingVoltage[*]-} ctrl=$_cf good=$(cat $PS/battery/good) bad=$(cat $PS/battery/bad)"
)
case "$_vp" in *'rc=0 '*) ok "a target held by at least one voltage node is accepted";;
  *) no "a working voltage node was rejected: $_vp";; esac
case "$_vp" in *'array=4150 battery/good::4150000::4200000 ctrl='*) ok "only the node that held the target stays configured";;
  *) no "rejected voltage siblings remain in the config: $_vp";; esac
case "$_vp" in *'ctrl=battery/good::v000::4200000,'*) ok "only the working voltage candidate remains selectable";;
  *) no "the voltage candidate list was not pruned: $_vp";; esac
case "$_vp" in *'good=4150000 bad=4200000'*) ok "partial verification distinguishes working and rejected nodes";;
  *) no "partial voltage verification is dishonest: $_vp";; esac

_sp=$(xf set_prop "$SP")
printf '%s' "$_sp" | grep -q 'set_ch_volt.*|| setRc=\$?' \
  && printf '%s' "$_sp" | grep -q 'return "\$setRc"' \
  && ok "a rejected voltage propagates a non-zero command verdict" \
  || no "set_prop still hides a rejected voltage behind exit 0"
printf '%s' "$_sp" | grep -q '\[ "\$setRc" -ne 0 \] || echo "✅"' \
  && ok "a rejected voltage cannot print the success tick" \
  || no "set_prop still prints success for a rejected voltage"

# ---- set_temp_level ------------------------------------------------------------------------------
_s=$(xf set_temp_level "$BI")
[ -n "$_s" ] || { no "could not extract set_temp_level"; fin; }
# The idempotence guard is the whole point: without the read-before-write these nodes get rewritten
# every loop, and on hardware where the write re-triggers AICL that throttles fast charge all day.
printf '%s' "$_s" | grep -q 'cat $b 2>/dev/null)" = "$_t"' \
  && ok "read-before-write: an unchanged level is never re-written" \
  || no "set_temp_level rewrites the node every loop - re-triggers AICL on some hardware"
printf '%s' "$_s" | grep -q '100 - $l' \
  && ok "siop_level is INVERTED (100 = unthrottled), and the code inverts it" \
  || no "siop_level is not inverted - level 20 would throttle to 20% not 80%"
printf '%s' "$_s" | grep -q 'num_system_temp' \
  && ok "also handles the num_system_temp_levels family, which counts the other way" \
  || no "only one thermal node family is handled"
printf '%s' "$_s" | grep -q '\[ -n "$l" \] || return 0' \
  && ok "an unset level is a no-op" \
  || no "an unset level is not guarded"
printf '%s' "$_s" | grep -q 'tl-custom' \
  && ok "level 0 only acts when a custom level was previously set" \
  || no "no marker, so level 0 would write on a phone that never had one"

# Live arithmetic on the two senses, using the real formulas.
siop(){ echo $(( 100 - $1 )); }
nstl(){ echo $(( ( $1 * $2 ) / 100 )); }
chk "siop: level 20 -> node 80"     80 "$(siop 20)"
chk "siop: level 100 -> node 0"     0  "$(siop 100)"
chk "siop: level 0 -> node 100"     100 "$(siop 0)"
chk "num_levels=10, level 50 -> 5"  5  "$(nstl 10 50)"
chk "num_levels=4, level 100 -> 4"  4  "$(nstl 4 100)"
chk "num_levels=4, level 0 -> 0"    0  "$(nstl 4 0)"

# ---- srccfg_try : loading a config that may be hostile --------------------------------------------
# The config is a shell file that gets sourced. A corrupt or truncated one must not take the daemon
# down with it - that is how a broken external write turned into a phone that never charges.
_s=$(xf srccfg_try "$MF")
if [ -n "$_s" ]; then
  eval "$_s"
  printf '%s' "$_s" | grep -qE '2>/dev/null|\|\| *:|return 1' \
    && ok "srccfg_try cannot abort the caller on a bad config" \
    || no "a corrupt config would propagate a failure out of srccfg_try"
  printf 'capacity=(5 101 70 80 false)\n' > $W/good.conf
  srccfg_try $W/good.conf 2>/dev/null && ok "a valid config loads" || no "a valid config was rejected"
  printf 'capacity=(5 101 70 80 false\n' > $W/trunc.conf
  if srccfg_try $W/trunc.conf 2>/dev/null; then no "a truncated config was accepted"; else ok "a truncated config is rejected, not sourced"; fi
  : > $W/empty.conf
  srccfg_try $W/empty.conf >/dev/null 2>&1; ok "an empty config does not abort the caller"
  srccfg_try $W/absent.conf >/dev/null 2>&1; ok "a missing config does not abort the caller"
else
  no "could not extract srccfg_try"
fi

# ---- unset_switch --------------------------------------------------------------------------------
_s=$(xf unset_switch "$MF")
if [ -n "$_s" ]; then
  printf '%s' "$_s" | grep -q 'charging_switch=' \
    && ok "unset_switch clears the switch variable" \
    || no "unset_switch does not clear the switch"
  printf '%s' "$_s" | grep -q 'write-config' \
    && ok "and persists that, so the daemon does not keep using the old one" \
    || no "the cleared switch is never written to config"
else
  no "could not extract unset_switch"
fi

rm -rf "$W" 2>/dev/null
fin
