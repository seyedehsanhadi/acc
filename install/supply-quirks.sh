# Motorola's MMI MediaTek driver exposes CURRENT_MAX as a write-only disable flag.
# Other MediaTek drivers expose a numeric current limit at the same supply names.
# Require both the vendor and the unreadable ABI before using boolean semantics.
mtk_current_flag() {
  case "/$1" in
    */mtk-master-charger/current_max|*/mtk-slave-charger/current_max|*/mtk-mst-div-chg/current_max|*/mtk-slv-div-chg/current_max) ;;
    *) return 1;;
  esac
  [ -f "$1" ] || return 1
  case "$(getprop ro.product.manufacturer 2>/dev/null)" in
    [Mm][Oo][Tt][Oo][Rr][Oo][Ll][Aa]*) ;;
    *) return 1;;
  esac
  ! cat "$1" >/dev/null 2>&1
}

mtk_current_flags() {
  local _mtk_name
  for _mtk_name in mtk-master-charger mtk-slave-charger mtk-mst-div-chg mtk-slv-div-chg; do
    mtk_current_flag "${1:-/sys/class/power_supply}/$_mtk_name/current_max" \
      && printf '%s\n' "${1:-/sys/class/power_supply}/$_mtk_name/current_max"
  done
  return 0
}

# Command nodes are not restoreable settings. Only re-detect a proven dead,
# low-voltage USB supply; an unknown reading must not destroy a working contract.
charge_redetect_safe() {
  local _p=${1:-/sys/class/power_supply} _f _v _i=
  [ ! -f /dev/.vr25/acc/.hvcontract ] || return 1
  [ ! -f /data/adb/vr25/acc-data/.rekick-off ] || return 1
  [ "$(cat "$_p/usb/present" 2>/dev/null)" = 1 ] ||
    [ "$(cat "$_p/usb/online" 2>/dev/null)" = 1 ] || return 1
  for _f in real_type usb_type type; do
    _v=$(cat "$_p/usb/$_f" 2>/dev/null)
    case $_v in *\[*\]*) _v=${_v#*\[}; _v=${_v%%\]*};; esac
    case $_v in *HVDCP*|*PD*|*QC*|*PPS*|*VOOC*|*WARP*|*DASH*|*SCP*|*hvdcp*|*pd*) return 1;; esac
  done
  _v=$(cat "$_p/usb/voltage_now" 2>/dev/null)
  case $_v in ''|*[!0-9]*) return 1;; esac
  [ "$_v" -gt 100000 ] && _v=$((_v / 1000))
  [ "$_v" -gt 0 ] && [ "$_v" -lt 5500 ] || return 1
  for _f in input_current_now current_now; do
    _i=$(cat "$_p/usb/$_f" 2>/dev/null); _i=${_i#-}
    case $_i in ''|*[!0-9]*) continue;; esac
    # power_supply current is in uA. Refuse ambiguous/missing sensors.
    [ "$_i" -le 50000 ] && return 0
    return 1
  done
  return 1
}
