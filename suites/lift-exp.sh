#!/system/bin/sh
# THE ONE EXPERIMENT that decides the usb/current_max lift rule.
#
# Two measurements in the tree disagree and they are NOT the same event:
#   Mi A3   "5000000 written over a live 1.2A -> driver settled at 200mA"  -- later blamed on a
#           ~500 milliohm cable, whose input collapses identically with ACC uninstalled.
#   bluejay "one write to usb/current_max dropped the port to ~100mA"      -- asserted in
#           _hv_lift and the rc24 changelog, never re-tested with a known-good cable.
#
# If the port COLLAPSES here on a good cable, an _hv_lift-style skip belongs on LIFTS OF A LIVE
# PORT. If it HOLDS, the cable explanation stands and the current code is right.
# This does NOT touch the cap-clear paths either way -- those must write usb, or the cap strands.
#
# Read-only except for the one write, which is restored immediately.
say(){ echo "$*"; }
N=/sys/class/power_supply/usb/current_max
[ -w "$N" ] || { say "SKIP: $N not writable"; exit 0; }

samp(){ printf 'usb: %8s uA   vbus: %8s uV   batt: %9s uA   status: %s\n' \
  "$(cat $N 2>/dev/null)" \
  "$(cat /sys/class/power_supply/usb/voltage_now 2>/dev/null)" \
  "$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)" \
  "$(cat /sys/class/power_supply/battery/status 2>/dev/null)"; }

say "=== BEFORE (5 samples, 3s apart) ==="
i=0; while [ $i -lt 5 ]; do samp; sleep 3; i=$((i+1)); done
ORIG=$(cat $N 2>/dev/null)
say ""
say "original usb/current_max = $ORIG"
say "=== WRITING 5000000 ==="
# A refused write used to print one "write failed" line and then carry on sampling for another
# 45 seconds, ending in a VERDICT INPUT paragraph inviting a comparison between two identical
# halves. That is how this experiment got run three times without ever answering its question.
# Both test phones refuse it: on the Mi A3 the node is mode 666 and owned by system:system, and
# still rejects a root write under SELinux Enforcing. Stop here and say so instead.
if ! echo 5000000 > $N 2>/dev/null; then
  say ""
  say "ABORTED: the kernel refused the write to $N"
  say "  node   : mode=$(stat -c %a $N 2>/dev/null) owner=$(stat -c %U:%G $N 2>/dev/null) value=$ORIG"
  say "  selinux: $(getenforce 2>/dev/null)  uid=$(id -u)"
  say "  Nothing was changed, so there is no before/after to compare and no verdict to draw."
  say "  This experiment cannot answer the question from a shell on this phone. To settle it,"
  say "  drive the write through ACC itself, which runs in a different SELinux domain:"
  say "    acc -s mcc=500   then watch $N and battery/current_now"
  exit 3
fi
i=0; while [ $i -lt 10 ]; do samp; sleep 3; i=$((i+1)); done
say ""
say "=== RESTORING $ORIG ==="
echo "$ORIG" > $N 2>/dev/null || :
i=0; while [ $i -lt 5 ]; do samp; sleep 3; i=$((i+1)); done
say ""
say "VERDICT INPUT: compare the battery uA before vs during. A collapse to ~100mA means the"
say "write renegotiated the port; a steady or higher current means the cable story stands."
