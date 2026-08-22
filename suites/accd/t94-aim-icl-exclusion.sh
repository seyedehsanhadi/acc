#!/system/bin/sh
# t94 - the aim's input-ceiling release must not write battery-side or gauge nodes.
#
# THE DEFECT. ctrl_charging() releases the input ceiling before re-detecting a contract:
#
#     for _mcf in */current_max */input_current_limit */input_current_settled; do
#       [ -w "$_mcf" ] || continue
#       case "$_mcf" in */battery/*|*/bms/*) continue;; esac
#       echo 5000000 > "$_mcf" 2>/dev/null || :
#     done
#
# The daemon is cd'd into /sys/class/power_supply (init does it once; the reads either side of this
# block are relative, e.g. `read -r _mcv < usb/voltage_now`). So the glob yields ONE-SLASH paths -
# battery/current_max, usb/current_max. The exclusion pattern */battery/* needs a component before
# AND after "battery", so it matches none of them. The exclusion has never fired.
#
# WHY IT MATTERS, and it is not the typo. accd.sh says of these very nodes:
#   "The battery and the gauges are excluded on top of that: their current_max is a battery-side
#    FCC, a different quantity."
# A battery-side FCC is the same quantity as maxChargingCurrent. Writing 5000000 to it sets the pack
# limit to 5000mA - inside the 3000-5499 pump dead zone that the rc20-alpha4 veto exists to keep
# clear, because a cap below pump need makes the firmware refuse pump mode and fall back to buck.
# That is the curtana symptom, arrived at with no user config involved.
#
# The sibling at acc.sh:886 uses the identical pattern and is CORRECT - it globs absolute paths,
# where */battery/* matches. Only the relative-path site is broken. Do not "fix" the other one.
#
# Introduced in rc22 (43f7f35). rc19/rc20/rc21 have neither the loop nor the pattern.
#
# NO HARDWARE.

ID=t94
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
[ -f "$AD" ] || { no "accd.sh not found at $AD"; fin; }
W=${TMPDIR:-/data/local/tmp}/.t94.$$
rm -rf "$W" 2>/dev/null; mkdir -p "$W" 2>/dev/null
[ -d "$W" ] || { no "scratch not creatable at $W - refusing to report a verdict from an unwritten tree"; fin; }

# ---- lift the SHIPPED loop, do not reimplement it ---------------------------------------------------
_blk=$(sed 's/^[[:space:]]*#.*//' "$AD" \
  | awk '/for _mcf in \*\/current_max \*\/input_current_limit \*\/input_current_settled; do/{f=1} f{print} f && /^[[:space:]]*done$/{exit}')
case "$_blk" in
  *'for _mcf in */current_max'*) : ;;
  *) no "could not extract the ceiling-release loop - this suite would grade nothing"; fin ;;
esac
# rc24 routes the lift through write(), so the blacklist and the write ledger apply - it is no
# longer a raw `echo 5000000 >`. Accept either spelling: what this suite grades is WHICH nodes get
# written, not the mechanism used to write them, and pinning the mechanism here made the whole file
# abort with "no verdict" against a build that had simply been made safer.
case "$_blk" in
  *'echo 5000000'*|*'write 5000000'*) : ;;
  *) no "extracted block writes nothing - extraction is truncated, no verdict"; fin ;;
esac

# ---- run it against a fake power_supply tree --------------------------------------------------------
# Real writes to real files. Nothing is faked except the tree, so the assertion measures what the
# shipped text actually does to node names shaped like the ones the daemon sees.
SUPPLIES="battery bms maxfg qcom,fuelgauge usb main main-charger dc pc_port"
build(){
  rm -rf "$W/psy" 2>/dev/null
  for s in $SUPPLIES; do
    mkdir -p "$W/psy/$s" 2>/dev/null
    for n in current_max input_current_limit input_current_settled; do
      printf '%s' 0 > "$W/psy/$s/$n" 2>/dev/null
    done
  done
}
val(){ cat "$W/psy/$1/${2:-current_max}" 2>/dev/null; }

build
# rc24 lifts through write(), which does not exist inside this eval - so without a stand-in the loop
# writes nothing at all and every "untouched" below is vacuous. The stand-in performs the write and
# nothing else: what is being graded is which nodes the loop SELECTS.
( cd "$W/psy"
  write(){ printf '%s' "$1" > "$2" 2>/dev/null; }
  eval "$_blk" ) >/dev/null 2>&1

# ---- 1: the loop ran at all -------------------------------------------------------------------------
# FIRST, and fatal. Without this a broken extraction writes nothing, every exclusion below reads
# "untouched", and the suite reports a clean pass over a test that did nothing.
# rc24 replaced the deny-list with an ALLOW-list of charger-owned supplies, so the proof that the
# loop ran is a write to main - not to usb. usb is now deliberately excluded, because one write to
# usb/current_max was measured dropping a Pixel port to 100 mA, and it is asserted as such below.
if [ "$(val main)" = 5000000 ]; then
  ok "the shipped loop ran and released the charger-owned supply (main)"
else
  no "the shipped loop wrote nothing to main - the tree or the extraction is wrong, so every exclusion result below is meaningless"
  fin
fi

# The negotiation supplies are the point of the allow-list: writing them renegotiates the port.
for s in usb dc pc_port; do
  if [ "$(val "$s")" = 0 ]; then
    ok "$s/current_max was left alone - it is the negotiation side, not a current ceiling"
  else
    no "$s/current_max was written $(val "$s") - this is the write that drops a port to 100 mA"
  fi
done

# ---- 2: the exclusions the comment promises ---------------------------------------------------------
for s in battery bms maxfg qcom,fuelgauge; do
  if [ "$(val "$s")" = 0 ]; then
    ok "$s/current_max was left alone"
  else
    no "$s/current_max was written $(val "$s") - a battery-side FCC set to 5000mA lands in the pump dead zone"
  fi
done

# ---- 3: the same exclusion on the other two node names ----------------------------------------------
for n in input_current_limit input_current_settled; do
  if [ "$(val battery "$n")" = 0 ]; then
    ok "battery/$n was left alone"
  else
    no "battery/$n was written $(val battery "$n") - the exclusion must cover every name in the glob"
  fi
done

# ---- 4: the charger-owned supplies still get released ------------------------------------------
# The allow-list must not be so narrow that nothing is released: a charger-side ceiling left in
# place during detection is the thing this loop exists to prevent. dc and pc_port are NOT in this
# set any more and are asserted untouched above - they are the negotiation side, and rc24 excluded
# them after one write to a port's current_max was measured dropping it to 100 mA.
for s in main main-charger; do
  if [ "$(val "$s")" = 5000000 ]; then
    ok "$s/current_max still released"
  else
    no "$s/current_max was NOT released - the allow-list is too narrow and detection now measures our own ceiling"
  fi
done

# ---- 5: the allow-list matches on the SUPPLY NAME, so the cwd cannot make it go dead -----------
# The daemon is cd'd into /sys/class/power_supply today, but nothing enforces that. rc23 matched on
# a path shape and its exclusion had never once fired as a result. Prove the selection survives an
# absolute path: a battery node must still be skipped, and a charger node must still be chosen.
_sel=$( set +u
  _blkabs=$(printf "%s" "$_blk")
  for _mcf in /sys/class/power_supply/battery/current_max /sys/class/power_supply/main/current_max; do
    case "${_mcf%/*}" in main|main-charger|mainchg|charger|gccd|bbc) echo "chose ${_mcf}";; *) case "${_mcf%/*}" in */main|*/main-charger) echo "chose ${_mcf}";; *) echo "skipped ${_mcf}";; esac;; esac
  done )
case "$_sel" in
  *"skipped /sys/class/power_supply/battery/current_max"*)
    ok "an absolute battery path is still skipped by the allow-list" ;;
  *) no "an absolute battery path would be written: [$_sel]" ;;
esac


rm -rf "$W" 2>/dev/null
fin
