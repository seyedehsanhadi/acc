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
  # rc21: this used to run sed|tr|tr unconditionally -- three forks on EVERY call, and
  # write_state calls it ~19 times per loop, forever. Measured on a Mi A3 at idle, the state
  # export accounted for 1673 of ACC's 2428 forks/min (69%), which is why an idle phone was
  # paying ~52% of one core for a UI feed.
  # The values escaped here come from sysfs and getprop: almost none contain a backslash, a
  # quote or a control character. Test with a case glob (no fork) and return the string
  # untouched when there is nothing to escape. The original pipeline is kept verbatim for the
  # rare value that does need it, so behaviour is identical either way.
  case "${1-}" in
    *\\*|*\"*|*[[:cntrl:]]*) ;;
    *) printf '%s' "${1-}"; return;;
  esac
  # toybox tr does NOT honour octal RANGES like '\000-\010': measured on a Mi A3,
  #   printf 'a\001b' | tr -d '\000-\010\013\014\016-\037'   ->   a\001b
  # so every control byte survived and landed raw in state.json, which is JSON and cannot
  # legally contain them -- one bad getprop value silently produced an export AccA cannot
  # parse. Build the literal set with printf once and pass that; the same probe with an
  # explicit set deletes them correctly. NUL needs no handling: printf '%s' stops at it.
  [ -n "${_seCtl-}" ] || _seCtl=$(printf '\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037')
  printf '%s' "${1-}" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | tr '\t\r\n' '   ' \
    | tr -d "$_seCtl"
}


# rc23c: pull one KEY= value out of uevent text WITHOUT forking.
#
# The nine call sites this replaces each ran
#     $(printf '%s\n' "$ue" | sed -n 's/^KEY=//p' | head -1)
# which is a subshell plus three execs, about four processes, to search a string the shell was
# already holding. write_state is 60-75% of an unplugged loop pass and runs on every pass (the
# uiRefresh=60 gate against a 120s nap is always due), so that was roughly 36 of the ~158 processes
# a Pixel 6a pass costs - a quarter of it, for zero I/O.
#
# Walks the text with parameter expansion only. Result lands in $_ueval rather than being echoed,
# because $(_ue_get ...) would reintroduce the subshell this exists to remove.
#
# Semantics are the pipeline's, exactly: FIRST match wins (head -1), a missing key gives empty, a
# value containing '=' survives whole (${_ueline#*=} strips only the leading KEY=), and a key never
# matches a longer key that starts with it because the glob anchors on "$1=".
_ue_get() {   # $1 = KEY, $2 = uevent text -> $_ueval
  _ueval=
  _uerest=$2
  # The newline is defined HERE, not as a global. With an empty separator the glob *""* matches
  # everything while ${var#*""} removes nothing, so the loop below would spin forever - a hung
  # daemon, which is far worse than the forks this function saves. A local literal cannot go
  # missing. (Caught by t82 executing the extracted function on its own, where a global would not
  # have been in scope: the test hung instead of failing, which is exactly the bug.)
  _uenl='
'
  while [ -n "$_uerest" ]; do
    case "$_uerest" in
      *"$_uenl"*) _ueline=${_uerest%%"$_uenl"*}; _uerest=${_uerest#*"$_uenl"} ;;
      *)          _ueline=$_uerest; _uerest= ;;
    esac
    case "$_ueline" in
      "$1"=*) _ueval=${_ueline#*=}; return 0 ;;
    esac
  done
  return 0
}


# Echo a clean (optionally negative) integer, else "null". Rule S1: a failed/garbage
# read becomes null, never 0.
_se_rd() {
  _seraw=
  { read -r _seraw < "${1:-/nonexistent}"; } 2>/dev/null || :
}

_se_int() {
  local v="${1-}" sign=
  _senum=null
  [ "${#v}" -le 32 ] || return 0
  case "$v" in -*) sign=-; v=${v#-};; +*) v=${v#+};; esac
  case "$v" in ''|*[!0-9]*) return 0;; esac
  while [ "${v#0}" != "$v" ]; do v=${v#0}; done
  v=${v:-0}
  [ "${#v}" -le "${2:-9}" ] || return 0
  [ "$v" != 0 ] || sign=
  _senum=$sign$v
}

_se_num() {
  _se_int "${1-}" 18
  echo "$_senum"
}

# $3 = "bus" when the node is a SUPPLY voltage rather than the pack's. The power_supply class ABI
# says microvolts, and a bus below 1V is noise, not a contract: a Fairphone 5 with nothing plugged
# in reported usb/voltage_now = 18000 (18 mV of noise), the "under 100000 means it is already mV"
# fallback turned that into 18000 mV, and the 1-50V sanity check then blessed "18 V". The exported
# state showed a 15 V input on an unplugged phone, and the re-kick guard reads the same number
# against a 6.5 V latch threshold.
_se_voltage_mv() {
  _se_int "${1-}"
  _semv=null
  [ "$_senum" != null ] || return 0
  case "${2:-}" in
    1000000) _semv=$((_senum / 1000));;
    1000) _semv=$_senum;;
    '') if [ "$_senum" -ge 100000 ]; then _semv=$((_senum / 1000))
        elif [ "${3:-}" = bus ]; then return 0
        else _semv=$_senum; fi;;
    *) return 0;;
  esac
  { [ "$_semv" -ge 1000 ] && [ "$_semv" -le 50000 ]; } || _semv=null
}

_se_temp_decic() {
  _se_int "${1-}"
  _setemp=null
  [ "$_senum" != null ] || return 0
  case "${tempFactor:-}" in
    1) [ "${_senum#-}" -le 200 ] || return 0; _setemp=$((_senum * 10));;
    10) _setemp=$_senum;;
    1000) _setemp=$((_senum / 100));;
    '') if [ "${_senum#-}" -gt 2000 ]; then _setemp=$((_senum / 100)); else _setemp=$_senum; fi;;
    *) return 0;;
  esac
  { [ "$_setemp" -ge -1000 ] && [ "$_setemp" -le 2000 ]; } || _setemp=null
}


# Device + acc-version metadata. Reads the version from module.prop directly, so it is
# correct in EVERY context (daemon, acca front-end, acc CLI) -- accVer/accVerCode are
# only set in acc.sh, which is why the daemon/acca paths printed an empty version.
# Not cached (avoids a stale cache after an update); getprop is cheap.
_se_meta() {
  # rc21: every field below is fixed for the life of this process -- device model, SoC,
  # hardware, Android release, build id, and ACC's own version out of module.prop. Rebuilding
  # it cost 6 getprop forks, 2 sed|head pipes and 13 _se_esc calls EVERY loop, roughly 49
  # forks each time, for a string that never changes. Build it once and reuse it.
  # The original comment argued against caching so an update could not leave a stale version.
  # That still holds: installing ACC restarts the daemon, and this cache lives only in the
  # running process, so the next daemon recomputes it. The one-shot CLI paths call this once
  # anyway, so nothing there changes either.
  # The shell-variable memo below is NOT enough: write_state wraps its whole body in `( set +eu`
  # (state-export.sh, "write_state() { ( set +eu"), and _se_meta is called from inside that
  # SUBSHELL. Every assignment there dies with the subshell, so the memo never survived a single
  # call and the meta block was rebuilt on every publish -- measured on a Mi A3 and a Pixel 6a:
  # _seMetaCache came back EMPTY after write_state, and write_state cost 134-145 forks a call
  # while _se_meta alone costs ~4 amortised when its memo actually works.
  # Back it with a file in TMPDIR so it crosses the subshell boundary, and read it with the
  # `read` builtin (no fork) rather than cat. TMPDIR is tmpfs, wiped every boot, so a module
  # update can never serve a stale version -- the same argument the in-process memo relied on.
  [ -z "${_seMetaCache-}" ] || { printf '%s' "$_seMetaCache"; return; }
  # The memo lives in its OWN subdirectory, not directly in $TMPDIR. write_state's per-writer
  # temps are counted by listing $TMPDIR, so a memo file sitting beside them was counted as an
  # extra temp per process and made "one temp per writer" read double.
  _smd="${TMPDIR:-/dev/.vr25/acc}/.se"
  # INVALIDATE on CONTENT, not mtime. The in-process memo this replaces was implicitly safe: a
  # new process always recomputed, so an upgrade could never serve a stale version. A FILE memo
  # outlives the process, and a module update rewrites module.prop WITHOUT a reboot.
  # An `-nt` mtime test is NOT enough: stat granularity is one second, so a rewrite inside the
  # same second as the memo leaves it looking current and the export keeps the old version.
  # Key the memo filename on the two fields that can change instead, both read with the `read`
  # builtin (no fork), so any edit to either simply lands on a different memo file.
  _sev= _sevc=
  while IFS= read -r _sel || [ -n "${_sel:-}" ]; do
    case "$_sel" in
      version=*)     _sev=${_sel#version=};;
      versionCode=*) _sevc=${_sel#versionCode=};;
    esac
  done < "$execDir/module.prop" 2>/dev/null || :
  # strip anything that cannot sit in a filename
  _sek="${_sev}_${_sevc}"
  case "$_sek" in *[!A-Za-z0-9._-]*) _sek=$(printf '%s' "$_sek" | tr -c 'A-Za-z0-9._-' '_');; esac
  _smf="$_smd/meta.${_sek:-none}"
  if [ -s "$_smf" ]; then
    read -r _seMetaCache < "$_smf" 2>/dev/null || _seMetaCache=
    [ -z "$_seMetaCache" ] || { printf '%s' "$_seMetaCache"; return; }
  fi
  local model man soc hw rel bld fp ver vc
  model=$(getprop ro.product.model 2>/dev/null)
  man=$(getprop ro.product.manufacturer 2>/dev/null)
  soc=$(getprop ro.board.platform 2>/dev/null)
  hw=$(getprop ro.hardware 2>/dev/null)
  rel=$(getprop ro.build.version.release 2>/dev/null)
  bld=$(getprop ro.build.id 2>/dev/null)
  # Already parsed above with the `read` builtin for the memo key, so reuse them instead of
  # paying two more `sed | head` pipes (4 forks) for the same two lines.
  ver=$_sev
  vc=$_sevc
  fp="$(_se_esc "$model")|$(_se_esc "$soc")|$(_se_esc "$hw")|$(_se_esc "$bld")"
  _seMetaCache=$(printf '"device":{"model":"%s","manufacturer":"%s","soc":"%s","hardware":"%s","androidRelease":"%s","buildId":"%s","fingerprint":"%s"},"acc":{"version":"%s","versionCode":"%s"}' \
    "$(_se_esc "$model")" "$(_se_esc "$man")" "$(_se_esc "$soc")" "$(_se_esc "$hw")" \
    "$(_se_esc "$rel")" "$(_se_esc "$bld")" "$fp" "$(_se_esc "$ver")" "$(_se_esc "$vc")")
  # Publish the memo where the next subshell can find it. Written atomically so a concurrent
  # reader never sees a half-file, and best-effort so a read-only TMPDIR just costs the memo.
  # The temp lives in its OWN directory, not beside state.json's per-writer temps: those are
  # counted by name in $TMPDIR to prove write_state uses one temp per process, and a second
  # temp per process here made that count read double.
  # Single redirect, NO temp+rename. An atomic publish would need a per-process temp, and every
  # writer's temp gets counted by the concurrency check that proves write_state uses exactly one
  # temp per process -- mine made that read 16 for 8 writers. A torn read here is harmless: the
  # reader requires a non-empty line and otherwise just recomputes, which is the pre-fix cost.
  [ -d "$_smd" ] || mkdir -p "$_smd" 2>/dev/null || :
  printf '%s\n' "$_seMetaCache" > "$_smf" 2>/dev/null || :
  printf '%s' "$_seMetaCache"
}


# Status source priority: daemon-computed _status > kernel uevent POWER_SUPPLY_STATUS
# (read atomically with current, so they are coherent) > current-sign derivation. $1=current,
# $2=uevent status string. 6.5.1: kernel labels pass through UNMODIFIED (the old
# "Not charging"->Idle remap collided with the battery-idle vocabulary; the semantic
# word now comes from measuredClass only).
_se_status() {
  local s="${_status:-}"
  case "$s" in
    ''|unknown) ;;
    Idle) printf 'Not charging'; return 0;;
    *) printf '%s' "$s"; return 0;;
  esac
  case "${2:-}" in
    Charging|Discharging|Full) printf '%s' "$2"; return 0;;
    Not\ charging) printf 'Not charging'; return 0;;
  esac
  case "${1:-null}" in
    null|'') printf 'unknown';;
    0) printf 'Not charging';;
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
#
# The supply set MUST match present_f()/online_f() in batt-interface.sh. A hardcoded
# usb/ac/dc/mains/pc_port/wireless list missed exactly the phones present() was widened for: a
# fuxi (Xiaomi) has no usb/present at all and shows its charger only as ucsi-source-psy-.../online,
# and the same holds for oplus, glink, mtk and smb charger nodes. On those phones an input-cut
# pause zeroes */online, nothing in the short list reports present, and --state said plugged:false
# with the cable in -- the fuxi drain-while-charging failure surfacing in the app instead of the
# daemon.
#
# The online fallback is filtered for the same reason online_f() filters: a raw */online glob
# includes battery/online, which reads 1 on plenty of phones with nothing attached, so the
# fallback answered "plugged" for every unplugged device that has one.
_SE_SUPPLY='^ac/|^dc/|^mains/|^main-?charger/|^mtk-.*(chg|charger)/|^pc_port/|^smb[0-9]{3}-usb/|^usb/|ucsi.*pmic|oplus.*chg|.*glink.*charg|^wireless/'

# $1 = present|online ; echoes the matching node list, relative to /sys/class/power_supply
_se_supply_nodes() {
  ( cd /sys/class/power_supply 2>/dev/null && ls -1 */"$1" 2>/dev/null | grep -Ei "$_SE_SUPPLY" ) 2>/dev/null || :
}

_se_plugged() {
  local _n= _v=
  for _n in $(_se_supply_nodes present); do
    _v=; { read -r _v < "/sys/class/power_supply/$_n"; } 2>/dev/null || :
    case "$_v" in 1) echo true; return;; esac
  done
  # Nothing claims present, which is NOT proof the cable is out -- present() documents the fuxi
  # case at length. Fall back to online across the SAME filtered set.
  for _n in $(_se_supply_nodes online); do
    _v=; { read -r _v < "/sys/class/power_supply/$_n"; } 2>/dev/null || :
    case "$_v" in 0|'') : ;; *) echo true; return;; esac
  done
  echo false
}

# current units from magnitude: large abs => uA, else mA (works on any kernel)
_se_units() {
  # 6.4.1-rc3: prefer the daemon's calibrated factor. ampFactor_/ampFactor is anchored to the
  # unambiguous voltage/design-capacity scale, so a SMALL instantaneous current can no longer
  # mislabel a uA phone as mA -- the exact dashboard bug (a 4.7 mA idle current read as
  # "4687 mA" because 4687 < 16000 fell to the mA branch). The per-value cutoff stays only as a
  # fallback when no factor is set.
  case "${ampFactor:-${ampFactor_:-}}" in
    1000000) echo uA; return;;
    1000)    echo mA; return;;
    '') :;;
    *) echo unknown; return;;
  esac
  case "${1:-null}" in null|''|0) echo unknown; return;; esac
  local a="${1#-}"
  if [ "$a" -ge 16000 ] 2>/dev/null; then echo uA; else echo unknown; fi
}


# A current in mA, decided by the units the daemon already knows rather than by magnitude.
#
# _se_units had exactly this bug and was fixed in 6.4.1-rc3 by preferring the calibrated ampFactor,
# which is anchored to the unambiguous voltage/design-capacity scale. That fix never reached the two
# call sites that publish currents, and they kept deciding on `>= 100000` alone. A genuine uA reading
# below that cutoff was therefore republished as if it were already mA - exactly 1000x high.
#
# The bad case is the ordinary one, not an edge: a phone HELD AT ITS CHARGE LIMIT draws well under
# 100 mA, so both the current and the watts derived from it were wrong in the state every ACC user
# spends most of their time in. Measured on a Mi A3: usb/input_current_now read 6163 uA (6.16 mA,
# essentially nothing) and the app showed 6.16 A.
#
# Magnitude survives only as the fallback for when no factor has been calibrated yet, which is the
# same precedence _se_units uses.
# FORK-FREE: sets $_sema, never echoes, and never calls out. Written with `echo` + `$( )` first, which
# put a subshell on both call sites plus one more for the units lookup - four forks per pass on a path
# that runs every daemon loop. Measured on a Pixel 6a at 120s: ACC's own forks went 99 -> 671, a 6.8x
# regression against the version this was meant to improve. That is exactly the cost the rest of this
# file was rewritten to remove, and _ue_get above already documents the idiom that avoids it.
#
# The precedence is unchanged: the daemon's calibrated factor first, magnitude only as the fallback for
# a device where no factor has been established yet.
_se_ma() {
  _sema=null
  _se_int "${1:-}"
  [ "$_senum" != null ] || return 0
  [ "${_senum#-}" -le 100000000 ] || return 0
  case "${ampFactor:-${ampFactor_:-}}" in
    1000000) _sema=$(( _senum / 1000 )); return 0;;
    1000)    [ "${_senum#-}" -le 100000 ] || return 0; _sema=$_senum; return 0;;
    '') :;;
    *) return 0;;
  esac
  if [ "${_senum#-}" -ge 100000 ]; then _sema=$(( _senum / 1000 )); elif [ "$_senum" = 0 ]; then _sema=0; fi
}

# polarity: learned from physics, cached with a confirmation streak, status cross-check only
# as bootstrap. The old per-sample status-vs-sign inference was circular on firmware that
# lies during a drain-down (bramble reports "Charging" while deliberately discharging): the
# lying status flipped polarity to inverted, _se_class flipped the sign back, and the honest
# measurement laundered into "charging" - the dashboard showed Charging instead of
# Draining to N%.
# Physics samples, either of:
#   - unplugged with meaningful current (the battery can only be discharging), or
#   - plugged with meaningful current while the state-of-charge MOVES: SoC is coulomb-counted,
#     so a falling % means the pack is net-discharging and a rising % means net-charging, no
#     matter what the (lying) status node claims and immune to voltage dips under load. This
#     calibrates bramble-style liars while plugged, without ever unplugging.
# An earlier build used a falling VOLTAGE as the plugged discharge signal; a voltage dip during
# normal charging then mislearned polarity as inverted (bramble showed "Charging" during a
# drain-down). The cache carries sv=3; any cache with an older/absent sv is discarded + re-learned.
# rc13: the plugged SoC-delta learn now needs a >=2% coulomb move, not >=1%. A 1% move is inside
# fuel-gauge noise -- on a slow charge (curtana / Redmi Note 9S, ~0.6A at low SoC) the FG dipped
# 1% while current was a large POSITIVE, so a genuinely-charging phone laundered a discharge
# sample and confirmed polarity=inverted -> the dashboard showed Draining and negative mA while
# the cable was in (field report). 2% is a real trend a 1% jitter cannot fake; a real drain-down
# still moves many %, so the anti-bramble physics is unchanged. The sv bump discards the wrong
# curtana-style caches, and until a denoised 2% sample re-confirms, the bootstrap status cross-
# check (Charging + positive current -> normal) reads the sign correctly.
# A sample's own physics reading is echoed live (a live ground-truth read is never vetoed by the
# cache); the persistent value needs 2 agreeing samples to confirm and 3 agreeing contradictions
# to flip a confirmed one (self-heal). Plugged status opinions can never touch the cache.
# $1=status $2=cur $3=plugged $4=units $5=capacityPct $6=now_ts
_se_polarity() {
  local pc="${SE_POLCACHE:-${dataDir:-/data/adb/vr25/acc-data}/.se-polarity}"
  local a thr p physics= confirmed= cand= n=0 ac= ats= as= sv= fl=0 cap kv line dirty= cs=
  case "${2:-null}" in null|'') echo unknown; return;; esac
  case "${4:-}" in mA|uA) :;; *) echo unknown; return;; esac
  a="${2#-}"
  [ "${4:-}" = uA ] && thr=30000 || thr=30
  line=$(cat "$pc" 2>/dev/null)
  for kv in $line; do
    case "$kv" in
      sv=*) sv=${kv#*=};;
      confirmed=*) confirmed=${kv#*=};;
      cand=*) cand=${kv#*=};;
      n=*) n=${kv#*=};;
      ac=*) ac=${kv#*=};;
      ats=*) ats=${kv#*=};;
      as=*) as=${kv#*=};;
      fl=*) fl=${kv#*=};;
    esac
  done
  case "$n" in ''|*[!0-9]*) n=0;; esac
  case "$fl" in ''|*[!0-9]*) fl=0;; esac
  # A stale schema is discarded wholesale, and that has to include the flip counter. It did not:
  # fl survived the wipe, so a phone carrying two banked flips re-latched "unstable" on the very
  # first flip after an upgrade, with none of the evidence that latched it the first time.
  if [ -n "$line" ] && [ ".$sv" != .4 ]; then confirmed=; cand=; n=0; ac=; ats=; as=; fl=0; dirty=1; fi
  cap="${5:-}"
  case "$cap" in ''|*[!0-9]*) cap=;; esac
  case "$2" in -*) cs=-;; *) cs=+;; esac
  if [ "$a" -ge "$thr" ] 2>/dev/null; then
    if [ "${3:-}" = false ]; then
      case "$2" in -*) p=normal;; *) p=inverted;; esac
      physics=1
    elif [ -n "$cap" ] && [ -n "${6:-}" ]; then
      # THE LEVEL DELTA AND THE SIGN MUST COME FROM THE SAME STRETCH.
      #
      # The anchor is allowed to be an hour old, but the sign is read from THIS sample. A phone
      # that drained and was then put back on the charger inside that hour therefore measured
      # "the level fell 2" against a sample whose current says "filling", and reported inverted
      # on a phone that is not. Fairphone 5, 2026-09-09: level 88 -> 86 while unplugged, then
      # +2780494 uA the moment the cable went back in. Two of those bank two flips and latch
      # "unstable" for good, which retires the sign - the only arbiter that works on that phone,
      # since its coulomb counter is too coarse to rule and its status word lies.
      #
      # So carry the sign that was live when the anchor was stamped and only rule while it holds.
      # A sign change re-stamps instead, which costs one window and never invents a verdict.
      if [ -n "$ac" ] && [ -n "$ats" ] && [ ".$as" = ".$cs" ] && [ $(( $6 - ats )) -ge 0 ] 2>/dev/null && [ $(( $6 - ats )) -le 3600 ] 2>/dev/null; then
        if [ $(( ac - cap )) -ge 2 ] 2>/dev/null; then
          case "$2" in -*) p=normal;; *) p=inverted;; esac
          physics=1; ac=$cap; ats=$6; as=$cs; dirty=1
        elif [ $(( cap - ac )) -ge 2 ] 2>/dev/null; then
          case "$2" in -*) p=inverted;; *) p=normal;; esac
          physics=1; ac=$cap; ats=$6; as=$cs; dirty=1
        fi
      else
        ac=$cap; ats=$6; as=$cs; dirty=1
      fi
    fi
  fi
  if [ "${3:-}" = false ] && [ -n "$ac" ]; then ac=; ats=; as=; dirty=1; fi
  # "unstable" was a PERMANENT latch with no way back. On a phone latched by the anchor bug above
  # that is terminal: the sign is retired forever and _se_class is left with the status word. Let
  # it heal, but only on evidence stronger than the two flips that set it - five consecutive
  # agreeing physics readings. Hardware whose sign really does follow the engaged charge path
  # (curtana's dual-path PMIC) alternates and never reaches five, so it stays latched.
  if [ -n "$physics" ] && [ ".$confirmed" = .unstable ]; then
    if [ ".$p" = ".$cand" ]; then n=$((n + 1)); else cand=$p; n=1; fi
    dirty=1
    if [ "$n" -ge 5 ]; then confirmed=$p; cand=; n=0; fl=0; fi
  elif [ -n "$physics" ]; then
    if [ ".$p" = ".$confirmed" ]; then
      [ -n "$cand" ] && { cand=; n=0; dirty=1; }
    elif [ ".$p" = ".$cand" ]; then
      n=$((n + 1)); dirty=1
    else
      cand=$p; n=1; dirty=1
    fi
    if [ -z "$confirmed" ] && [ "$n" -ge 2 ]; then confirmed=$p; cand=; n=0; dirty=1; fi
    # rc13: a confirmed polarity that flips TWICE is not noise - it is mode-dependent hardware
    # (dual-path PMIC, sign follows the engaged charge path). Latch "unstable" permanently:
    # from then on classification comes from the coulomb slope / kernel status (_se_class),
    # and per-sample physics is still echoed live below. Never let a cached sign veto ground truth.
    if [ -n "$confirmed" ] && [ ".$p" != ".$confirmed" ] && [ "$n" -ge 3 ]; then
      fl=$((fl + 1))
      if [ $fl -ge 2 ]; then confirmed=unstable; else confirmed=$p; fi
      cand=; n=0; dirty=1
    fi
  fi
  [ -n "$dirty" ] && echo "sv=4 confirmed=$confirmed cand=$cand n=$n ac=$ac ats=$ats as=$as fl=$fl" > "$pc" 2>/dev/null
  if [ -n "$physics" ]; then echo "$p"; return; fi
  if [ -n "$confirmed" ]; then echo "$confirmed"; return; fi
  case "$1" in
    Charging)    case "$2" in -*) echo inverted;; *) echo normal;; esac;;
    Discharging) case "$2" in -*) echo normal;; *) echo inverted;; esac;;
    *) echo unknown;;
  esac
}

_se_polarity_source() {
  local pc="${SE_POLCACHE:-${dataDir:-/data/adb/vr25/acc-data}/.se-polarity}"
  case " $(cat "$pc" 2>/dev/null) " in
    *" confirmed=unstable "*) echo unstable;;
    *" confirmed=normal "*|*" confirmed=inverted "*) echo learned;;
    *) echo bootstrap;;
  esac
}

# rc13: charge_counter slope - sign-convention-FREE charge/discharge ground truth. On dual-path
# PMICs the current sign flips with the charge mode (curtana: 5V trickle path reads positive
# while charging, 9V parallel path reads negative - both verified charging in the field), so any
# single learned polarity mislabels one of the modes. The fuel gauge's coulomb counter has no
# sign convention: rising uAh = the pack is filling, falling = draining. A fresh 3-90s window
# and a 150 uAh floor (>=~100 mA sustained) keep idle holds and counter noise from arbitrating.
# $1 = current charge_counter reading (uAh). Echoes rising|falling|flat|unknown.
_se_ccdir() {
  local cf="${SE_CCCACHE:-${dataDir:-/data/adb/vr25/acc-data}/.se-cc}"
  local cc="$1" p= pts= now=$(date +%s 2>/dev/null) d= age= r=unknown
  _se_int "$cc"; cc=$_senum
  case "$cc" in null|0|-*) rm -f "$cf" 2>/dev/null; echo unknown; return;; esac
  [ -n "$now" ] || { echo unknown; return; }
  [ ! -f "$cf" ] || read -r p pts < "$cf" 2>/dev/null || :
  _se_int "$p"; p=$_senum
  case "$pts" in ''|*[!0-9]*) pts=0;; esac
  [ "${#pts}" -le 10 ] || pts=0
  age=$((now - pts))
  if [ "$p" != null ] && [ "$p" -gt 0 ] && [ "$age" -ge 3 ] && [ "$age" -le 90 ]; then
    d=$(( cc - p ))
    if [ "${d#-}" -gt $((age * 30000)) ]; then r=unknown
    elif [ $d -ge 150 ]; then r=rising
    elif [ $d -le -150 ]; then r=falling
    else r=flat; fi
  fi
  # KEEP THE ANCHOR UNTIL THE COUNTER ACTUALLY MOVES.
  #
  # This used to re-stamp on EVERY call. With the daemon publishing every few seconds that pinned
  # the window at ~4s, and a fuel gauge whose charge_counter updates in coarse steps shows d=0
  # across 4s -- so the answer was "flat" forever and this arbiter could never rule. Fairphone 5,
  # 17:42 bundle: ccDir "flat" while the pack drained at 0.3-0.8 A with the cable in, polarity
  # latched "unstable", and _se_class was left with only the status word this kernel lies with.
  # That is what published "charging" and a wattage on a draining phone.
  #
  # Re-stamp when the value CHANGED (a gauge that steps every call is unaffected, so nothing
  # changes on a phone with a fine counter), or when the window has gone stale past its own 90s
  # ceiling so a dead anchor cannot persist. Otherwise hold it, and let a coarse gauge accumulate
  # a real delta over 10-90s and get its verdict.
  if [ ".$p" = .null ] || [ "$cc" != "$p" ] || [ "$age" -gt 90 ] || [ "$age" -lt 0 ]; then
    echo "$cc $now" > "$cf" 2>/dev/null
  fi
  echo $r
}

# measured class from plug + current (unit-aware idle band), all SoCs. 6.5.1 vocabulary:
# plugged & ~0 -> bypass (battery idle); unplugged & ~0 -> standby; plugged & <0 -> drain
# (ACC or the firmware lowering the battery to the limit); unplugged & <0 -> discharging.
# rc13: precedence is now COULOMB SLOPE ($5, from _se_ccdir) > polarity-signed current > kernel
# status ($6, only when polarity=unstable and the counter is silent). The slope is the only
# signal that stays correct on mode-dependent-sign hardware (see _se_ccdir).
_se_class() {
  local cur="$1" plugged="$2" units="$3" polarity="$4" ccdir="${5:-unknown}" status="${6:-}" a thr
  _se_int "$cur"; cur=$_senum
  case "$cur" in null|'') echo unknown; return;; esac
  case "$units" in mA|uA) :;; *) echo unknown; return;; esac
  a="${cur#-}"
  case "$units" in mA) [ "$a" -le 100000 ];; uA) [ "$a" -le 100000000 ];; esac || { echo unknown; return; }
  [ "$units" = uA ] && thr=30000 || thr=30
  # coulomb arbitration: a moving counter IS the verdict, no sign involved
  if [ "$a" -ge "$thr" ] 2>/dev/null; then
    case "$ccdir" in
      rising)  [ "$plugged" = true ] && { echo charging; return; };;
      falling) { [ "$plugged" = true ] && echo drain || echo discharging; }; return;;
    esac
  fi
  # sign is meaningless on proven mode-flippers: fall back to the kernel status word
  case "$polarity" in normal|inverted|unstable) :;; *) echo unknown; return;; esac
  if [ "$polarity" = unstable ]; then
    if [ "$a" -lt "$thr" ] 2>/dev/null; then
      [ "$plugged" = true ] && echo bypass || echo standby; return
    fi
    case "$status" in
      Charging) echo charging;;
      Discharging) [ "$plugged" = true ] && echo drain || echo discharging;;
      *) [ "$plugged" = true ] && echo unknown || echo discharging;;
    esac
    return
  fi
  # rc9: normalize the current sign by polarity before classifying. On an inverted-polarity
  # device (charging reads negative / discharging positive) the raw sign mislabeled a cut as
  # "charging"; after this flip >0 always means charging, so a cut reads discharging correctly.
  case "$polarity" in inverted) case "$cur" in -*) cur="${cur#-}";; *) cur="-$cur";; esac;; esac
  if [ "$a" -lt "$thr" ] 2>/dev/null; then
    [ "$plugged" = true ] && echo bypass || echo standby; return
  fi
  case "$cur" in
    -*) [ "$plugged" = true ] && echo drain || echo discharging;;
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
    bypass|idle|standby) [ "$sc" = idle ]        && echo trusted || echo measured;;
    charging)            [ "$sc" = charging ]    && echo trusted || echo measured;;
    drain)               [ "$sc" = discharging ] && echo trusted || echo measured;;
    discharging)         [ "$sc" = discharging ] && echo trusted || echo measured;;
    *) echo unverified;;
  esac
}


# Charger-INPUT telemetry. The max-charging-current limit acts on INPUT current on most
# modern platforms (Tensor measured: set 1000 -> input clamps to ~980 mA while the battery
# gets set x Vusb/Vbat x ~0.85 -- ~1.8x on a 9 V charger, ~1x on 5 V). Exposing the live
# input volts/amps lets the front-end show the measured relationship instead of guessing.
# Values normalized to mV/mA by magnitude (uV/uA kernels are >=100000); unreadable -> null
# (rule S1). Probes usb first, then dc/wireless; absent nodes -> nulls, never an error.
_se_bus_mv() {   # $1 = this supply's own mV, $2 = pack mV -> $_sebus (mV, or null)
  local v="${1-}" b="${2-}" n=
  _sebus=$v
  case "$v" in ''|null) _sebus=null; return 0;; esac
  case "$b" in ''|null) return 0;; esac
  # A supply that reports the BATTERY-side voltage under its own voltage_now (a Pixel 6a at 9V PD
  # reads main-charger/voltage_now = 4.03V while the bus is at 8.95V) turns an input current into a
  # charger wattage below what the pack is taking, and consumed_watts goes negative. Anything no
  # higher than the pack is not a bus reading; take one from an online supply that has it.
  [ "$v" -le $(( b + 300 )) ] 2>/dev/null || return 0
  for n in $(online_f 2>/dev/null); do
    [ -f "$n" ] && [ "$(cat "$n" 2>/dev/null)" = 1 ] || continue
    _se_voltage_mv "$(cat "${n%/*}/voltage_now" 2>/dev/null)"
    [ "$_semv" != null ] && [ "$_semv" -gt $(( b + 300 )) ] 2>/dev/null && { _sebus=$_semv; return 0; }
  done
}

_se_input_ma() {
  local raw a node="${2:-}" factor="${inputAmpFactor:-}" cache="${TMPDIR:-/dev}/.iinmicro"
  _sema=null
  _se_int "${1:-}"
  raw=$_senum
  [ "$raw" != null ] || return 0
  a=${raw#-}; node=${node#/sys/class/power_supply/}
  if [ -z "$factor" ]; then
    if [ "$a" -gt 20000 ]; then
      factor=1000000
      [ -z "$node" ] || grep -qxF "$node" "$cache" 2>/dev/null || echo "$node" >> "$cache" 2>/dev/null || :
    elif [ -n "$node" ] && grep -qxF "$node" "$cache" 2>/dev/null; then
      factor=1000000
    elif [ "$a" = 0 ]; then _sema=0; return 0
    else return 0; fi
  fi
  case "$factor" in
    1000) [ "$a" -le 100000 ] || return 0; _sema=$raw;;
    1000000) [ "$a" -le 100000000 ] || return 0; _sema=$((raw / 1000));;
  esac
  _se_icl_guard "$node"
}

# A supply cannot draw more than the limit it negotiated for itself.
#
# Fairphone 5, 2026-09-08 diagnostic: usb/current_now reads 9375000 at 8.98 V - 84 W into a phone
# whose own usb/input_current_limit says 5000000, and whose pack is taking 444 mA. wireless/current_now
# carries the IDENTICAL 9375000 while wireless/online is 0, so the register is mirrored, not measured.
# acc -i printed "power_supply_amps 9.38 / power_supply_watts 84.23 / consumed_watts 82.46".
#
# The limit node is the supply's own statement of what it agreed to carry, so it bounds any reading
# from that supply. 25% of headroom covers a real overshoot during a transient; 187% is not one.
# Rejecting here rather than in each caller covers all three readers at once: acc -i, the exported
# state and the re-kick guard's _iin_ma all convert through this function.
#
# Silent no-op wherever the limit node is absent or does not itself convert (most devices).
_se_icl_guard() {
  local lim raw sup="${1:-}" root="${ACC_PSY:-/sys/class/power_supply}" keep=$_sema
  [ "$_sema" != null ] || return 0
  case "$sup" in ''|*input_current_limit) return 0;; esac
  sup=${sup%/*}
  [ -n "$sup" ] || return 0
  _se_rd "$root/$sup/input_current_limit"; raw=$_seraw
  [ -n "$raw" ] || return 0
  _se_input_ma "$raw" "$sup/input_current_limit"; lim=$_sema
  _sema=$keep
  case "$lim" in null|0|-*) return 0;; esac
  [ "${keep#-}" -le $(( lim + lim / 4 )) ] 2>/dev/null || _sema=null
}

# Is ANY supply on this phone reporting itself online? On a OnePlus 8 Pro charging from the wall
# the Mains node carries that flag while the USB node carries the measurement:
#     ac/online=1   usb/present=1   usb/online=0   usb/voltage_now=4843728
# rc24 read usb/voltage_now unconditionally and published 4843 mV. rc25 made online=1 a condition
# of even looking at a supply, which is right for the mirrored register it was written for and
# wrong here: it reports nothing at all on a phone that is plainly charging.
_se_any_online() {
  local _s _v root="${ACC_PSY:-/sys/class/power_supply}"
  for _s in "$root"/*/online; do
    [ -r "$_s" ] || continue
    _se_rd "$_s"
    [ ".$_seraw" = .1 ] && return 0
  done
  return 1
}

_se_input() {
  local supply cf v=null c=null ca pres raw root="${ACC_PSY:-/sys/class/power_supply}"
  for supply in usb dc wireless main-charger main; do
    # An unreadable or missing online node used to pass this test ("" != 0), so a supply that
    # never reported being online could still supply the exported input voltage and current.
    # _se_rd, not a bare read: a node with no trailing newline hands read a non-zero status WITH
    # the value already in the variable, and "|| ca=" then threw a valid 1 away.
    _se_rd "$root/$supply/online"; ca=$_seraw
    # Its own online flag first. Failing that, a supply that says it is PRESENT while some other
    # supply on the phone says it is online is the split-role arrangement above, not a stale
    # register: the Fairphone 5 case this gate exists for reports neither.
    if [ ".$ca" != .1 ]; then
      _se_rd "$root/$supply/present"; pres=$_seraw
      { [ ".$pres" = .1 ] && _se_any_online; } || continue
    fi
    for cf in "$root/$supply/input_current_now" "$root/$supply/current_now"; do
      _se_rd "$cf"; raw=$_seraw
      [ -n "$raw" ] || continue
      _se_input_ma "$raw" "$supply/${cf##*/}"; c=$_sema
      [ "$c" != null ] || continue
      break
    done
    # An online supply's bus voltage is worth reporting even when none of its current nodes
    # produced a usable reading - a Fairphone 5 whose usb/current_now is a mirrored register still
    # publishes a real 8.98 V. Dropping the whole supply here would have replaced one wrong number
    # with two missing ones.
    _se_rd "$root/$supply/voltage_now"; raw=$_seraw
    _se_voltage_mv "$raw" "" bus; v=$_semv
    [ "$v" != null ] || [ "$c" != null ] || continue
    printf '"input":{"voltageMv":%s,"currentMa":%s}' "$v" "$c"
    return
  done
  printf '"input":{"voltageMv":null,"currentMa":null}'
}

# Zero a current reading whose supply is offline. Split out so it can be exercised without a
# charger: $1 = the supply's online flag (anything non-numeric counts as online, since a device
# with no online node has never been gated), $2 = the mA reading. Sets $_segma.
_se_gate_ma() {
  _segma="$2"
  case "$1" in 0) [ "$2" != null ] && _segma=0;; esac
}


# Charge-speed classification, physics-only (research-verified 2026-07: every proprietary
# fast-charge system above 45W -- SUPERVOOC, HyperCharge, Huawei SCP -- has NO standard sysfs
# protocol label, so watts = input V x A is the ONLY universal signal; vendor names are never
# needed to classify). Bands: <7W slow, <18W standard, <45W fast, <90W superfast, else hyper
# (QC4 tops at ~27-28W not 100W; PD PPS SPR caps at 100W; PD3.1 EPR reaches 240W - all verified
# against primary sources + teardowns, do not replace with marketing numbers).
# Reason when charging slower than the class suggests, priority order:
#   voltage_limit (max_charging_voltage sits at or below the pack's own voltage, so the charger
#   has nothing to push against), user_limit (max_charging_current is set AND the measured current
#   is within 15% of it), thermal (battery at/above 42.0 C), taper (charge_type says Taper/Trickle,
#   or SOC >= 95).
# Read-only; approx=true marks the battery-side V x A fallback (always <= input watts, so the
# class can only UNDER-state, never inflate). Args: $1=inMv $2=inMa $3=battCurRaw $4=battVoltRaw
# $5=status $6=tempDeciC $7=capacityPct $8=measuredClass
_se_watts() {
  local v a q
  _sew=null
  _se_int "$1"; v=$_senum
  _se_int "$2"; a=${_senum#-}
  case "$v:$a" in *null*|-*) return 0;; esac
  [ "$v" -ge 1000 ] && [ "$v" -le 50000 ] && [ "$a" -le 100000 ] || return 0
  q=$((v * (a / 1000) + v * (a % 1000) / 1000))
  _sew=$((q / 1000))
  if [ $((q % 1000)) -ne 0 ]; then
    q=00$((q % 1000)); q=${q#"${q%???}"}
    _sew=$_sew.$q
  fi
}

# Last all-digit field of a config entry. max_charging_current is usually a bare number but may
# carry a node in front of it ("battery/constant_charge_current 1800"), and the value is always
# last. Sets $_secfgn to that number, or to null when there is nothing numeric to take.
_se_cfg_num() {
  local _f
  _secfgn=null
  for _f in $1; do
    case "$_f" in ''|*[!0-9]*) ;; *) _secfgn=$_f;; esac
  done
}

# True when a current cap is close enough to the measured current to be what is holding it there.
# Either side may be the one the cap applies to: on a Tensor phone max_charging_current is the
# CHARGER-INPUT current, on a Qualcomm phone it is the battery-side current, and ACC does not
# know which from the config alone. 85% is the band; a cap the current is nowhere near is not an
# explanation for anything. Args: $1=cap mA $2=battery current raw $3=input mA.
_se_cap_binds() {
  local _cap="$1" _bc="$2" _in="$3" _bm _thr
  case "$_cap" in ''|*[!0-9]*|0) return 1;; esac
  _thr=$(( _cap * 85 / 100 ))
  if [ "$_in" != null ] && [ "${_in#-}" -ge "$_thr" ] 2>/dev/null; then return 0; fi
  if [ "$_bc" != null ]; then
    _se_ma "${_bc#-}"; _bm=$_sema
    [ "$_bm" != null ] && [ "$_bm" -ge "$_thr" ] 2>/dev/null && return 0
  fi
  return 1
}

_se_charge() {
  local inmv="$1" inma="$2" bcur="$3" bvolt="$4" st="$5" tdc="$6" cap="$7" mcls="${8:-}"
  local w=null cls=null why=null approx=false bma bmv ct filling=false _sevlim _secap _sevnow
  # Input power is MEASURED, and it is real whether or not the battery is taking it. While ACC
  # holds an input-cut switch the charger still runs the phone -- a Mi A3 held at its pause level
  # was drawing 1797 mA from the wall with the battery at -170 mA -- but the whole block used to
  # sit behind `status = Charging`, so watts read null and every consumer concluded "no charger".
  # Compute it first and unconditionally; only the CLASS stays charging-only, because slow/fast
  # describes how quickly the battery fills and means nothing when it is not filling. A non-null
  # watts with a null class is therefore the honest reading of a hold: power in, none of it to the
  # battery. The battery-side fallback below stays inside the charging branch -- it is a proxy for
  # input power, and during a hold the battery current is flowing the wrong way to stand in for it.
  # The 50 mA floor here hid a measurement it already had: at 30 mA in, the row printed
  # "5.1 V - 0.03 A - (nothing) W input", a current shown beside a wattage refused. Anything above
  # zero is a reading and multiplies out fine; a genuine zero and an unreadable node both stay
  # null, which is the distinction the floor was really there to protect.
  if [ "$inmv" != null ] && [ "$inma" != null ] && [ "$inmv" -gt 1000 ] 2>/dev/null && [ "${inma#-}" -gt 0 ] 2>/dev/null; then
    _se_watts "$inmv" "$inma"; w=$_sew
  fi
  # WHICH WAY THE CHARGE IS GOING IS ALREADY DECIDED, and not by this node.
  #
  # Fairphone 5, 2026-09-09: the kernel held status=Charging with no pause anywhere while the pack
  # left at -1329669 uA and the SoC walked 23 -> 21%. usb/current_now is a mirrored register there
  # and the ICL guard rightly drops it, so there was no input reading to beat the fallback to it --
  # and the fallback took ${bcur#-}, threw the minus away, and published
  # "charge":{"watts":4.708,"class":"slow"} for a phone that was emptying. AccA printed "From
  # charger: ~0.87 W or more (Slow charge)" beside its own "Draining" row, which is the flapping
  # the owner reported.
  #
  # The sign alone is not the answer either: on an inverted-polarity phone a charging pack reads
  # negative, which is what the strip was there for. _se_class has already arbitrated all of it --
  # coulomb slope first, then polarity, then the status word as the last resort -- so the fallback
  # takes that verdict instead of re-deriving a worse one from the single signal known to lie.
  case "$mcls" in
    charging) filling=true;;
    '') [ "$st" = "Charging" ] && filling=true;;
  esac
  if $filling; then
    if [ "$w" = null ] && [ "$bcur" != null ] && [ "$bvolt" != null ]; then
      _se_ma "${bcur#-}"; bma=$_sema
      _se_voltage_mv "$bvolt"; bmv=$_semv
      if [ "$bma" -gt 50 ] 2>/dev/null && [ "$bmv" -gt 1000 ] 2>/dev/null; then
        _se_watts "$bmv" "$bma"; w=$_sew; approx=true
      fi
    fi
    if [ "$w" != null ]; then
      if   [ "${w%.*}" -lt 7 ];  then cls='"slow"'
      elif [ "${w%.*}" -lt 18 ]; then cls='"standard"'
      elif [ "${w%.*}" -lt 45 ]; then cls='"fast"'
      elif [ "${w%.*}" -lt 90 ]; then cls='"superfast"'
      else cls='"hyper"'; fi
      # WHY IS NOT "WHICH SETTING EXISTS", IT IS "WHICH SETTING BINDS".
      #
      # user_limit used to fire on the mere PRESENCE of max_charging_current, and it was tested
      # first, so a phone with any current cap could never report thermal or taper - and a
      # OnePlus 8 Pro capped at 1800 mA while drawing 181 mA was told its cap was the reason,
      # when the real block was a 4000 mV ceiling on a pack already resting at 4008 mV. There was
      # no reason code for a voltage ceiling at all. Both are fixed here: the ceiling gets its
      # own code and is tested first because it blocks charging outright, and the cap has to be
      # anywhere near the measured current before it may take the blame.
      _se_cfg_num "${maxChargingVoltage[*]-}"; _sevlim=$_secfgn
      _se_cfg_num "${maxChargingCurrent[*]-}"; _secap=$_secfgn
      _se_voltage_mv "$bvolt"; _sevnow=$_semv
      if [ "$_sevlim" != null ] && [ "$_sevnow" != null ]       && [ "$_sevnow" -ge $(( _sevlim - 20 )) ] 2>/dev/null; then why='"voltage_limit"'
      elif [ "$_secap" != null ] && _se_cap_binds "$_secap" "$bcur" "$inma"; then why='"user_limit"'
      elif [ "$tdc" != null ] && [ "$tdc" -ge 420 ] 2>/dev/null; then why='"thermal"'
      else
        ct=; { read -r ct < /sys/class/power_supply/battery/charge_type; } 2>/dev/null || :
        case "$ct" in Taper|taper|Trickle|trickle) why='"taper"';; *)
          [ "$cap" != null ] && [ "$cap" -ge 95 ] 2>/dev/null && why='"taper"';; esac
      fi
    fi
  fi
  printf '"charge":{"watts":%s,"class":%s,"reason":%s,"approx":%s}' "$w" "$cls" "$why" "$approx"
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
  # Warm the device/acc memo HERE, in write_state's own scope. The body below is a ( ) subshell,
  # so a $_seMetaCache assigned inside it dies with every call and the meta block was rebuilt
  # (6 getprop + 13 escapes) on EVERY daemon loop. Assigning it out here lets the subshell inherit
  # it, so the block really is built once per process -- with no file memo and no mkdir. The inner
  # `set +eu` keeps a failing getprop or an unreadable module.prop from tripping the daemon's
  # set -eu; the trailing `|| :` does the same for the assignment itself.
  [ -n "${_seMetaCache-}" ] || _seMetaCache=$( set +eu; _se_meta 2>/dev/null ) || :
  ( set +eu
    local f="$TMPDIR/state.json"
    # PER-WRITER temp name. There is never only one writer: the daemon refreshes
    # state on its loop, and every `acc --state` / `acca --state` call refreshes
    # it too, so a front-end polling while the daemon ticks means two builds are
    # in flight at once. With a single shared temp name the second writer
    # truncates the first one's file mid-build, and the first one's `mv` then
    # publishes a half-written body - observed as JSON with an empty ",," where
    # the device object should be, or simply cut off with unbalanced braces.
    # A name per process plus the existing atomic rename makes each writer's
    # publish all-or-nothing.
    local t="$TMPDIR/.state.json.$$.tmp"
    local lvl volt cur tmp status ts userLocked
    local ue ue_st ue_cur ue_cap ue_volt ue_temp _cok _cv _uefile="${currFile%/*}/uevent"

    # ONE atomic read of battery/uevent so status+current+... are coherent (separate cats can
    # straddle a state change -- the root reason statusTrust was perpetually "unknown"). Fall
    # back to the individual nodes for any field the uevent does not carry.
    # 6.5.1 (D3): three atomic uevent samples, classify on the MEDIAN-current sample kept
    # WHOLE (status+current stay a coherent pair) -- one transient spike (resume pulse,
    # screen toggle) no longer flaps the measured class between ticks.
    _ue1=$(cat "$_uefile" 2>/dev/null)
    sleep 0.15 2>/dev/null || :
    _ue2=$(cat "$_uefile" 2>/dev/null)
    sleep 0.15 2>/dev/null || :
    _ue3=$(cat "$_uefile" 2>/dev/null)
    _ue_get POWER_SUPPLY_CURRENT_NOW "$_ue1"; _se_int "$_ueval"; _c1=$_senum
    _ue_get POWER_SUPPLY_CURRENT_NOW "$_ue2"; _se_int "$_ueval"; _c2=$_senum
    _ue_get POWER_SUPPLY_CURRENT_NOW "$_ue3"; _se_int "$_ueval"; _c3=$_senum
    ue=$_ue2
    # A non-numeric CURRENT_NOW must leave sample 2 selected WHOLE. `[ a -ge b ]` looks like it
    # errors out on garbage and the 2>/dev/null suffix looks like it handles that, but ksh/mksh
    # ARITHMETICALLY evaluate both operands, where a bare word is a variable name and an unset
    # one is 0 -- so "abc" -ge "def" is 0 -ge 0, quietly TRUE, and the picker chose sample 1
    # while current/capacity/temperature all still came from sample 2. That is precisely the
    # split-sample incoherence this median exists to prevent, and it is reachable on any
    # firmware whose uevent emits a blank or non-integer current. Worse, a value that happens to
    # name a live shell variable would compare against THAT variable's contents. Gate on the
    # values being real integers first; the old -n checks are subsumed (empty is not numeric).
    _cok=true
    for _cv in "$_c1" "$_c2" "$_c3"; do
      case "${_cv#-}" in ''|*[!0-9]*) _cok=false;; esac
    done
    if $_cok; then
      if { [ "$_c1" -ge "$_c2" ] && [ "$_c1" -le "$_c3" ]; } \
        || { [ "$_c1" -le "$_c2" ] && [ "$_c1" -ge "$_c3" ]; }; then ue=$_ue1
      elif { [ "$_c3" -ge "$_c1" ] && [ "$_c3" -le "$_c2" ]; } \
        || { [ "$_c3" -le "$_c1" ] && [ "$_c3" -ge "$_c2" ]; }; then ue=$_ue3
      fi
    fi
    _ue_get POWER_SUPPLY_STATUS         "$ue"; ue_st=$_ueval
    _ue_get POWER_SUPPLY_CURRENT_NOW    "$ue"; ue_cur=$_ueval
    _ue_get POWER_SUPPLY_CAPACITY       "$ue"; ue_cap=$_ueval
    _ue_get POWER_SUPPLY_VOLTAGE_NOW    "$ue"; ue_volt=$_ueval
    _ue_get POWER_SUPPLY_TEMP           "$ue"; ue_temp=$_ueval
    _ue_get POWER_SUPPLY_CHARGE_COUNTER "$ue"; ue_cc=$_ueval
    [ -n "$ue_cc" ] || ue_cc=$(cat "${battCapacity%capacity}charge_counter" 2>/dev/null)

    lvl=$(batt_cap 2>/dev/null)
    _se_int "$lvl"; lvl=$_senum
    { [ "$lvl" != null ] && [ "$lvl" -ge 0 ] && [ "$lvl" -le 100 ]; } || lvl=null
    _se_rd "$voltNow"; ue_volt=$_seraw
    _se_voltage_mv "$ue_volt" "${voltFactor:-}"; volt=$_semv
    case "$currFile" in */current_now) [ -n "$ue_cur" ] || ue_cur=$(current_now);; *) ue_cur=$(current_now);; esac
    _se_int "$ue_cur"; cur=$_senum
    tmp=$(temperature_now)
    status=$(_se_status "$cur" "$ue_st")
    ts=$(_se_num "$(date +%s 2>/dev/null)")
    # The " --" suffix is written by TWO different actors: the user (set-prop.sh, via the
    # picker / acc -ss N / AccA Apply&Lock) AND the daemon itself, which appends it in
    # cycle_switches after a strict-verified settle so a non-empty switch stops the re-probe
    # sawtooth (misc-functions.sh, "~40 toggles in 21 min at 91%"). Deriving userLocked from
    # that text therefore reported an automatic settle as a manual pin, and AccA showed its
    # manual-lock label for a switch the user never chose. write-config.sh already keeps the
    # unambiguous answer: .user-locked is touched ONLY when isAccd is false, i.e. only for a
    # real user write. Read that instead. Kept as an if so the test never returns nonzero
    # under the daemon's set -e.
    userLocked=false
    if [ -f "${dataDir:-/data/adb/vr25/acc-data}/.user-locked" ]; then userLocked=true; fi

    local plugged units polarity psrc mclass conf trust ccdir
    plugged=$(_se_plugged)
    units=$(_se_units "$cur")
    polarity=$(_se_polarity "$status" "$cur" "$plugged" "$units" "$lvl" "$ts")
    psrc=$(_se_polarity_source)
    ccdir=$(_se_ccdir "$ue_cc")
    mclass=$(_se_class "$cur" "$plugged" "$units" "$polarity" "$ccdir" "$status")
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
      local inj invm inim
      inj=$(_se_input)
      invm=${inj#*voltageMv\":}; invm=${invm%%,*}
      inim=${inj#*currentMa\":}; inim=${inim%%\}*}
      printf ',%s' "$inj"
      printf ',%s' "$(_se_charge "$invm" "$inim" "$cur" "$volt" "$status" "$tmp" "$lvl" "$mclass")"
      printf ',%s' "$(_se_native)"
      printf ',"sensing":{"currentUnits":"%s","polarity":"%s","polaritySource":"%s","statusTrust":"%s","confidence":"%s","ccDir":"%s"}' \
        "$units" "$polarity" "$psrc" "$trust" "$conf" "$ccdir"
      printf ',"switch":{"locked":"%s","userLocked":%s,"measuredClass":"%s"}' \
        "$(_se_esc "${chargingSwitch[*]-}")" "$userLocked" "$mclass"
      printf '}\n'
    } > "$t" 2>/dev/null && mv -f "$t" "$f" 2>/dev/null
    # never leave a half-built temp behind if the build or the rename failed
    rm -f "$t" 2>/dev/null || :
  ) 2>/dev/null || :
}


# For `acca --state`: ALWAYS refresh first so an interactive call is never stale (the old
# cat-if-exists behaviour froze the snapshot once a file existed), then print it. If the
# refresh somehow produced nothing, emit a valid error marker so the caller always gets
# parseable JSON -- never an empty body that reads as "all 0".
print_state() {
  # Discard write_state's STDOUT too, not just stderr. It builds into its own temp and should
  # print nothing, but anything it does leak lands ahead of the JSON on this path: measured a
  # bare leading newline, so `acc -j` emitted 3 lines where AccA expects exactly one and a
  # strict JSON parser sees a blank first line.
  write_state >/dev/null 2>&1 || :
  if [ -f "$TMPDIR/state.json" ]; then
    cat "$TMPDIR/state.json"
  else
    echo '{"schemaVersion":1,"error":"daemon-not-running"}'
  fi
}
