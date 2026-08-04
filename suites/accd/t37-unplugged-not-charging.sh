#!/system/bin/sh
# t37 - a phone with no cable attached must never be reported as Charging.
#
# idle_discharging decides charge direction from three inferences: the current sign read through a
# cached per-device polarity, a charge_counter window, and the kernel's status node. Each can be
# wrong on its own, and on an unplugged phone all three failed together:
#
#   Mi A3     unplugged, draining 400-980mA, current reads POSITIVE, _DPOL=- -> "Charging"
#   Pixel 6a  unplugged, draining 450mA,     current reads NEGATIVE, _DPOL=+ -> "Charging"
#
# Opposite signs, opposite cached polarities, same wrong answer. The Pixel was correct on exactly
# the samples where charge_counter moved >=150 in the window and wrong on the rest; the A3's counter
# never moved at all (flat 1115400 across 30s), so it was wrong on every sample.
#
# The rc21 tie-break cannot help: it is deliberately one-way (Discharging -> Charging), because
# believing "discharging" while the pack fills is the dangerous error. That leaves a wrong
# "Charging" with nothing to correct it.
#
# So the last word goes to a fact rather than an inference: no cable, no charging.
#
# present() is used, NOT online(). An input-cut switch (input_suspend, current_max 0) drives
# */online to 0 while the cable is still attached, so an online-based gate would call a
# paused-but-plugged phone unplugged and fight ACC's own pause. present stays 1 there.
#
# Pure unit test: the decision chain is reproduced against fake values. No node is read or written.

ID=t37
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir/batt-interface.sh
[ -f "$SRC" ] || { no "batt-interface.sh not found"; fin; }

# ---- source level --------------------------------------------------------------------------------
grep -q '! present 2>/dev/null' "$SRC" \
  && ok "the unplugged gate is present" \
  || no "no unplugged gate - a detached phone can still report Charging"

# It must be the LAST word. Anything that sets Charging after it re-opens the hole.
_tail=$(sed -n '/! present 2>\/dev\/null/,/^}/p' "$SRC" | grep -c '_status=Charging')
[ "${_tail:-0}" -eq 0 ] \
  && ok "nothing sets Charging after the gate" \
  || no "something re-asserts Charging after the gate ($_tail occurrence(s))"

sed -n '/! present 2>\/dev\/null/,/^}/p' "$SRC" | grep -q 'online' \
  && no "the gate keys on online - an input-cut switch would read as unplugged" \
  || ok "the gate keys on present, not online"

# ---- behavioural ---------------------------------------------------------------------------------
# $1 verdict reaching the gate, $2 present (1/0) -> the final verdict
gate() {
  _status=$1
  if [ "$_status" = Charging ] && [ "$2" != 1 ]; then _status=Discharging; fi
  echo "$_status"
}

# The two field cases, both phones.
[ "$(gate Charging 0)" = Discharging ] \
  && ok "unplugged + a wrong Charging verdict -> Discharging (both test phones)" \
  || no "an unplugged phone still reports Charging"

# ACC's own pause must be untouched: cable attached, input cut, present still 1.
[ "$(gate Charging 1)" = Charging ] \
  && ok "cable attached -> the verdict is left alone, so an input-cut pause is unaffected" \
  || no "the gate fired on a plugged phone and would fight ACC's own pause"

# The gate is one-way. It may only ever remove a Charging claim, never create one.
[ "$(gate Discharging 1)" = Discharging ] \
  && ok "plugged + Discharging is not promoted" || no "the gate invented a Charging verdict"
[ "$(gate Discharging 0)" = Discharging ] \
  && ok "unplugged + Discharging stays Discharging" || no "an unplugged verdict was changed"
[ "$(gate Idle 0)" = Idle ] \
  && ok "unplugged + Idle is left alone" || no "the gate disturbed an Idle verdict"
[ "$(gate Idle 1)" = Idle ] \
  && ok "plugged + Idle is left alone" || no "the gate disturbed an Idle verdict"

fin
