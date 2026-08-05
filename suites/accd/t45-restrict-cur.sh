#!/system/bin/sh
# t45 - restrict_cur must be released high on a restore, not written back to its probe-time value.
#
# The qcom-battery restricted-charging pair (restrict_chg, restrict_cur) is an input-current ceiling
# exactly like usb/current_max, but it lives outside /sys/class/power_supply, so the never-lower
# restore rule - which is written around node names under power_supply - did not match it.
#
# Measured on a Mi A3 on a QC3 charger. ACC's recorded default for restrict_cur was 1000000, because
# that is what the node read when ACC first identified it, with the vendor's restricted mode already
# engaged. So every restore wrote 1 A back.
#
#   restricted (as ACC restores it) : 4.64 V, icl 2.1 A, battery 1.51 A
#   lifted (uninstaller's values)   : 5.97 V, icl 3.0 A, battery 3.03 A, level 63% -> 70% in 3 min
#
# The phone had been charging at half speed. On Qualcomm hardware that is the curtana report - "fast
# charge is gone" - and ACC's own uninstaller already knew the unrestricted values.

ID=t45
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/misc-functions.sh
UN=$execDir/uninstall.sh
[ -f "$SRC" ] || { no "misc-functions.sh not found"; fin; }

grep -q 'input_current_settled|\*/restrict_cur)' "$SRC" \
  && ok "restrict_cur is matched by the never-lower restore rule" \
  || no "restrict_cur is not in the restore pattern - a restore writes its probe-time value back"

# The rule it joins must still be the release-high one, not a default write.
_b=$(sed -n '/input_current_settled|\*\/restrict_cur)/,/;;/p' "$SRC")
printf '%s' "$_b" | grep -q 'default=5000000' \
  && ok "the branch releases high rather than writing the recorded default" \
  || no "the branch does not release high"

# The uninstaller is the reference for what unrestricted means on this hardware; if these ever
# disagree, one of them is wrong and it should fail loudly rather than drift.
if [ -f "$UN" ]; then
  grep -q 'restrict_cur' "$UN" && grep -q '5000000' "$UN" \
    && ok "the uninstaller still agrees 5000000 is the unrestricted value" \
    || no "the uninstaller no longer writes 5000000 to restrict_cur - the two paths disagree"
  grep -q 'restrict_chg' "$UN" \
    && ok "the uninstaller still clears restrict_chg" \
    || no "the uninstaller no longer clears restrict_chg"
else
  no "uninstall.sh not found, cannot cross-check the unrestricted values"
fi

fin
