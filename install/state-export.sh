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


# Status: prefer the daemon-computed _status; otherwise derive a best-effort value from
# the current sign so the field is meaningful even on the front-end/on-demand path that
# never calls read_status. (Low-confidence -- sensing.statusTrust stays "unknown" until
# subsystem C calibrates polarity/units.)
_se_status() {
  local s="${_status:-}"
  case "$s" in
    ''|unknown) ;;
    *) printf '%s' "$s"; return 0;;
  esac
  case "${1:-null}" in
    null|'') printf 'unknown';;
    0) printf 'Idle';;
    -*) printf 'Discharging';;
    *) printf 'Charging';;
  esac
}


# Build and atomically publish $TMPDIR/state.json. Best-effort; never propagates failure.
write_state() {
  ( set +eu
    local f="$TMPDIR/state.json"
    local t="$TMPDIR/.state.json.tmp"
    local lvl volt cur tmp status ts userLocked

    lvl=$(_se_num "$(batt_cap 2>/dev/null)")
    volt=$(_se_num "$(volt_now 2>/dev/null)")
    cur=$(_se_num "$(cat "$currFile" 2>/dev/null)")
    tmp=$(_se_num "$(cat "$temp" 2>/dev/null)")
    status=$(_se_status "$cur")
    ts=$(_se_num "$(date +%s 2>/dev/null)")
    userLocked=false
    case "${chargingSwitch[*]-}" in *" --"*) userLocked=true;; esac

    {
      printf '{"schemaVersion":1,"ts":%s,' "$ts"
      _se_meta
      printf ',"battery":{"capacityPct":%s,"current_raw":%s,"voltage_raw":%s,"temp_deci_c":%s,"status":"%s"}' \
        "$lvl" "$cur" "$volt" "$tmp" "$(_se_esc "$status")"
      printf ',"config":{"capacity":"%s","temperature":"%s","chargingSwitch":"%s","allowIdleAbovePcap":"%s","prioritizeBattIdleMode":"%s"}' \
        "$(_se_esc "${capacity[*]-}")" "$(_se_esc "${temperature[*]-}")" \
        "$(_se_esc "${chargingSwitch[*]-}")" "$(_se_esc "${allowIdleAbovePcap-}")" \
        "$(_se_esc "${prioritizeBattIdleMode-}")"
      # sensing / switch-class slots are filled by subsystem C; honest "unknown" until then
      printf ',"sensing":{"currentUnits":"unknown","polarity":"unknown","statusTrust":"unknown","confidence":"low"}'
      printf ',"switch":{"locked":"%s","userLocked":%s,"measuredClass":"unknown"}' \
        "$(_se_esc "${chargingSwitch[*]-}")" "$userLocked"
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
