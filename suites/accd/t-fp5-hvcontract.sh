#!/system/bin/sh
# The FP5 report of 2026-09-10: "hanging in charging state but does not charge", cleared only by a
# reboot, not by a daemon restart.
#
# POWER_SUPPLY_USB_TYPE lists every type the port supports and brackets the ACTIVE one. The FP5 sat
# on a DCP:
#
#   Unknown SDP [DCP] CDP ACA C PD PD_DRP PD_PPS BrickID
#
# The old matcher tested that whole line against *PD*, so it recorded a high-voltage contract that
# was never negotiated. .hvcontract lives in tmpfs, so it outlived every daemon restart and blocked
# the re-kick for the rest of the boot while the pack drained at ~0.9A behind a Charging icon.
#
# This runs BOTH halves against private files: the daemon branch that creates the marker, and the
# gate that reads it.

ID=t-fp5-hvcontract
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
AD=$execDir/accd.sh
MF=$execDir/misc-functions.sh
SE=$execDir/state-export.sh
for f in "$AD" "$MF" "$SE"; do [ -f "$f" ] || { no "missing $f"; fin; }; done

FP5='Unknown SDP [DCP] CDP ACA C PD PD_DRP PD_PPS BrickID'
W=${TMPDIR_T:-/data/local/tmp}/fp5-hv-$$
rm -rf "$W"; mkdir -p "$W/usb" "$W/tmp" 2>/dev/null

echo "--- 1. the daemon's own branch must not record a contract the charger never negotiated"
# The two lines that set the marker from the TYPE, cut out of accd.sh.
blk=$(sed -n '/^             _hvt=$(_usb_type)/,/^             esac ;;/p' "$AD" | sed -e 's/^             //' -e 's/^esac ;;$/esac/')
if [ -z "$blk" ]; then
  # An arm with no _usb_type at all still has the old inline loop; grade that instead.
  blk=$(sed -n '/for _tn in real_type usb_type type; do/,/done ;;/p' "$AD" | sed -e 's/^ *//' -e 's/^done ;;$/done/')
  [ -n "$blk" ] || { no "no charger-type branch found in accd.sh"; no "branch not found"; no "branch not found"; fin; }
fi
mark(){ # mark <type string> -> "contract" or "none"
  ( cd "$W" || exit
    TMPDIR=$W/tmp; rm -f "$TMPDIR/.hvcontract"
    printf '%s' "$1" > usb/usb_type
    . "$SE" 2>/dev/null || :
    eval "$(sed -n '/^_usb_type() {/,/^}/p' "$MF")" 2>/dev/null || :
    eval "$blk" >/dev/null 2>&1 || :
    [ -f "$TMPDIR/.hvcontract" ] && echo contract || echo none )
}
r=$(mark "$FP5")
[ ".$r" = .none ] && ok "a DCP that merely SUPPORTS PD records no contract" \
  || no "the FP5 charger string still records a high-voltage contract: $r"
r=$(mark 'Unknown SDP DCP CDP ACA C [PD] PD_DRP PD_PPS BrickID')
[ ".$r" = .contract ] && ok "an ACTIVE PD still records its contract" \
  || no "an active PD no longer records a contract: $r"
r=$(mark 'USB_HVDCP_3')
[ ".$r" = .contract ] && ok "a plain vendor HVDCP type still records its contract" \
  || no "a vendor HVDCP type no longer records a contract: $r"

echo "--- 2. with no false contract, the re-kick gate lets the phone recover"
gate(){ # gate <type string> <contract?> -> rc of _hv_may_kick
  ( cd "$W" || exit
    TMPDIR=$W/tmp; dataDir=$W/tmp
    rm -f "$TMPDIR/.hvcontract" "$TMPDIR/.hvkicked" "$TMPDIR/.rekick-off"
    [ ".$2" != .contract ] || : > "$TMPDIR/.hvcontract"
    echo 5000 > "$TMPDIR/.hvpeak"
    printf '%s' "$1" > usb/usb_type
    . "$SE" 2>/dev/null || :
    for fn in _usb_type _hv_may_kick; do
      eval "$(sed -n "/^$fn() {/,/^}/p" "$MF")" 2>/dev/null || :
    done
    present(){ return 0; }
    _iin_ma(){ echo 0; }
    _hv_may_kick; echo $? )
}
r=$(gate "$FP5" none)
[ ".$r" = .0 ] && ok "the FP5 collapse is allowed to re-kick" \
  || no "the FP5 collapse is still refused a re-kick (rc=$r)"
r=$(gate 'Unknown SDP DCP CDP ACA C [PD] PD_DRP PD_PPS BrickID' none)
[ ".$r" = .1 ] && ok "a live PD contract is still left alone" \
  || no "a live PD contract would now be re-kicked (rc=$r)"

echo "--- 3. why a daemon restart could not clear it, and a reboot could"
grep -q 'hvcontract' "$AD" && grep -q '\$TMPDIR/\.hvcontract' "$AD" \
  && ok "the marker lives in TMPDIR, which is tmpfs: only a reboot clears it" \
  || no "the marker is no longer kept in TMPDIR; this suite's premise needs rechecking"

echo "--- 4. the whole recovery decision, on the reporter's own numbers"
# His plug: peak 4200mV, no input current, charger string as above. That is a collapsed supply the
# re-kick exists to repair, and the type string is the only thing that stood in the way.
D=$W/probe; rm -rf "$D"; mkdir -p "$D/usb"
verdict(){ # verdict <tree>
  ( cd "$D" || exit
    echo 0 > usb/input_current_now
    printf '%s' "$FP5" > usb/usb_type
    echo 4200 > "$D/.hvpeak"
    TMPDIR=$D; dataDir=$D
    rm -f "$D/.hvcontract" "$D/.hvkicked" "$D/.rekick-off"
    . "$1/state-export.sh" 2>/dev/null || :
    for fn in _mv _ma _iin_ma _usb_type _hv_may_kick; do
      eval "$(sed -n "/^$fn() {/,/^}/p" "$1/misc-functions.sh")" 2>/dev/null || :
    done
    present(){ return 0; }
    : ${hvPeakMaxMv:=5500}; : ${hvDeadMa:=50}
    _hv_may_kick && echo KICK || echo WITHHOLD )
}
r=$(verdict "$execDir")
[ ".$r" = .KICK ] && ok "a collapsed DCP at 4200mV with no input current is repaired: $r" \
  || no "the collapse is still not repaired: $r"
# ...and the same fixture against a tree that matches the whole type list, to show the case is real.
if [ -n "${ARM23-}" ] && [ -f "$ARM23/misc-functions.sh" ]; then
  r=$(verdict "$ARM23")
  [ ".$r" = .WITHHOLD ] && ok "the pre-fix tree withholds it, which is the reported symptom: $r" \
    || no "the pre-fix tree no longer reproduces the symptom: $r"
else
  ok "no ARM23 tree given, the negative control is skipped"
fi


rm -rf "$W" 2>/dev/null
fin
