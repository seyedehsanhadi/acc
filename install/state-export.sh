# Advanced Charging Controller -- state export (subsystem A)
# Copyright 2017-2024, VR25 / community
# License: GPLv3+
#
# Publishes a machine-readable snapshot of ACC's ACTUAL state to tmpfs so the front-end
# (AccA) can read it back. The same file is, at once: the control-bus confirmation
# (what ACC really holds after a change), the diagnostics feed, and the exportable
# report source.
#
# Contracts (must hold):
#   * tmpfs only ($TMPDIR) -- written every loop, must never wear flash.
#   * atomic -- temp file + rename, so a reader never sees a torn write.
#   * best-effort, non-blocking -- a failure here must NEVER stall the safety loop.
#   * S1: a value that cannot be read is JSON null, NEVER 0 (absence != evidence).
#   * fingerprint carries non-PII props only (no serial / IMEI / ANDROID_ID).


# Minimal JSON string escaper: backslash and double-quote escaped; tabs/CR and other
# control bytes stripped so the output is always valid JSON.
_se_esc() {
  printf '%s' "${1-}" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | tr '\t\r\n' '   ' \
    | tr -d '\000-\010\013\014\016-\037'
}


# Echo the value if it is a clean (optionally negative) integer, else "null".
# Rule S1: a failed/garbage read becomes null, never 0.
_se_num() {
  local v="${1-}"
  case "$v" in -*) v="${v#-}";; esac
  case "$v" in
    ''|*[!0-9]*) echo null;;
    *) echo "${1-}";;
  esac
}


# Static fields (device fingerprint + acc version): computed ONCE and cached in tmpfs,
# so the per-loop export doesn't re-run getprop every iteration.
_se_static() {
  [ ! -f "$TMPDIR/.state-static" ] || { cat "$TMPDIR/.state-static"; return 0; }
  local model man soc hw rel bld fp
  model=$(getprop ro.product.model 2>/dev/null)
  man=$(getprop ro.product.manufacturer 2>/dev/null)
  soc=$(getprop ro.board.platform 2>/dev/null)
  hw=$(getprop ro.hardware 2>/dev/null)
  rel=$(getprop ro.build.version.release 2>/dev/null)
  bld=$(getprop ro.build.id 2>/dev/null)
  # fingerprint = non-PII props only
  fp="$(_se_esc "$model")|$(_se_esc "$soc")|$(_se_esc "$hw")|$(_se_esc "$bld")"
  printf '"device":{"model":"%s","manufacturer":"%s","soc":"%s","hardware":"%s","androidRelease":"%s","buildId":"%s","fingerprint":"%s"},"acc":{"version":"%s","versionCode":"%s"}' \
    "$(_se_esc "$model")" "$(_se_esc "$man")" "$(_se_esc "$soc")" "$(_se_esc "$hw")" \
    "$(_se_esc "$rel")" "$(_se_esc "$bld")" "$fp" \
    "$(_se_esc "${accVer-}")" "$(_se_esc "${accVerCode-}")" > "$TMPDIR/.state-static" 2>/dev/null || return 1
  cat "$TMPDIR/.state-static" 2>/dev/null
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
    status="${_status:-unknown}"
    ts=$(_se_num "$(date +%s 2>/dev/null)")
    userLocked=false
    case "${chargingSwitch[*]-}" in *" --"*) userLocked=true;; esac

    {
      printf '{"schemaVersion":1,"ts":%s,' "$ts"
      _se_static
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


# For `acca --state`: print the published snapshot. If the daemon isn't running (no
# file yet), generate one on demand; if even that fails, emit a valid error marker so
# the caller always gets parseable JSON (never an empty body that reads as "all 0").
print_state() {
  if [ -f "$TMPDIR/state.json" ]; then
    cat "$TMPDIR/state.json"
  else
    write_state 2>/dev/null || :
    if [ -f "$TMPDIR/state.json" ]; then
      cat "$TMPDIR/state.json"
    else
      echo '{"schemaVersion":1,"error":"daemon-not-running"}'
    fi
  fi
}
