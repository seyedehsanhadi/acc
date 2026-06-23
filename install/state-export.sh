# Advanced Charging Controller -- state export (subsystem A)
# Copyright 2017-2024, VR25 / community
# License: GPLv3+
#
# Publishes a machine-readable snapshot of ACC's ACTUAL state so the front-end (AccA)
# can read it back. The same file is, at once: the control-bus confirmation, the
# diagnostics feed, and the exportable report source.
#
# Contracts: tmpfs only; atomic (temp+rename, no torn reads); best-effort/non-blocking
# (never stalls the safety loop); fingerprint is non-PII; rule S1 -- a value that cannot
# be read is JSON null, never 0.


# Minimal JSON string escaper.
_se_esc() {
  printf '%s' "${1-}" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | tr '\t\r\n' '   ' \
    | tr -d '\000-\010\013\014\016-\037'
}


# Echo a clean (optionally negative) integer, else "null". Rule S1: a failed/garbage
# read becomes null, never 0.
_se_num() {
  local v="${1-}"
  case "$v" in -*) v="${v#-}";; esac
  case "$v" in
    ''|*[!0-9]*) echo null;;
    *) echo "${1-}";;
  esac
}


# Device + acc-version metadata. Reads the version from module.prop directly, so it is
# correct in EVERY context (daemon, acca front-end, acc CLI) -- accVer/accVerCode are
# only set in acc.sh, which is why the daemon/acca paths printed an empty version.
# Not cached (avoids a stale cache after an update); getprop is cheap.
_se_meta() {
  local model man soc hw rel bld fp ver vc
  model=$(getprop ro.product.model 2>/dev/null)
  man=$(getprop ro.product.manufacturer 2>/dev/null)
  soc=$(getprop ro.board.platform 2>/dev/null)
  hw=$(getprop ro.hardware 2>/dev/null)
  rel=$(getprop ro.build.version.release 2>/dev/null)
  bld=$(getprop ro.build.id 2>/dev/null)
  ver=$(sed -n 's/^version=//p' "$execDir/module.prop" 2>/dev/null | head -1)
  vc=$(sed -n 's/^versionCode=//p' "$execDir/module.prop" 2>/dev/null | head -1)
  fp="$(_se_esc "$model")|$(_se_esc "$soc")|$(_se_esc "$hw")|$(_se_esc "$bld")"
  printf '"device":{"model":"%s","manufacturer":"%s","soc":"%s","hardware":"%s","androidRelease":"%s","buildId":"%s","fingerprint":"%s"},"acc":{"version":"%s","versionCode":"%s"}' \
    "$(_se_esc "$model")" "$(_se_esc "$man")" "$(_se_esc "$soc")" "$(_se_esc "$hw")" \
    "$(_se_esc "$rel")" "$(_se_esc "$bld")" "$fp" "$(_se_esc "$ver")" "$(_se_esc "$vc")"
}


# Status source priority: daemon-computed _status > kernel uevent POWER_SUPPLY_STATUS
# (read atomically with current, so they are coherent) > current-sign derivation. $1=current,
# $2=uevent status string. "Not charging" maps to Idle (same as read_status).
_se_status() {
  local s="${_status:-}"
  case "$s" in
    ''|unknown) ;;
    *) printf '%s' "$s"; return 0;;
  esac
  case "${2:-}" in
    Charging|Discharging|Full) printf '%s' "$2"; return 0;;
    Not\ charging) printf 'Idle'; return 0;;
  esac
  case "${1:-null}" in
    null|'') printf 'unknown';;
    0) printf 'Idle';;
    -*) printf 'Discharging';;
    *) printf 'Charging';;
  esac
}


# --- smart sensing, generalized for ALL SoCs (not Tensor-only) ---

# plugged? rc9: present-first (cable attached), not online. An input-cut switch
# (input_suspend / current_max 0) drives */online to 0 while the cable is still
# attached, so the old online-only test returned plugged:false and _se_class then
# misread the switch as discharging while plugged. Check charger-side */present
# first (NOT battery/present, always 1), fall back to */online where no present node.
_se_plugged() {
  local _n
  for _n in usb ac dc mains pc_port wireless; do
    _n="/sys/class/power_supply/$_n/present"
    [ -r "$_n" ] && [ "$(cat "$_n" 2>/dev/null)" = 1 ] && { echo true; return; }
  done
  case "$(cat /sys/class/power_supply/*/online 2>/dev/null | tr -d ' \t\n\r')" in
    *1*) echo true;; *) echo false;; esac
}

# current units from magnitude: large abs => uA, else mA (works on any kernel)
_se_units() {
  case "${1:-null}" in null|''|0) echo unknown; return;; esac
  local a="${1#-}"
  if [ "$a" -gt 16000 ] 2>/dev/null; then echo uA; else echo mA; fi   # rc6 (D2): use the SAME 16000 uA/mA cutoff the control side uses (batt-interface / read-ch-curr-ctrl-files-p2), so AccA's reported units never disagree with control in the 16000-20000 band
}

# polarity: cross-check status vs current sign
_se_polarity() {
  case "${2:-null}" in null|'') echo unknown; return;; esac
  case "$1" in
    Charging)    case "$2" in -*) echo inverted;; *) echo normal;; esac;;
    Discharging) case "$2" in -*) echo normal;; *) echo inverted;; esac;;
    *) echo unknown;;
  esac
}

# measured class from plug + current (unit-aware idle band), all SoCs:
# plugged & ~0 -> bypass; unplugged & ~0 -> idle; >0 plugged -> charging; <0 -> discharging
_se_class() {
  local cur="$1" plugged="$2" units="$3" polarity="$4" a thr
  case "$cur" in null|'') echo unknown; return;; esac
  # rc9: normalize the current sign by polarity before classifying. On an inverted-polarity
  # device (charging reads negative / discharging positive) the raw sign mislabeled a cut as
  # "charging"; after this flip >0 always means charging, so a cut reads discharging correctly.
  case "$polarity" in inverted) case "$cur" in -*) cur="${cur#-}";; *) cur="-$cur";; esac;; esac
  a="${cur#-}"
  [ "$units" = uA ] && thr=30000 || thr=30
  if [ "$a" -lt "$thr" ] 2>/dev/null; then
    [ "$plugged" = true ] && echo bypass || echo idle; return
  fi
  case "$cur" in
    -*) echo discharging;;
    *) [ "$plugged" = true ] && echo charging || echo discharging;;
  esac
}


# statusTrust: does the kernel status AGREE with the current-measured class?
#   trusted    = kernel status matches the measured current direction (reliable)
#   measured   = they DISAGREE -> the kernel status is lying (e.g. Tensor reports a status
#                that does not match current); trust the CURRENT, not the status node
#   unverified = not enough signal (current unreadable, or status Unknown)
# $1=status $2=measuredClass $3=current
_se_trust() {
  case "${3:-null}" in null|'') echo unverified; return;; esac
  local sc=
  case "$1" in
    Charging) sc=charging;;
    Discharging) sc=discharging;;
    Idle|Full|Not*charging) sc=idle;;
    *) echo unverified; return;;
  esac
  case "$2" in
    bypass|idle)  [ "$sc" = idle ]        && echo trusted || echo measured;;
    charging)     [ "$sc" = charging ]    && echo trusted || echo measured;;
    discharging)  [ "$sc" = discharging ] && echo trusted || echo measured;;
    *) echo unverified;;
  esac
}


# Native firmware charge-limit block. On Pixel/Tensor (google,charger) and similar, ACC
# controls charging via charge_stop_level/charge_start_level, NOT a chargingSwitch -- so an
# empty chargingSwitch is normal there. Expose it so the front-end can show "native mode"
# instead of "no switch".
_se_native() {
  local d sl st
  for d in /sys/devices/platform/google,charger /sys/devices/platform/soc/soc:google,charger; do
    [ -e "$d/charge_stop_level" ] || continue
    sl=$(cat "$d/charge_stop_level" 2>/dev/null); st=$(cat "$d/charge_start_level" 2>/dev/null)
    printf '"native":{"enabled":true,"stopLevel":%s,"startLevel":%s}' "$(_se_num "$sl")" "$(_se_num "$st")"
    return
  done
  printf '"native":{"enabled":false}'
}


# Build and atomically publish $TMPDIR/state.json. Best-effort; never propagates failure.
write_state() {
  ( set +eu
    local f="$TMPDIR/state.json"
    local t="$TMPDIR/.state.json.tmp"
    local lvl volt cur tmp status ts userLocked
    local ue ue_st ue_cur ue_cap ue_volt ue_temp

    # ONE atomic read of battery/uevent so status+current+... are coherent (separate cats can
    # straddle a state change -- the root reason statusTrust was perpetually "unknown"). Fall
    # back to the individual nodes for any field the uevent does not carry.
    ue=$(cat /sys/class/power_supply/battery/uevent 2>/dev/null)
    ue_st=$(printf '%s\n' "$ue"   | sed -n 's/^POWER_SUPPLY_STATUS=//p'      | head -1)
    ue_cur=$(printf '%s\n' "$ue"  | sed -n 's/^POWER_SUPPLY_CURRENT_NOW=//p' | head -1)
    ue_cap=$(printf '%s\n' "$ue"  | sed -n 's/^POWER_SUPPLY_CAPACITY=//p'    | head -1)
    ue_volt=$(printf '%s\n' "$ue" | sed -n 's/^POWER_SUPPLY_VOLTAGE_NOW=//p' | head -1)
    ue_temp=$(printf '%s\n' "$ue" | sed -n 's/^POWER_SUPPLY_TEMP=//p'        | head -1)

    lvl=$(_se_num "${ue_cap:-$(batt_cap 2>/dev/null)}")
    volt=$(_se_num "${ue_volt:-$(volt_now 2>/dev/null)}")
    cur=$(_se_num "${ue_cur:-$(cat "$currFile" 2>/dev/null)}")
    tmp=$(_se_num "${ue_temp:-$(cat "$temp" 2>/dev/null)}")
    status=$(_se_status "$cur" "$ue_st")
    ts=$(_se_num "$(date +%s 2>/dev/null)")
    userLocked=false
    case "${chargingSwitch[*]-}" in *" --"*) userLocked=true;; esac

    local plugged units polarity mclass conf trust
    plugged=$(_se_plugged)
    units=$(_se_units "$cur")
    polarity=$(_se_polarity "$status" "$cur")
    mclass=$(_se_class "$cur" "$plugged" "$units" "$polarity")
    trust=$(_se_trust "$status" "$mclass" "$cur")
    conf=low
    { [ "$units" != unknown ] && [ "$cur" != null ]; } && conf=medium
    [ "$trust" = trusted ] && conf=high

    {
      printf '{"schemaVersion":1,"ts":%s,' "$ts"
      _se_meta
      printf ',"battery":{"capacityPct":%s,"current_raw":%s,"voltage_raw":%s,"temp_deci_c":%s,"status":"%s"}' \
        "$lvl" "$cur" "$volt" "$tmp" "$(_se_esc "$status")"
      printf ',"config":{"capacity":"%s","temperature":"%s","chargingSwitch":"%s","allowIdleAbovePcap":"%s","prioritizeBattIdleMode":"%s"}' \
        "$(_se_esc "${capacity[*]-}")" "$(_se_esc "${temperature[*]-}")" \
        "$(_se_esc "${chargingSwitch[*]-}")" "$(_se_esc "${allowIdleAbovePcap-}")" \
        "$(_se_esc "${prioritizeBattIdleMode-}")"
      # smart sensing, measured live for any SoC
      printf ',"plugged":%s' "$plugged"
      printf ',%s' "$(_se_native)"
      printf ',"sensing":{"currentUnits":"%s","polarity":"%s","statusTrust":"%s","confidence":"%s"}' \
        "$units" "$polarity" "$trust" "$conf"
      printf ',"switch":{"locked":"%s","userLocked":%s,"measuredClass":"%s"}' \
        "$(_se_esc "${chargingSwitch[*]-}")" "$userLocked" "$mclass"
      printf '}\n'
    } > "$t" 2>/dev/null && mv -f "$t" "$f" 2>/dev/null
  ) 2>/dev/null || :
}


# For `acca --state`: ALWAYS refresh first so an interactive call is never stale (the old
# cat-if-exists behaviour froze the snapshot once a file existed), then print it. If the
# refresh somehow produced nothing, emit a valid error marker so the caller always gets
# parseable JSON -- never an empty body that reads as "all 0".
print_state() {
  write_state 2>/dev/null || :
  if [ -f "$TMPDIR/state.json" ]; then
    cat "$TMPDIR/state.json"
  else
    echo '{"schemaVersion":1,"error":"daemon-not-running"}'
  fi
}
