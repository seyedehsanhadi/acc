#!/system/bin/sh
# t165 - the resume path must not force charger enable nodes on while charging is healthy.
#
# FIELD REPORT (munch / Poco F4, test24-14): "charging connected and disconnected 2-3 times at 69%".
# Ledger: 00:38:58 sweep bq2597x-master/charging_enabled <- 1 (enable-revive), unplug at 00:39:00;
# 00:39:08 the same sweep again, unplug at 00:39:11. The firmware holds the charge pumps off while
# USB-PD negotiates and turns the slave off at low current; forcing them on dropped the contract.
# A really dead charger is still revived by the stall watchdog, after 9 s of measured not-charging.
# ARM=<dir holding accd.sh> grades another build (test24-14 must fail 1).

ID=t165
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

ARM=${ARM:-${execDir:-/data/adb/vr25/acc}}
A=$ARM/accd.sh
[ -f "$A" ] || { no "no accd.sh in $ARM"; fin; }

grep -q '(enable-revive)' "$A" \
  && no "the resume path still forces */charging_enabled to 1 while charging" \
  || ok "no unconditional enable sweep on resume"
grep -q 'sweep $_di <- 0 (cut-release)' "$A" \
  && ok "stray cuts are still released on resume" \
  || no "the cut-release sweep is gone"
grep -q 'stall $_en <- 1' "$A" \
  && ok "a charger that stays dead is still revived by the stall watchdog" \
  || no "the stall watchdog no longer revives enable nodes"
fin
