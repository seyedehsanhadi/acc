#!/system/bin/sh
execDir=${execDir:-/data/adb/vr25/acc}
W=${TMPDIR_T:-/data/local/tmp}/usb-active-type-$$
mkdir -p "$W/usb" "$W/tmp" "$W/data"
cd "$W" || exit 2
TMPDIR=$W/tmp; dataDir=$W/data
. "$execDir/state-export.sh"
for fn in _usb_type _hv_may_kick; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$execDir/misc-functions.sh")"
done
present(){ return 0; }
_iin_ma(){ echo 0; }
echo 5000 > "$TMPDIR/.hvpeak"
P=0; F=0
check(){
  rm -f "$TMPDIR/.hvkicked"
  printf '%s' "$1" > usb/usb_type
  _hv_may_kick; result=$?
  if [ "$result" = "$2" ]; then P=$((P+1)); echo "PASS $3"; else F=$((F+1)); echo "FAIL $3 (rc=$result)"; fi
}
check 'Unknown SDP [DCP] CDP ACA C PD PD_DRP PD_PPS BrickID' 0 'DCP is not PD merely because PD is supported'
check 'Unknown [SDP] DCP CDP ACA C PD PD_DRP PD_PPS BrickID' 0 'SDP can recover when input is proven dead'
check 'Unknown SDP DCP CDP ACA C [PD] PD_DRP PD_PPS BrickID' 1 'active PD remains protected'
check 'Unknown SDP DCP CDP ACA C PD PD_DRP [PD_PPS] BrickID' 1 'active PPS remains protected'
check 'USB_HVDCP_3' 1 'plain vendor HVDCP type remains protected'
printf USB_PD > usb/real_type
check '[DCP] PD' 1 'real_type still has precedence'
rm -f usb/real_type
: > "$TMPDIR/.hvcontract"
check '[DCP] PD' 1 'previously negotiated voltage remains protected'
rm -f usb/usb_type "$TMPDIR/.hvcontract"
_hv_may_kick; result=$?
if [ "$result" = 0 ]; then P=$((P+1)); echo 'PASS absent type preserves the existing dead-input fallback'; else F=$((F+1)); echo 'FAIL absent type lost the dead-input fallback'; fi

echo "t-usb-active-type: $P passed, $F failed"
[ "$F" = 0 ]
