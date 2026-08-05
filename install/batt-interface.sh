idle_discharging() {
  if [ ${curNow#-} -le $idleThreshold ]; then
    _status=Idle
    return 0
  fi
  case "${_DPOL-}" in
    +) [ $curNow -ge 0 ] && _status=Discharging || _status=Charging;;
    -) [ $curNow -lt 0 ] && _status=Discharging || _status=Charging;;
    *) [ "${curThen:-null}" = null ] || {
          eq "$curThen,$curNow" "-*,[0-9]*|[0-9]*,-*" && _status=Discharging || _status=Charging
       };;
  esac
  # rc13: COULOMB ARBITRATION. The sign verdict above assumes ONE polarity per device, but on
  # dual-path PMICs the current sign FLIPS with the charge mode (curtana / Redmi Note 9S: the
  # master-only 5V trickle path reads POSITIVE while charging, the parallel 9V fast path reads
  # NEGATIVE while charging - field-verified in back-to-back forensics runs). Whatever single
  # _DPOL is latched is then wrong in the other mode: the daemon believed Discharging while the
  # pack was filling, the resume watchdog churned good switches, and acca -i showed "Draining"
  # with the cable in. The fuel gauge's charge_counter (uAh) is sign-convention-free ground
  # truth: if it ROSE beyond noise across the sample window the pack IS charging, if it FELL the
  # pack IS discharging, no matter what the signed current claims. Only a fresh (3-90s) window
  # arbitrates; a flat counter (idle hold, or too slow to tell) leaves the sign verdict alone,
  # so bypass/idle behavior is unchanged. When the counter contradicts the sign twice, the
  # polarity is provably mode-dependent -> drop a marker so set_dp stops re-latch churn.
  local _cc=$(cc_now) _ccp= _ccts= _ccnow=$(date +%s 2>/dev/null) _ccd= _ccraw= _sv=$_status
  if [ "${_cc:-0}" -gt 0 ] 2>/dev/null && [ -n "$_ccnow" ]; then
    [ ! -f $TMPDIR/.cc_then ] || read -r _ccp _ccts < $TMPDIR/.cc_then 2>/dev/null || :
    if [ "${_ccp:-0}" -gt 0 ] 2>/dev/null && [ $(( _ccnow - ${_ccts:-0} )) -ge 3 ] 2>/dev/null \
      && [ $(( _ccnow - ${_ccts:-0} )) -le 90 ] 2>/dev/null; then
      # rc22: _ccd is set ONLY when the counter actually ruled. It used to be assigned the raw
      # delta unconditionally, including 0, and the kernel tie-break below stands down whenever
      # _ccd is non-empty -- it reads "the counter already decided this". A flat counter set
      # _ccd=0, which is not a verdict, and that silently disabled the tie-break.
      # On a gauge too coarse to move in the sample window the delta is ALWAYS 0, so both
      # arbitrators stood down together and an unchallenged (possibly wrong) current sign decided
      # everything. Device-proven on a Mi A3: charge_counter flat across 120s, _DPOL latched to the
      # wrong sign, `acc -i` reporting Discharging with the kernel saying Charging, and therefore
      # is_charging false and EVERY limit skipped -- pack at 32C against max_temp 30 and charging
      # not cut. Same signature as the sweet field report at 41C against max_temp 40.
      _ccraw=$(( _cc - _ccp ))
      if [ $_ccraw -ge 150 ]; then _status=Charging; _ccd=$_ccraw
      elif [ $_ccraw -le -150 ]; then _status=Discharging; _ccd=$_ccraw; fi
      [ "$_sv" = "$_status" ] || {
        local _fl=$(cat $TMPDIR/.dpol_flips 2>/dev/null || echo 0)
        case "$_fl" in ''|*[!0-9]*) _fl=0;; esac
        _fl=$((_fl + 1)); echo $_fl > $TMPDIR/.dpol_flips 2>/dev/null || :
        [ $_fl -lt 2 ] || touch $TMPDIR/.dpol_unstable 2>/dev/null || :
      }
    fi
    echo "$_cc $_ccnow" > $TMPDIR/.cc_then 2>/dev/null || :
  fi

  # rc21 SIGN-VS-KERNEL TIE-BREAK. The coulomb block above is the good arbiter, but it only
  # rules when it has a fresh 3-90s window AND a >=150uAh delta. Outside that -- first loop
  # after a start, a window stretched past 90s by deep sleep, a slow charge -- whatever the
  # sign said stands unchallenged. On a phone whose current reads NEGATIVE while charging that
  # verdict is "Discharging" with the cable in, and every charging limit then goes blind:
  # max_temp and pause_capacity are only evaluated while ACC believes it is charging. Field
  # report on a sweet (Redmi Note 10 Pro): battery/status=Charging, charge_type=Fast,
  # USB_HVDCP_3 online, current_now=-2410000, and `acc -i` said Discharging at 41C with
  # max_temp=40 -- charging never paused.
  #
  # So when the counter could not rule, fall back to the node the kernel itself publishes.
  # Deliberately ONE-WAY: only Discharging -> Charging. Believing "discharging" while the pack
  # fills is the dangerous error (limits blind, overcharge); believing "charging" while it
  # drains is harmless (ACC pauses something that is not happening). battStatusWorkaround
  # exists because some kernels lie about status, so this never overrides toward Discharging
  # and never touches an Idle verdict -- it only refuses to ignore a kernel that is actively
  # claiming Charging while we guessed the opposite.
  if [ "$_status" = Discharging ] && [ "${_kstatus-}" = Charging ] && [ -z "${_ccd-}" ]; then
    _status=Charging
  fi

  # rc22 PHYSICAL GATE, and it is last on purpose: nothing above may leave "Charging" standing on a
  # phone with no cable attached. Every arbiter above is an inference -- a current sign read through
  # a cached polarity, a coulomb window that needs the pack to move, a status node that some kernels
  # lie about. This one is a fact, and it needs none of them.
  #
  # Measured on BOTH test phones, unplugged, with OPPOSITE current signs and OPPOSITE cached
  # polarities, and both said Charging: a Mi A3 draining 400-980mA reading POSITIVE with _DPOL=-,
  # and a Pixel 6a draining 450mA reading NEGATIVE with _DPOL=+. The Pixel got it right on exactly
  # the samples where charge_counter moved enough to rule and wrong on the rest; the A3's counter
  # never moved at all, so it was wrong every time. The tie-break above cannot help here -- it is
  # deliberately one-way, Discharging to Charging, so a wrong "Charging" has nothing to correct it.
  #
  # present() is the right primitive rather than online(): an input-cut switch (input_suspend,
  # current_max 0) drives */online to 0 while the cable is still attached, and gating on online
  # would then declare a paused-but-plugged phone unplugged. present stays 1 there, so ACC's own
  # pause is untouched and only a genuinely detached cable trips this.
  if [ "$_status" = Charging ] && ! present 2>/dev/null; then
    _status=Discharging
  fi
}


not_charging() {

  local i=
  local j=
  local sw=
  local _STI=${_STI:-35} # switch test iterations
  local switch=${flip-}; flip=
  local curThen=$(cat $curThen)
  local chargingSwitch="${chargingSwitch[*]-}"
  local idleThreshold=${idleThreshold:-10}
  local battStatusOverride="${battStatusOverride-}"
  local battStatusWorkaround=${battStatusWorkaround-}
  local wsLog=$dataDir/logs/working-switches.log

  [[ "$chargingSwitch" = *\ -- ]] && chargingSwitch="${chargingSwitch% --}" || battStatusOverride=

  case "$currFile" in
    */current_now|*/?attery?verage?urrent) [ ${ampFactor:-$ampFactor_} -eq 1000 ] || idleThreshold=${idleThreshold}000;;
    *) battStatusWorkaround=false;;
  esac

  if [ -z "${battStatusOverride-}" ] && [ -n "$switch" ]; then
    for i in $(seq $_STI); do
      if [ "$switch" = off ]; then
        ! status ${1-} || {
          sw=$(grep "\[[id]\] $chargingSwitch" $wsLog 2>/dev/null || :)
          while :; do
            j=$(echo $_status | sed -E 's/^(.).*/\1/; s/I/i/; s/D/d/')
            if [ -n "$sw" ]; then
              [[ "$sw" = \[$j\]* ]] || { sed -i "\|$chargingSwitch|d" $wsLog; sw=; continue; }
            else
              printf "[$j] $chargingSwitch" >> $wsLog
              case "$chargingSwitch" in
                # A current_cmd entry takes no {mcc} tag, but it still needs the newline every
                # other arm emits: the bare `||` skipped the echo entirely, so the next switch
                # logged merged onto the same line and both became unparseable to `acc -ss::`.
                *current*) if [[ "$chargingSwitch" = *current_cmd* ]]; then echo; else echo " {mcc}"; fi;;
                *control_limit_max*|*siop_level*|*temp_level*) echo " {tl}";;
                *voltage*) echo " {mcv}";;
                *) echo;;
              esac >> $wsLog
            fi
            break
          done
          return 0
        }
      else
        status ${1-} || return 1
      fi
      [ ! -f $TMPDIR/.nowrite ] || { rm $TMPDIR/.nowrite 2>/dev/null || :; break; }
      [ $i = $_STI ] || sleep 1
    done
    [ "$switch" = on ] || return 1
  else
    status ${1-}
  fi
}


online() {
  local i= seen=false
  for i in $(online_f); do
    seen=true
    grep -q 0 $i || return 0
  done
  # rc5 (#6): if NO */online node matched the regex (a device with an unlisted charger-node
  # name), do NOT blindly report offline -- that silently breaks generic_rearm/native_unlatch,
  # the resume flip-ON gate, and enters idle-nap while plugged. Defer to the charge status.
  $seen && return 1 || [ "$(read_status)" = Charging ]
}


online_f() {
  ls -1 */online | grep -Ei '^ac/|^dc/|^mains/|^main-?charger/|^mtk\-.*(chg|charger)/|^pc_port/|^smb[0-9]{3}\-usb/|^usb/|ucsi.*pmic|oplus.*chg|.*glink.*charg|^wireless/' || :
}


# rc(6.4): "is the cable physically attached" -- distinct from online() ("is the
# charge path energized"). An input-cut switch (input_suspend / current_max 0)
# drives */online to 0 WHILE the cable is still plugged, which blinded the breach
# watchdog (it read online=0 -> "unplugged" -> cleared the breach). POWER_SUPPLY_PRESENT
# stays 1 across an input cut. Falls back to online() on kernels with no present node.
present_f() {
  # rc19 (standby): the supply list is fixed hardware -- compute the ls|grep once per process
  # and reuse. present() runs every second inside the idle naps; two forks per call added up
  # to tens of thousands of spawns a night. Power-supply entries exist from boot, so a
  # process-lifetime cache cannot miss one.
  [ -n "${_presentF+x}" ] || _presentF=$(ls -1 */present 2>/dev/null | grep -Ei '^ac/|^dc/|^mains/|^main-?charger/|^mtk\-.*(chg|charger)/|^pc_port/|^smb[0-9]{3}\-usb/|^usb/|ucsi.*pmic|oplus.*chg|.*glink.*charg|^wireless/' || :)
  printf '%s\n' "$_presentF"
}

present() {
  local i= v= seen=false
  [ -n "${_presentF+x}" ] || present_f >/dev/null
  for i in $_presentF; do
    seen=true
    v=
    { read -r v < $i; } 2>/dev/null || :
    case "$v" in 1) return 0;; esac
  done
  # no usable present node -> defer to online (a path that is energized is plugged)
  $seen && return 1 || online
}


read_status() {
  local status="$(cat $battStatus)"
  case "$status" in
    Cmd*discharging) printf Discharging;;
    Charging|Discharging) printf %s $status;;
    Not?charging) printf Idle;;
    *) printf Discharging;;
  esac
}


set_temp_level() {
  local f=$TMPDIR/.tl-custom
  local a=
  local b=battery/siop_level
  local l=${1:-${tempLevel-}}
  local _t=
  [ -n "$l" ] || return 0
  [[ $l -eq 0 && ! -f $f ]] && return 0 || :
  # IDEMPOTENT (fast charge): write a level/limit node ONLY when its value must change. These are
  # raw writes (not via write()), and charge_control_limit_max / siop_level re-trigger AICL / the
  # charge FSM on every write, so re-asserting the same value each loop while warm throttles fast
  # charge continuously. Read-before-write leaves a healthy charge undisturbed and still re-arms
  # the instant the firmware drifts the node off target.
  if [ -f $b ]; then
    _t=$((100 - $l)); [ "$(cat $b 2>/dev/null)" = "$_t" ] || { chmod a+w $b && echo $_t > $b; } || :
  else
    for a in */num_system_temp*levels; do
      b=$(echo $a | sed 's/\/num_/\//; s/s$//')
      if [ ! -f $a ] || [ ! -f $b ]; then
        continue
      fi
      _t=$(( ($(cat $a) * l) / 100 )); [ "$(cat $b 2>/dev/null)" = "$_t" ] || { chmod a+w $b && echo $_t > $b; } || :
    done
  fi
  for a in */charge_control_limit_max; do
    b=${a%_max}
    if [ ! -f $a ] || [ ! -f $b ]; then
      continue
    fi
    _t=$(( ($(cat $a) * l) / 100 )); [ "$(cat $b 2>/dev/null)" = "$_t" ] || { chmod a+w $b && echo $_t > $b; } || :
  done
  [ $l -ne 0 ] && touch $f || rm $f 2>/dev/null || :
}


status() {

  local i=0
  local return1=false
  local csw2=${chargingSwitch[2]-}
  local curNow=$(cat $currFile)
  # N1 (coerce): a transient empty/garbage current_now read (common on some fuel gauges during a
  # mode switch) would make idle_discharging's "[ ${curNow#-} -le N ]" and the calc below a 2-arg
  # test / arithmetic error, aborting this hot loop under set -eu (charging limit lost). Same
  # hardening the sibling volt_now/batt_cap/temp_now reads already carry; curNow was the gap.
  case ${curNow#-} in ''|*[!0-9]*) curNow=0;; esac

  _status=$(read_status)
  # Keep the kernel's own verdict. idle_discharging() below replaces _status with a verdict
  # derived from the CURRENT SIGN, and when that sign is misread there is nothing left to
  # compare against. Stashing it costs one variable and gives the arbitration a third opinion.
  _kstatus=$_status

  if [ -n "${battStatusOverride-}" ]; then
    [[ .${chargingSwitch[2]-} != */* ]] || csw2="$(cat ${chargingSwitch[2]})"
    if  eq "$battStatusOverride" "Discharging|Idle"; then
      [ "$(cat ${chargingSwitch[0]})" != "$csw2" ] || _status=$battStatusOverride
    else
      _status=$(set -eu; eval '$battStatusOverride') || :
    fi
  # Was a bare $battStatusWorkaround. status() is reached from the daemon via not_charging(),
  # which declares the variable local, but any OTHER caller left it unset -- and under set -u
  # mksh does not abort there, it fails the command and hands the caller rc=1 with _status
  # already fallen back, so a wrong charging status propagates quietly instead of loudly.
  # An empty value (not_charging's `local battStatusWorkaround=${battStatusWorkaround-}` can
  # produce one) was an empty command word for the same reason. :-false covers both.
  elif ${battStatusWorkaround:-false}; then
    idle_discharging
  fi

  [ -z "${exitCode_-}" ] || echo -e "  ${switch:--} (${swValue:-N/A})\t$(calc $curNow \* 1000 / ${ampFactor:-$ampFactor_} | xargs printf %.f)mA\t$_status"

  for i in Discharging DischargingDischarging Idle IdleIdle; do
    [ $i != ${1-}$_status ] || return 0
  done

  return 1
}


volt_now() {
  # N1: a transiently-empty/garbage voltage_now read used to emit nothing -> "[ -ge NN ]" syntax
  # error -> daemon abort under set -eu (charging limit lost). Coerce an unreadable node to a
  # fail-safe HIGH value (forces a pause, never a false shutdown) so the loop survives.
  # rc19 (standby): builtin read + prefix trim replace the per-call grep spawn (same first-4
  # digits: uV -> mV). A short/garbage read still coerces to the fail-safe 9999.
  local v=
  { read -r v < $voltNow; } 2>/dev/null || :
  v=${v%"${v#????}"}
  case $v in ''|*[!0-9]*) v=9999;; esac
  echo $v
}


_cache_write(){
  # The only writer of the cache. Temp file then rename, so a reader never sees it half-built and
  # two writers cannot interleave. _DPOL is carried across when it is already known: it is appended
  # later by sdp() rather than being part of this block, and a republish that dropped it would throw
  # away the learned polarity and make the next reader re-derive it.
  { echo "ampFactor_=$ampFactor_
batt=$batt
battCapacity=$batt/capacity
battStatus=$battStatus
currFile=$currFile
curThen=$curThen
idleThreshold=${idleThreshold:-10}
_STI=\${_STI:-35}
temp=$temp
voltNow=$voltNow"
    [ -z "${_DPOL-}" ] || echo "_DPOL=$_DPOL"; } > $TMPDIR/.batt-interface.sh.$$ 2>/dev/null     && mv -f $TMPDIR/.batt-interface.sh.$$ $TMPDIR/.batt-interface.sh 2>/dev/null     || rm -f $TMPDIR/.batt-interface.sh.$$ 2>/dev/null
}

_cache_republish(){
  # For a daemon that is already looping. It sources this file once at init and then works from the
  # variables in its own memory, so losing the FILE costs it nothing and it never noticed -- but the
  # file is the daemon's published state, and everything else on the phone reads it. Measured on
  # both phones: truncate the cache with the daemon left running and it stayed empty indefinitely.
  #
  # This republishes what the daemon already holds. It does NOT re-probe and does not re-source
  # anything, so it cannot change a learned fact or disturb the loop; it only writes down what is
  # already true. Callers rebuild by probing (see the branch below); the daemon has no need to.
  _cache_usable && return 0
  [ -n "${batt-}" ] && [ -n "${currFile-}" ] || return 1
  _cache_write
  _cache_usable
}

_cache_usable(){
  [ -s $TMPDIR/.batt-interface.sh ]     && grep -q '^battCapacity=' $TMPDIR/.batt-interface.sh 2>/dev/null     && grep -q '^currFile=' $TMPDIR/.batt-interface.sh 2>/dev/null
}

# Build on a real init, and ALSO whenever the cache is unusable. The else branch used to `touch`
# and source, and touch CREATES an empty file: every learned fact came back unset and the caller
# carried on with no gauge, no current node and no temperature. That is what an empty `acc -i` was.
# Only accd rebuilt itself, and only at startup, so a daemon already looping never noticed and
# neither did AccA, which reads through the CLI.
if ${_INIT:-false} || ! _cache_usable; then


  # Nexus 10 (manta)
  f1=smb???-battery/status
  f2=ds????-fuelgauge/capacity


  if ls $f1 $f2 >/dev/null 2>&1; then
    batt=${f2%/*}
  else
    for batt in maxfg/capacity */capacity; do
      if [ -f ${batt%/*}/status ]; then
        batt=${batt%/*}
        break
      fi
    done
  fi

  [[ $batt != */capacity ]] || exit 1


  for battStatus in sm????_bms/status $batt/status $f1; do
    [ ! -f $battStatus ] || break
  done

  [ -f $battStatus ] || exit 1
  unset f1 f2


  echo 250 > $TMPDIR/.dummy-temp

  for temp in $batt/temp $batt/batt_temp bms/temp ${battStatus%/*}/temp $TMPDIR/.dummy-temp; do
    [ ! -f $temp ] || break
  done


  echo 0 > $TMPDIR/.dummy-mcc

  for currFile in rt*-charger/current_now battery/current_now $batt/current_now bms/current_now battery/?attery?verage?urrent \
    /sys/devices/platform/battery/power_supply/battery/?attery?verage?urrent \
    ${battStatus%/*}/current_now $TMPDIR/.dummy-mcc
  do
    [ ! -f $currFile ] || break
  done


  voltNow=$batt/voltage_now
  [ -f $voltNow ] || voltNow=$batt/batt_vol
  [ -f $voltNow ] || {
    echo 3900 > $TMPDIR/.voltage_now
    voltNow=$TMPDIR/.voltage_now
  }


  ampFactor=$(sed -n 's/^ampFactor=//p' $dataDir/config.txt 2>/dev/null || :)
  ampFactor_=${ampFactor:-1000}

  # uA-vs-mA: a current >= 16000 (raw) means a microamp sensor (no cell charges at 16+ amps).
  # This is read from whatever the live current is now; amp_recheck (accd) re-latches it the
  # moment a CHARGING current appears and PERSISTS it, so an init while idling at the cap can
  # self-heal. A true milliamp device (e.g. OnePlus 8 Pro: mA current_now but uV/uAh voltage and
  # charge -- a MIXED-unit phone) stays under 16000 even when charging, so it stays mA. (An
  # earlier charge_full_design/voltage anchor mis-detected those mixed-unit phones and is removed:
  # only the current_now magnitude reflects the current_now unit.)
  if [ $ampFactor_ -eq 1000000 ] || [ $(sed s/-// $currFile) -ge 16000 ]; then
    ampFactor_=1000000
  fi

  curThen=$TMPDIR/.mcc
  # Only on a genuine init. A self-heal rebuild is repairing the cache, not restarting the daemon,
  # and dropping the applied-current record there would make it re-apply a cap it already holds.
  if ${_INIT:-false}; then rm $curThen 2>/dev/null || :; fi


  _cache_write
# Written to a temp file and renamed, so a reader never sees it half-built and two writers cannot
# interleave. It used to truncate in place, which was argued safe because accd was the only writer;
# that argument no longer holds now that any caller rebuilds an unusable cache, and a rename is
# cheaper than re-deriving who may race whom.

  _INIT=false


else
  # Reached only when _cache_usable said yes, so the file exists and has content.
  . $TMPDIR/.batt-interface.sh
fi

[ -f $curThen ] || echo null > $curThen

batt_cap() {
  # rc19 (standby): the Android level (a full dumpsys = fork + binder into system_server) is
  # now CACHED and re-read only when the kernel percent moves. The cap checks call this 4-7x
  # per loop, which was ~30 binder calls/min around the clock -- the single biggest standby
  # cost (measured 26% of a core with children on a Mi A3). The kernel node is a builtin read
  # (no fork); the cache (tmpfs, subshell-safe) is keyed to the kernel percent, so a stale
  # Android read can never outlive a real 1% move -- the same 1-frame framework lag exists on
  # a per-call read too. Blind devices (no kernel node) keep the per-call dumpsys as before.
  # N1: never emit empty/garbage -- a blank capacity makes "[ -ge NN ]" a syntax error and aborts
  # the loop under set -eu (limit lost). capacity_mask(=[4]) -> kernel level; else prefer Android's
  # level, fall back to kernel; coerce an unreadable result to 100 (fail-safe pause, never overcharge).
  local l= l2= r= ck= cl=
  { read -r l2 < $battCapacity; } 2>/dev/null || l2=
  case $l2 in *[!0-9]*) l2=;; esac
  # rc20 CRITICAL: if WE have frozen Android's battery state (.dsys-override -- the capacity
  # mask, or the cooldown cycle's own `set ac 1`), Android's level is a snapshot we wrote, not
  # a live reading. Trusting it is circular: during a sustained cooldown the level stops moving,
  # so _lt_pause_cap stays true, the cooldown cycle never breaks, the pause never fires and the
  # cell runs to 100% (field report, rc19). While an override is in force the kernel percent is
  # the only honest source, so use it directly. The mask already did this by design; this simply
  # extends the same rule to every override.
  if ${capacity[4]:-false} || { [ -f $TMPDIR/.dsys-override ] && [ -n "$l2" ]; }; then
    r=$l2
  elif [ -n "$l2" ]; then
    { read -r ck cl < $TMPDIR/.bc-cache; } 2>/dev/null || { ck=; cl=; }
    case ${cl:-x} in *[!0-9]*) cl=;; esac
    if [ ".$ck" = ".$l2" ] && [ -n "$cl" ]; then
      r=$cl
    else
      l=$(dsys_batt get level)
      case ${l:-x} in *[!0-9]*) l=;; esac
      # rc20 SAFETY (defense in depth): Android's level and the kernel percent come from the
      # same fuel gauge and normally agree within a point. A wide gap means Android's battery
      # state is FROZEN (something called `dumpsys battery set/unplug` and never reset -- ACC's
      # own cooldown did exactly that before rc20, but a third-party app or a killed switch test
      # can do it too). A frozen level never reaches the pause level, so the limit never fires
      # and the cell runs to 100%. When they diverge by more than 5, trust the kernel: it is
      # ground truth and it cannot be spoofed by a stale broadcast. The mask path above is
      # unaffected (it already uses the kernel value by design).
      if [ -n "$l" ] && { [ $(( l - l2 )) -gt 5 ] || [ $(( l2 - l )) -gt 5 ]; } 2>/dev/null; then
        l=
      fi
      if [ -n "$l" ]; then
        r=$l
        echo "$l2 $l" > $TMPDIR/.bc-cache 2>/dev/null || :
      else
        r=$l2
      fi
    fi
  else
    l=$(dsys_batt get level)
    r=$l
  fi
  case $r in ''|*[!0-9]*) r=100;; esac
  echo $r
}


cc_now() {
  # charge_counter (uAh remaining) -- a POLARITY-INDEPENDENT "is the cell actually gaining charge?" signal.
  # The resume watchdog uses it to tell a real stall apart from a status node that lies under a bypass/idle
  # switch (OnePlus/OPLUS) or a mis-latched polarity. 0 = node absent or non-numeric (signed coulomb-counter
  # devices) -> callers fall back to the status-only path, so this never regresses a phone without it.
  local _c=$(cat ${battCapacity%capacity}charge_counter 2>/dev/null)
  case "$_c" in ''|*[!0-9]*) echo 0;; *) echo "$_c";; esac
}
