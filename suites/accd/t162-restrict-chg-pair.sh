#!/system/bin/sh
# t162 - a current cap written to qcom-battery/restrict_cur must also arm restrict_chg.
#
# FIELD REPORT (munch / Poco F4, rc24): "Max Current 4000 mA, still charges at 10,000 mA". The
# bundle shows 7.9 A at the battery with a 4500 mA cap live. Xiaomi's smb5 driver only votes FCC with
# restrict_cur while restrict_chg=1; ACC (and VR25 since v2022.6.4) wrote restrict_cur alone. Proven on
# a Mi A3: restrict_cur 600000 + restrict_chg 0 -> 1.43 A, restrict_chg 1 -> 0.60 A.
#
# Fixture only: the nodes are files under $W, write() is a recorder, nothing touches hardware.
# ARM=<dir holding misc-functions.sh> grades another build (the pre-fix one must fail 1 and 2).
#
# FIELD REPORT 2 (munch, test24-10): "set 4000 mA, charging disconnects and connects continuously".
# The ledger showed ACC rewriting the charger INPUT nodes (usb/current_max 12000000 -> 4000000,
# input_current_settled, pc_port, dc, the charge-pump input limits) every few seconds, each rewrite
# landing 0-11 s before every recorded unplug. Those nodes belong to the PD negotiation. Once
# restrict_cur holds the cap and restrict_chg is armed, the battery-side FCC vote enforces it and
# the input nodes are left to the charger (1, 3); without that proof they are still capped (5, 7-9).

ID=t162
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

ARM=${ARM:-${execDir:-/data/adb/vr25/acc}}
W=${W:-/data/local/tmp/t162}
[ -f "$ARM/misc-functions.sh" ] || { no "no misc-functions.sh in $ARM"; fin; }
[ "1" = "2" ] && no "harness: 1 equals 2" || ok "harness: the assertions discriminate"

Q=$W/q/qcom-battery
# $1 arg (value|default)  $2 marker yes|no  $3 restrict_chg before  $4 reject restrict_cur yes|no
# $5 chargingSwitch  $6 exitCode_
run(){
  rm -rf $W/t $W/q $W/ps; mkdir -p $W/t $Q $W/ps/usb
  echo 12000000 > $W/ps/usb/current_max
  if [ "${8:-}" = norestrict ]; then rmdir $Q; else echo 5000000 > $Q/restrict_cur; echo "$3" > $Q/restrict_chg; fi
  [ "$2" = yes ] && : > $W/t/.mcc-custom
  [ "${7:-}" = own ] && : > $W/t/.restrict-chg-own
  printf '%s
' "$Q/restrict_cur::v000::5000000" "usb/current_max::v000::12000000" > $W/t/ch-curr-ctrl-files
  {
    echo "TMPDIR=$W/t"
    echo "PS=$W/ps"
    echo 'applyOnPlug=(); maxChargingVoltage=()'
    if [ "$1" = value ]; then echo "maxChargingCurrent=(800 $Q/restrict_cur::800000::5000000 usb/current_max::800000::12000000)"
    else echo 'maxChargingCurrent=()'; fi
    echo "chargingSwitch=($5)"
    [ -n "${6:-}" ] && echo "exitCode_=$6"
    echo "write(){ _v=\$(eval echo \$1); case \"\$2:$4\" in *restrict_cur:yes) return 0;; esac; echo \"\$_v\" > \"\$2\"; }"
    echo '_wlog(){ :; }'
    sed -n '/^apply_on_plug() {/,/^}/p' "$ARM/misc-functions.sh"
    echo "apply_on_plug $1 >/dev/null 2>&1"
  } > $W/run.sh
  /system/bin/sh $W/run.sh 2>$W/stderr
  echo "chg=$(cat $Q/restrict_chg 2>/dev/null) cur=$(cat $Q/restrict_cur 2>/dev/null) own=$([ -f $W/t/.restrict-chg-own ] && echo Y || echo n) usb=$(cat $W/ps/usb/current_max)"
}
is(){ _g=$(run $3 $4 $5 $6 "$7" "$8" "$9" "${10-}"); [ "$_g" = "$2" ] && ok "$1 ($_g)" || no "$1: got $_g, want $2"; }

is "1 a cap raises restrict_chg, owns it, and leaves the charger input alone" "chg=1 cur=800000 own=Y usb=12000000" value yes 0 no ""
is "2 a release drops a restrict_chg ACC raised and lifts the input high"        "chg=0 cur=5000000 own=n usb=5000000" default no 1 no "" "" own
is "3 a vendor-set restrict_chg=1 is used, not claimed, input left alone"        "chg=1 cur=800000 own=n usb=12000000" value yes 1 no ""
is "4 a release leaves a vendor-set restrict_chg=1 alone"                        "chg=1 cur=5000000 own=n usb=5000000" default no 1 no ""
is "5 a rejected restrict_cur never arms restrict_chg; the input cap still applies" "chg=0 cur=5000000 own=n usb=800000" value yes 0 yes ""
is "6 a stale daemon pass (marker gone) writes nothing"                          "chg=0 cur=5000000 own=n usb=12000000" value no 0 no ""
is "7 a restrict_chg charging switch is never touched; the input cap applies"    "chg=0 cur=800000 own=n usb=800000" value yes 0 no "$Q/restrict_chg 0 1"
is "8 a switch test (exitCode_ set) writes the cap everywhere, arms nothing"      "chg=0 cur=800000 own=n usb=800000" value yes 0 no "" 10
is "9 a phone without restrict nodes keeps capping the input"                    "chg= cur= own=n usb=800000" value yes 0 no "" "" "" norestrict
[ ! -s "$W/stderr" ] && ok "no shell errors" || no "shell errors: $(head -1 $W/stderr)"
rm -rf $W
fin
