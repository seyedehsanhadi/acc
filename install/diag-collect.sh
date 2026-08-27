#!/system/bin/sh
# ACC + AccA centralized diagnostic collector (v2: scoped + tiered + smart).
# Passive, on-demand, READ-ONLY (the only write is the output bundle; --sample adds a 20s read loop).
# No daemon, no wakelock, no scheduling: it runs for a few seconds on demand and exits. Scope is locked
# to CHARGING / REBOOT / ROOT. See .scratch/centralized-diagnosis/diag-scope-definitive.md.
#
# TIERS
#   CORE        - always collected. Small, high-signal, decides the majority of reports.
#   CONDITIONAL - the heavy raw logs, auto-attached ONLY when a cheap signal fires: a fresh crash
#                 (tombstone/last-crash/DropBox this boot) or an abnormal reboot (bootreason /
#                 pstore panic-density). They are decisive exactly for the case that triggers them.
#   EXTRA       - --full only. Big, rarely decisive.
# SMART           filters drop 70-93% noise (also the privacy boundary); repetitive logs are tailed;
#                 last_kmsg is de-duplicated against pstore (measured 99% identical).
# Usage: diag-collect.sh [--full|--core] [--sample]      (root required)

id=acc; domain=vr25
E=/data/adb/$domain/$id; DD=/data/adb/$domain/${id}-data; T=/dev/.$domain/$id
PKG=mattecarra.accapp
SCHEMA=2; COLLECTOR=2.0

# ---- mode + flags ----
MODE=core; SAMPLE=false
for a in "$@"; do case "$a" in
  --full) MODE=full ;;
  --core|--min) MODE=min ;;
  --sample) SAMPLE=true ;;
esac; done
# opt-in verbose (armed + unexpired) -> auto live sample. Zero background: only steers THIS run.
if [ -f "$DD/.diag-verbose-armed" ]; then
  read _va _vh _rest < "$DD/.diag-verbose-armed" 2>/dev/null
  case "${_va:-}" in ''|*[!0-9]*) _va=0 ;; esac
  case "${_vh:-}" in ''|*[!0-9]*) _vh=24 ;; esac
  _now=$(date +%s 2>/dev/null || echo 0)
  if [ "$_va" -gt 0 ] && [ "$_now" -gt 0 ] && [ $(( _now - _va )) -lt $(( _vh * 3600 )) ]; then SAMPLE=true
  else rm -f "$DD/.diag-verbose-armed" 2>/dev/null; fi
fi

# ---- output, stage ----
OUT=/data/local/tmp
for d in /sdcard/Download /storage/emulated/0/Download; do [ -w "$d" ] 2>/dev/null && OUT="$d" && break; done
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
DEV=$(getprop ro.product.device 2>/dev/null || echo dev)
STAGE=/data/local/tmp/accdiag-$$; rm -rf "$STAGE"; mkdir -p "$STAGE/charging" "$STAGE/reboot" "$STAGE/crash" "$STAGE/acc-logs" "$STAGE/android" "$STAGE/env" "$STAGE/kernel"
MAN="$STAGE/_MANIFEST.txt"; SUM="$STAGE/_SUMMARY.txt"; FS="$STAGE/_FILTERSTATS.txt"
: > "$MAN"; : > "$SUM"; : > "$FS"

man(){ echo "$1" >> "$MAN"; }

# EVERY COLLECTOR IS BOUNDED. Measured on a Mi A3: the whole collector ran 55s on one invocation and
# 456s on the next, same build, same phone, an eight-fold spread with no pattern. `find /sys /proc`
# alone measured 17-18s every time; the rest of the tail is dumpsys and logcat, which block for as
# long as the system makes them. There were ZERO timeout guards in this file.
#
# This is user-facing. It is the one-tap diagnostic, and a user who runs it waits seven and a half
# minutes with nothing on screen to say it is not hung. A bundle that is missing one slow source is
# strictly better than a bundle that never arrives, so a source that overruns is recorded as TIMEOUT
# and the collector moves on.
#
# timeout(1) is not guaranteed present (it is a toybox/busybox applet), so degrade to running bare
# rather than losing the source entirely - the old behaviour, kept only where the tool is absent.
DIAG_TMO=${DIAG_TMO:-30}
if command -v timeout >/dev/null 2>&1; then
  _tmo(){ _t=$1; shift; timeout "$_t" "$@"; }
  _HAVE_TMO=yes
else
  _tmo(){ shift; "$@"; }
  _HAVE_TMO=no
fi
# grab CMD... into a staged file
# _n holds the destination because `shift 2` has already moved it out of $1 by the time the manifest
# line is written. Without it every grab entry named the COMMAND it ran - 22 of the 45 lines in a
# bluejay bundle read "-> sh" - so a responder looking for those files had nothing to look for.
grab(){ _o="$STAGE/$1"; _n="$1"; _l="$2"; shift 2
  _tmo "$DIAG_TMO" "$@" > "$_o" 2>/dev/null; _rc=$?
  if [ "$_rc" = 124 ]; then man "TIMEOUT $_l (over ${DIAG_TMO}s; partial output kept if any)"; fi
  if [ -s "$_o" ]; then man "OK     $_l -> ${_n} ($(wc -c <"$_o")b)"; else man "EMPTY  $_l"; rm -f "$_o"; fi; }
# FILTERED grab: keep only lines matching PATTERN; record raw->kept in _FILTERSTATS (loss accounting)
grabf(){ _o="$STAGE/$1"; _l="$2"; _pat="$3"; _nm="$1"; shift 3; _raw="$STAGE/.raw$$"
  _tmo "$DIAG_TMO" "$@" > "$_raw" 2>/dev/null; _rc=$?
  [ "$_rc" = 124 ] && man "TIMEOUT $_l (over ${DIAG_TMO}s; filtering whatever landed)"
  grep -iE "$_pat" "$_raw" > "$_o" 2>/dev/null
  _rb=$(wc -c <"$_raw" 2>/dev/null); _kb=$(wc -c <"$_o" 2>/dev/null); _rl=$(wc -l <"$_raw" 2>/dev/null); _kl=$(wc -l <"$_o" 2>/dev/null)
  rm -f "$_raw"
  if [ -s "$_o" ]; then man "OK     $_l [filtered] -> ${_nm} (${_kb}b of ${_rb}b)"
    printf '%-26s raw=%sb/%sL  kept=%sb/%sL  dropped=%sb\n' "$_nm" "$_rb" "$_rl" "$_kb" "$_kl" "$(( _rb - _kb ))" >> "$FS"
  else rm -f "$_o"; man "EMPTY  $_l [filtered]"; fi; }
# copy a file; record OK/ABSENT
# The OK line is earned by the DESTINATION, not the source. It used to be logged whenever the source
# existed, with the cp error swallowed - so when the rc22 kernel/ collectors were added without their
# directory, every bundle on a device with /proc/last_kmsg claimed to carry a file it did not have.
# A manifest that records what was ATTEMPTED is worse than none: a responder reads it, sees a byte
# count, and stops looking for the evidence.
cpf(){ if [ -f "$3" ]; then
    # The byte count is the DESTINATION's, never the source's. A procfs file reports size 0 however
    # much it contains: /proc/last_kmsg on a Mi A3 stats as 0 and copies 254KB, and the manifest
    # duly announced "OK ... last_kmsg.txt (0b)" for a quarter-megabyte of kernel log. Reporting
    # what landed is both honest and the only figure a responder can act on.
    if cp -f "$3" "$STAGE/$1" 2>/dev/null && [ -s "$STAGE/$1" ]; then man "OK     $2 -> ${1} ($(wc -c <"$STAGE/$1")b)"
    else
      rm -f "$STAGE/$1" 2>/dev/null
      # An EMPTY source is not a failure. /proc/last_kmsg exists on a Mi A3 and reads zero bytes
      # after a clean reboot - there simply was no previous-boot log to keep - and calling that
      # FAILED sends a responder hunting for evidence that never existed. Same distinction `grab`
      # has always made. A non-empty source that did not land IS a failure and still says so.
      # `[ -s ]` cannot tell "empty" from "procfs" on the SOURCE, so ask by reading instead: if one
      # byte can be read, the source had content and the copy genuinely failed.
      if [ -n "$(dd if="$3" bs=1 count=1 2>/dev/null)" ]; then man "FAILED $2 -> ${1} (source has content, copy did not land)"
      else man "EMPTY  $2 (${3} exists but is empty)"; fi
    fi
  else man "ABSENT $2 (${3})"; fi; }
# tail a file into staging (smart-condense append-only repetitive logs)
tailcpf(){ if [ -f "$3" ]; then tail -n "$4" "$3" > "$STAGE/$1" 2>/dev/null
    if [ -s "$STAGE/$1" ]; then man "OK     $2 [tail $4] -> ${1} ($(wc -c <"$STAGE/$1")b of $(wc -c <"$3")b)"
    else rm -f "$STAGE/$1" 2>/dev/null; man "FAILED $2 [tail $4] -> ${1} (source present, tail did not land)"; fi
  else man "ABSENT $2 (${3})"; fi; }

# ---- filter patterns (scope: charging / reboot / root) ----
DMPAT='charg|batt|therm|power_supply|health|usb|smb|fg_|qpnp|qcom-battery|pmic|vote|jeita|max77|pca9468|google,charger|vooc|dash|warp|oplus|hvdcp|usbpd|usb_pd|typec|pd_active|pdo|panic|oom|watchdog|reboot|fault|die |hang|over.?volt|under.?volt|undervolt|over.?heat|shutdown|overlay|ovl_|erofs| acc|vr25'
# PRIVACY: logcat is scoped to OUR app + charging/kernel ONLY. Generic error/exception/crash lines from
# THIRD-PARTY apps are deliberately NOT matched -- that is where user PII would live. Our own crash stack
# comes from the crash buffer (crash/logcat-crash.txt) + acca-last-crash.txt, not from other apps' logs.
LGPAT="$PKG|accapp| acc:|healthd|[Bb]atteryService|power_supply|charg|thermal|watchdog|jeita|smb|fg_|qpnp|pmic|vooc|dash|hvdcp|usbpd|typec|pd_active"
AVPAT="$PKG|accapp|magisk|vr25|:acc|u:r:magisk|u:r:init|u:r:vendor_init"
GPPAT='ro.product|ro.build.version|ro.build.fingerprint|ro.build.display|ro.boot|ro.hardware|ro.board|ro.soc|charg|batt|crypto|boot.reason|persist.sys.boot|dalvik.vm.heap|init.svc.acc|vr25|sku|treble|vold'

# ---- signal detectors (cheap, computed once) ----
BOOT_EPOCH=$(( $(date +%s 2>/dev/null || echo 0) - $(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0) ))
_mt(){ f=$(ls -t "$@" 2>/dev/null | head -1); [ -n "$f" ] && stat -c %Y "$f" 2>/dev/null || echo 0; }
CRASH_SIGNAL=false
[ "$(_mt /data/tombstones/tombstone_*)" -gt "$BOOT_EPOCH" ] 2>/dev/null && CRASH_SIGNAL=true
[ "$(_mt /data/anr/*)" -gt "$BOOT_EPOCH" ] 2>/dev/null && CRASH_SIGNAL=true
[ "$(stat -c %Y /data/data/$PKG/files/logs/last-crash.txt 2>/dev/null || echo 0)" -gt "$BOOT_EPOCH" ] 2>/dev/null && CRASH_SIGNAL=true
logcat -d -b crash 2>/dev/null | grep -q "$PKG" && CRASH_SIGNAL=true
REBOOT_SIGNAL=false
_BR="$(getprop sys.boot.reason)|$(getprop ro.boot.bootreason)|$(getprop sys.boot.reason.last)|$(getprop persist.sys.boot.reason.history)"
# rc23: this gate decides whether the pstore, last_kmsg and the full dmesg are attached at all -- the
# only three things that can explain a phone going down. Both crashes actually reported from the
# field fell straight through it:
#   - a Motorola kansas (MT6835) hung and came back with ro.boot.bootreason=hang_detect. MediaTek's
#     userspace-hang watchdog is not a panic and matched nothing here.
#   - a OnePlus hung during boot after a dirty module update. The user escaped it by holding the
#     power key, which produces reboot,longkey / cold,powerkey -- a perfectly ordinary-looking
#     reason. Signal false, evidence deferred, on the one report that needed it most.
# It is the LONG-press that is the signal, not the power key. Measured on a Mi A3: an ordinary cold
# boot from the power button reports cold,powerkey, so matching bare powerkey fired on every healthy
# phone and attached the heavy dumps to every bundle -- which is the adaptive gate not existing.
# longkey / keys_clear / hard_reset are the forced resets, and a healthy phone does not do those.
echo "$_BR" | grep -iqE 'panic|watchdog|wdog|wdt|hwt|hang|oom|thermal|kernel|hw_reset|hard_reset|undervolt|err_fatal|dog_ba|dog_bi|tz_err|rpm_err|longkey|keys_clear' && REBOOT_SIGNAL=true
# ACC's own bootloop backstop is the most direct evidence there is: post-fs-data counts boots that
# never reach late_start_service and latches .no-early-cap at three. It is only ever cleared by hand
# (acc -s early_cap on), so its presence means this phone HAS bootlooped with ACC installed --
# regardless of what the reset reason says. reboot-history.log carries the same counter per boot,
# recorded before service.sh clears it, and survives long after.
[ -f "$DD/.no-early-cap" ] && REBOOT_SIGNAL=true
grep -qE 'early-boot-count: [1-9]' "$DD/reboot-history.log" 2>/dev/null && REBOOT_SIGNAL=true
_PS=/sys/fs/pstore/console-ramoops-0; [ -f "$_PS" ] || _PS=/sys/fs/pstore/console-ramoops
if [ -f "$_PS" ]; then _pl=$(wc -l <"$_PS" 2>/dev/null); _pp=$(grep -icE 'panic|die |fatal|watchdog|hardware|BUG|Oops' "$_PS" 2>/dev/null)
  # Both operands have to be numeric before the arithmetic: an unreadable or killed grep leaves _pp
  # empty, and `$(( * 100 / _pl ))` is a syntax error that takes the whole collector down with it --
  # in the middle of gathering a crash report.
  case ${_pl:-x} in ''|*[!0-9]*) _pl=0;; esac
  case ${_pp:-x} in ''|*[!0-9]*) _pp=0;; esac
  [ "$_pl" -gt 0 ] && [ $(( _pp * 100 / _pl )) -ge 2 ] && REBOOT_SIGNAL=true; fi
case "$MODE" in full) CRASH_SIGNAL=true; REBOOT_SIGNAL=true ;; min) CRASH_SIGNAL=false; REBOOT_SIGNAL=false ;; esac

# ---- current-state verdict inputs (turn the captured config+state into a plain-language read) ----
_V_cap=$(grep -m1 '^capacity=' $DD/config.txt 2>/dev/null | sed 's/^capacity=//; s/[()]//g')
_V_resume=$(echo "$_V_cap" | awk '{print $3}'); _V_pause=$(echo "$_V_cap" | awk '{print $4}')
_V_batt=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
_V_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
case "${_V_pause:-}" in ''|*[!0-9]*) _V_pause= ;; esac
case "${_V_batt:-}" in ''|*[!0-9]*) _V_batt= ;; esac

# ===== _SUMMARY.txt =====
{
  echo "ACC/AccA diagnostic bundle   schema=$SCHEMA  collector=$COLLECTOR   mode=$MODE"
  echo "collected: $(date 2>/dev/null)   uptime: $(cut -d. -f1 /proc/uptime 2>/dev/null)s"
  echo "adaptive: crash-signal=$CRASH_SIGNAL  reboot-signal=$REBOOT_SIGNAL  (heavy raw attached only when true)"
  echo
  echo "[verdict] plain-language read -- every line cites the raw value it rests on; nothing is asserted without it"
  _vn=0; _dOK=0; _capOK=0
  # daemon: backed by pgrep (raw output in env/daemon-detail.txt + [identity] below)
  # The daemon verdict must not use a bare `pgrep -f accd.sh`: release-lock's pkill and
  # service.sh's start-stop-daemon both carry that path in their own argv, so a phone with no
  # daemon can read as UP and the report then calls an unmanaged phone healthy. Same positive test
  # as misc-functions.sh daemon_alive (a SHELL whose script argument is accd.sh); inlined because
  # this collector deliberately sources nothing and must keep running on a broken install.
  _diag_accd() {
    local _p= _c=
    for _p in $(pgrep -f "accd.sh" 2>/dev/null); do
      [ -r "/proc/$_p/cmdline" ] || continue
      _c=$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)
      set -f; set -- $_c; set +f
      case "${1:-}" in sh|*/sh|mksh|*/mksh|bash|*/bash|busybox|*/busybox) ;; *) continue;; esac
      [ "${1##*/}" = busybox ] && shift
      case "${2:-}" in */accd.sh|accd.sh) return 0;; esac
    done
    return 1
  }
  if _diag_accd; then _dOK=1; else echo "  (!) daemon DOWN (no shell running accd.sh) -> charging is UNMANAGED, limit not enforced"; _vn=$((_vn+1)); fi
  # charge limit: backed by config.txt capacity= (raw tuple shown so a wrong field-order is visible)
  if [ -n "$_V_cap" ]; then
    if [ -n "$_V_pause" ]; then _capOK=1
      # Read the switch the user ACTUALLY has, not input_suspend. chargingSwitch=(<node> <on> <off> --)
      # where <node> is relative to the power-supply dir. Hardcoding input_suspend declared a healthy
      # `battery/charging_enabled` phone "switch may be broken" purely because the unused node read 0
      # (field report, sweet/M2101K6G). Holding == the configured node sits at its OFF value.
      _V_swl=$(sed -n 's/^chargingSwitch=(//p' "$DD/config.txt" 2>/dev/null | sed 's/).*$//' | head -1)
      _V_swn=$(echo "$_V_swl" | awk '{print $1}'); _V_swoff=$(echo "$_V_swl" | awk '{print $3}')
      # The node is stored absolute on some setups (A3) and relative to the power-supply dir on
      # others (sweet), and on/off are inverted between them, so resolve the path both ways and
      # always take OFF from field 3 rather than assuming 1 means "held".
      case "$_V_swn" in /*) _V_swp="$_V_swn" ;; *) _V_swp="/sys/class/power_supply/$_V_swn" ;; esac
      # THE FIRMWARE LIMIT DECIDES FIRST, WHERE THERE IS ONE.
      #
      # On a phone with a native charge_stop_level the daemon drives that and never writes the
      # configured chargingSwitch at all. Judging the hold from that switch therefore reports a
      # perfectly healthy phone as broken. Worse, the OFF value there is the KEYWORD "pcap", not a
      # number, so the comparison was "40" against the literal string pcap and could never be true.
      #
      # Field report, bramble/Pixel 4a 5G: charge_stop_level=40 with pause=40 and the firmware
      # holding correctly, and this block printed "switch is NOT holding charge (switch may be
      # broken)" and then, off the same flag, "overcharging now (daemon not holding)". The bundle
      # said the opposite of itself, because the section below already reports the native limit as
      # ACTIVE. The same owner had already lost a report to exactly this once - see the note in
      # accd.sh about a Pixel 4a 5G owner hunting a switch that had never been in use.
      _V_gcsl=""
      # Same override accd.sh uses for the same list, so this branch can be driven in a test with a
      # fabricated tree instead of only on hardware that happens to have the path.
      for _d in ${NATIVE_DIRS:-/sys/devices/platform/google,charger /sys/devices/platform/soc/soc:google,charger}; do
        [ -f "$_d/charge_stop_level" ] && _V_gcsl="$_d"
      done
      if [ -n "$_V_gcsl" ] && [ ! -f "$DD/.no-native-limit" ]; then
        _susp_node="${_V_gcsl}/charge_stop_level"
        _susp_now=$(cat "$_V_gcsl/charge_stop_level" 2>/dev/null | head -1)
        _susp_want="$_V_pause"
      elif [ -n "$_V_swn" ] && [ -e "$_V_swp" ]; then
        _susp_node="$_V_swn"; _susp_want="$_V_swoff"
        _susp_now=$(cat "$_V_swp" 2>/dev/null | head -1)
        # pcap and rcap are keywords meaning "the pause level" and "the resume level". Comparing a
        # node reading 40 against the string "pcap" is never true, so a level-type switch that was
        # holding perfectly read as broken.
        case "$_susp_want" in
          pcap) _susp_want="$_V_pause" ;;
          rcap) _susp_want="$_V_resume" ;;
        esac
      else
        _susp_node="battery/input_suspend"; _susp_want=1
        _susp_now=$(cat /sys/class/power_supply/battery/input_suspend 2>/dev/null)
      fi
      if [ -n "$_susp_now" ] && [ "$_susp_now" = "$_susp_want" ]; then _susp=1; else _susp=0; fi
      if [ "$_V_pause" -ge 100 ]; then echo "  (!) charge limit pause=${_V_pause}% [capacity=($_V_cap)] -> NO protective limit (charges to full)"; _vn=$((_vn+1))
      elif [ -n "$_V_batt" ] && [ "$_V_batt" -gt "$_V_pause" ]; then
        if [ "$_susp" = 1 ]; then echo "  (!) pause=${_V_pause}% below level ${_V_batt}% + ${_susp_node}=${_susp_now} (off) -> charging HELD at the limit (raise it to charge higher)"
        else echo "  (!) pause=${_V_pause}% below level ${_V_batt}% but ${_susp_node}=${_susp_now:-unreadable} (off=${_susp_want}) -> switch is NOT holding charge (switch may be broken)"; fi
        _vn=$((_vn+1))
      else echo "  charge limit: stops ${_V_pause}% / resumes ${_V_resume}% [capacity=($_V_cap)], now ${_V_batt:-unknown}%"; fi
    else echo "  (?) capacity=($_V_cap) present but pause field did not parse -> read config.txt directly"; fi
  else echo "  (?) config.txt capacity NOT readable -> CANNOT verify the charge limit (see config.txt / init.log)"; _vn=$((_vn+1)); fi
  # live overcharge: backed by battery status+level+pause (all raw-captured)
  # Only an overcharge if the switch is NOT held. A held switch plus status=Charging is a lying
  # status node (what battStatusWorkaround exists for) or idle/bypass mode, not a runaway charge.
  if [ -n "$_V_batt" ] && [ -n "$_V_pause" ] && [ "$_V_batt" -gt "$_V_pause" ] && [ "$_V_status" = Charging ] && [ "${_susp:-0}" != 1 ]; then echo "  (!) status=Charging at ${_V_batt}% ABOVE pause ${_V_pause}% -> overcharging now (daemon not holding)"; _vn=$((_vn+1)); fi
  # crash/reboot: backed by the captured signals + the crash/ and reboot/ folders
  # System thermal throttle. charge_control_limit is a THERMAL mitigation level owned by the ROM,
  # NOT by ACC -- ACC never writes it. A user on a 9V charger seeing 5V/2A has no way to tell that
  # apart from an ACC fault, and the bundle already captured both numbers without ever saying so
  # (field report, curtana/crDroid: level 8/10 + Thermal Status 4 while asking why ACC throttled
  # him). Report the raw pair and let the level speak; assert nothing we did not read.
  # ...unless ACC itself is driving that node. On an oplus OnePlus 8 the working charging switch
  # IS charge_control_limit (0 on, 4 off), so a held limit reads 4 of 4 and this line would have
  # blamed the ROM for a cut ACC made on purpose. When ACC owns the node, say nothing: silence is
  # better than a confident wrong accusation, and the charge-limit lines above already cover it.
  _V_ccl=$(cat /sys/class/power_supply/battery/charge_control_limit 2>/dev/null | head -1)
  _V_cclm=$(cat /sys/class/power_supply/battery/charge_control_limit_max 2>/dev/null | head -1)
  case "${_V_swn:-}" in *charge_control_limit*) _V_ccl=; _V_cclm=;; esac
  case "${_V_ccl:-}${_V_cclm:-}" in *[!0-9]*|'') : ;; *)
    if [ "$_V_cclm" -gt 0 ] && [ "$_V_ccl" -gt 0 ]; then
      _V_ts=$(dumpsys thermalservice 2>/dev/null | sed -n 's/^Thermal Status: *//p' | head -1)
      echo "  (!) system thermal throttle: charge_control_limit=${_V_ccl} of ${_V_cclm}${_V_ts:+, Android Thermal Status=$_V_ts} -> the ROM is limiting charge rate, NOT ACC (ACC never writes this node). Charge cool/screen-off to compare."
      _vn=$((_vn+1))
    fi
  ;; esac
  # Vendor battery authentication. On Xiaomi the kernel gates HIGH-VOLTAGE charging on a battery
  # check; fail it and the phone holds a 5V contract forever no matter what the charger offers, and
  # nothing in userspace can override that. It looks exactly like throttling, so it gets reported as
  # one -- and ACC gets the blame for a decision made below it.
  #
  # Field report, curtana/Redmi Note 9S: "still not getting fast charge". The charger advertised
  # 9V/3A, 15V/3A and 20V/4.5A and negotiated Type-C high (3.0A); the phone sat at 4.75V/1.43A =
  # 6.75W. The reason was three lines of dmesg the bundle already carried and never surfaced:
  #     usbpd0: batterysecret verify process :0
  #     usbpd0: batterysecret set usbpd verifed :0
  # ACC's write ledger for that whole session was one line, a plug-time re-kick that RAISED the
  # contract 4732mV -> 4785mV. It had capped nothing.
  #
  # Only the verified=0 verdict is reported, never the absence of the service: a phone without
  # batterysecret at all is not failing anything.
  _V_bs=$(grep -aoE 'batterysecret[^:]*verifed[[:space:]]*:[0-9]' /data/local/tmp/.acc-dmesg 2>/dev/null | tail -1)
  [ -n "$_V_bs" ] || _V_bs=$(dmesg 2>/dev/null | grep -aoE 'batterysecret[^:]*verifed[[:space:]]*:[0-9]' | tail -1)
  case "${_V_bs:-}" in
    *:0)
      _V_pdv=$(cat /sys/class/power_supply/usb/voltage_now 2>/dev/null | head -1)
      [ -n "$_V_pdv" ] && [ "$_V_pdv" -gt 100000 ] 2>/dev/null && _V_pdv=$(( _V_pdv / 1000 ))
      echo "  (!) battery authentication FAILED (kernel: '${_V_bs}')${_V_pdv:+, port at ${_V_pdv}mV} -> this phone's kernel gates high-voltage fast charging on a battery check, and the check said no. It will hold a 5V contract whatever the charger offers. NOT ACC (ACC never touches this). Usual causes: a replaced/aftermarket battery, or a handshake that failed this plug -- reboot and replug to re-run it."
      _vn=$((_vn+1)) ;;
  esac
  $CRASH_SIGNAL && { echo "  (!) fresh crash/ANR/native captured -> see crash/"; _vn=$((_vn+1)); }
  $REBOOT_SIGNAL && { echo "  (!) abnormal reboot signalled (sys.boot.reason=$(getprop sys.boot.reason)) -> see reboot/"; _vn=$((_vn+1)); }
  # all-clear ONLY if we actually verified daemon UP and read the limit -- never a blind reassurance
  [ "$_vn" = 0 ] && [ "$_dOK" = 1 ] && [ "$_capOK" = 1 ] && echo "  all clear: daemon up, charge limit read and normal, no fresh crash or abnormal reboot"
  echo
  echo "[identity]"
  echo "  device : $(getprop ro.product.device) / $(getprop ro.product.model) / SoC $(getprop ro.board.platform)"
  echo "  rom    : $(getprop ro.build.display.id)  Android $(getprop ro.build.version.release)  kernel $(uname -r)"
  echo "  root   : magisk=$(magisk -V 2>/dev/null || echo n/a) ksud=$(ksud -V 2>/dev/null || echo n/a)  busybox=$(command -v busybox >/dev/null && echo yes || echo no)  crypto=$(getprop ro.crypto.state)"
  # `acc --version` pads its output with a leading blank line, so `head -1` returned EMPTY and
  # every bundle we ever collected showed "handler " with nothing after it. Take the first
  # NON-empty line instead. (Same padding made two of our own test scripts misread the version.)
  # /dev/acc can exist and still print nothing (seen on KernelSU + FBE, curtana/crDroid: the
  # bundle reported "/dev/acc=ok" next to an empty handler field). Fall back through the other
  # real sources and, if they all fail, SAY it failed -- an empty field reads as "no handler",
  # which is a different and much scarier fault than "version unreadable".
  _hv=$(/dev/acc --version 2>/dev/null | grep -m1 .)
  [ -n "${_hv:-}" ] || _hv=$(acc --version 2>/dev/null | grep -m1 .)
  [ -n "${_hv:-}" ] || _hv=$(grep -m1 '^version=' /data/adb/vr25/acc/module.prop 2>/dev/null | cut -d= -f2)
  [ -n "${_hv:-}" ] || _hv="UNREADABLE (/dev/acc exists but --version printed nothing)"
  echo "  ACC    : module $(grep -h '^version=' /data/adb/modules/$id/module.prop 2>/dev/null | cut -d= -f2) / handler $_hv"
  echo "  AMPS   : $(grep -m1 '^V=' $E/acc-compat.sh 2>/dev/null | cut -d= -f2)   AccA: $(dumpsys package $PKG 2>/dev/null | grep -m1 versionName | tr -d ' ')"
  echo "  daemon : $(pgrep -f accd.sh >/dev/null && echo UP || echo DOWN)   /dev/acc=$([ -e /dev/acc ] && echo ok || echo MISSING)   tmpfs=$([ -d $T ] && echo ok || echo absent)"
  echo
  echo "[charging now]"
  _bt=$(cat /sys/class/power_supply/battery/temp 2>/dev/null); case "$_bt" in ''|*[!0-9-]*) _bt= ;; esac
  _bl=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  echo "  status=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo -) level=${_bl:--}$([ -n "$_bl" ] && echo %) temp=$([ -n "$_bt" ] && echo "$((_bt/10))C (raw $_bt, assumes deci-C)" || echo -) health=$(cat /sys/class/power_supply/battery/health 2>/dev/null || echo -)"
  echo "  current_now=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null) voltage_now=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null) charge_type=$(cat /sys/class/power_supply/battery/charge_type 2>/dev/null)"
  echo "  input_suspend=$(cat /sys/class/power_supply/battery/input_suspend 2>/dev/null || echo -)  charge_control_limit=$(cat /sys/class/power_supply/battery/charge_control_limit 2>/dev/null || echo -)  csl=$(cat /sys/devices/platform/google,charger/charge_stop_level 2>/dev/null || echo -)"
  echo "  switch=$(grep -m1 '^chargingSwitch=' $DD/config.txt 2>/dev/null)  caps=$(grep -m1 '^capacity=' $DD/config.txt 2>/dev/null)"
  echo
  echo "[reboot/crash]"
  echo "  bootreason: sys=$(getprop sys.boot.reason) raw=$(getprop ro.boot.bootreason) last=$(getprop sys.boot.reason.last)"
  echo "  reboot-signal=$REBOOT_SIGNAL   crash-signal=$CRASH_SIGNAL"
  echo "  pstore: $(ls /sys/fs/pstore/ 2>/dev/null | tr '\n' ' ' || echo none)  tombstones: $(ls /data/tombstones/ 2>/dev/null | wc -l)  anr: $(ls /data/anr/ 2>/dev/null | wc -l)"
  echo "  reboot archive: $([ -f $DD/reboot-history.log ] && echo "$(grep -c '^====' $DD/reboot-history.log 2>/dev/null || :) boots recorded (persistent)" || echo "none yet")"
  echo "  last app-crash: $(logcat -d -b crash 2>/dev/null | grep -A2 'FATAL EXCEPTION' | grep -m1 "$PKG" | tr -d ' ' | head -c 60)"
  echo
  echo "[privacy] scope: charging, reboot, root modules, and THIS app only."
  echo "  Stripped from everything: device serial, MAC address, email, IMEI/IMSI/ICCID/android_id."
} > "$SUM"

# ============================================================ CORE (always) ============================================================
# --- charging (the domain that matters most; the ~1KB of adds live here) ---
grab charging/acc-i.txt        "acc live snapshot (acc -i: STATUS/CURRENT/INPUT_SUSPEND/CTRL_LIMIT)" sh -c '/dev/acc -i 2>/dev/null || acc -i 2>/dev/null'
grab charging/power-supply.txt "power_supply full nodes (health/charge_type/limits/counter/full)" sh -c '
  for s in /sys/class/power_supply/*; do [ -d "$s" ] || continue; echo "== ${s##*/} (type=$(cat $s/type 2>/dev/null)) =="
    for n in status present online health charge_type capacity temp voltage_now current_now power_now \
             input_suspend charge_control_limit charge_control_limit_max input_current_limit \
             constant_charge_current_max constant_charge_voltage_max charge_counter charge_full charge_full_design \
             charge_stop_level charge_start_level; do
      v=$(cat "$s/$n" 2>/dev/null); [ -n "$v" ] && echo "  $n=$v"; done; done'
grab charging/power-supply-uevent.txt "power_supply FULL uevent (EVERY driver prop -- generic; catches nodes the curated list misses)" sh -c '
  for s in /sys/class/power_supply/*; do [ -f "$s/uevent" ] && { echo "== ${s##*/} =="; cat "$s/uevent" 2>/dev/null; }; done'
grab charging/pmic-votable.txt "PMIC votables (Qualcomm min-wins: which subsystem limits/blocks charge)" sh -c '
  d=/sys/kernel/debug/pmic-votable; [ -d "$d" ] || { echo "(no pmic-votable on this SoC)"; exit 0; }
  for v in FCC FCC_MAIN USB_ICL DC_ICL CHG_DISABLE FV SMB_EN AWAKE DC_SUSPEND ICL_CHANGE; do
    [ -f "$d/$v/status" ] && { echo "== $v =="; cat "$d/$v/status" 2>/dev/null; }; done'
grab charging/switches.txt "charging switch: enforced + candidates + offered list + what actually holds" sh -c '
  echo "== enforced =="; /dev/acc -s s: 2>/dev/null || acc -s s: 2>/dev/null
  # ch-switches IS the list the picker and "acc -ss::" offer. Without it a report of the form
  # "my old switch is not in the list any more" cannot be answered from the bundle at all
  # (Pixel 4a 5G, 2026-07-28). The numbered view is what the user actually sees.
  echo "== offered list (acc -ss::) =="; /dev/acc -ss:: 2>/dev/null || acc -ss:: 2>/dev/null
  echo "== ch-switches (raw candidate file the offer list is built from) =="
  cat '"$T"'/ch-switches 2>/dev/null || echo "(absent)"
  # WHICH mechanism is really holding the limit. On a phone with a firmware limit the daemon
  # drives that and skips the configured switch entirely, so config.txt can name a node that is
  # never written -- which sends people hunting for a switch that was never the problem.
  echo "== what is holding the limit =="
  _gcsl=""; for _d in /sys/devices/platform/google,charger /sys/devices/platform/soc/soc:google,charger; do
    [ -f "$_d/charge_stop_level" ] && _gcsl="$_d"; done
  if [ -n "$_gcsl" ] && [ ! -f '"$DD"'/.no-native-limit ]; then
    echo "  NATIVE firmware limit is ACTIVE ($_gcsl)"
    echo "    charge_stop_level  = $(cat "$_gcsl/charge_stop_level" 2>/dev/null)"
    echo "    charge_start_level = $(cat "$_gcsl/charge_start_level" 2>/dev/null)"
    echo "    -> the daemon drives these and SKIPS the configured chargingSwitch below;"
    echo "       a chargingSwitch naming any other node is NOT what holds the limit."
  else
    echo "  generic switch path (no native firmware limit in use)"
  fi
  echo "    configured chargingSwitch = $(grep -m1 "^chargingSwitch=" '"$DD"'/config.txt 2>/dev/null)"
  echo "== candidates/working (acc-data) =="; for f in '"$DD"'/logs/*compat* '"$DD"'/logs/switch* '"$DD"'/logs/*ctrl-files* '"$DD"'/logs/acc-p*; do [ -f "$f" ] && { echo "-- ${f##*/} --"; cat "$f" 2>/dev/null; }; done'
grab charging/thermal.txt      "thermal (zones + throttle)" sh -c 'dumpsys thermalservice 2>/dev/null; echo "---- zones ----"; for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type 2>/dev/null)=$(cat $z/temp 2>/dev/null)"; done'
grab charging/doze-power.txt   "doze/deviceidle + power (standby drain, schedule-miss)" sh -c 'echo "== deviceidle =="; dumpsys deviceidle 2>/dev/null; echo; echo "== power (head) =="; dumpsys power 2>/dev/null | head -120'
grab charging/dumpsys-battery.txt "dumpsys battery (HAL snapshot)" sh -c 'dumpsys battery 2>/dev/null'

# --- reboot (persistent record always; raw dumps are CONDITIONAL) ---
grab reboot/bootreason.txt "boot/reset reason: canonical + raw + history + PON/POFF latch + bootstat" sh -c '
  getprop | grep -iE "boot.?reason"; echo "---- PON/POFF (Qualcomm PMIC latch, if exposed) ----"
  for f in $(timeout 20 find /sys /proc -iname "*pon*reason*" -o -iname "*poff*reason*" 2>/dev/null | head -6); do echo "$f = $(timeout 5 cat "$f" 2>/dev/null | head -1)"; done
  echo "---- bootstat (OS cross-boot reboot record; corroborates a bootloop) ----"; dumpsys bootstat 2>/dev/null | head -40'
cpf reboot/reboot-history.txt "reboot archive (PERSISTENT, per-boot; the reliable reboot record)" "$DD/reboot-history.log"

# --- crash (app-side small evidence always; tombstones/anr are CONDITIONAL) ---
grab crash/logcat-crash.txt "logcat crash buffer (app FATAL stack)" logcat -d -b crash
grab crash/dropbox-index.txt "DropBox index (crash/anr/panic events; bodies often quota-purged)" sh -c 'dumpsys dropbox 2>/dev/null | grep -iE "crash|anr|panic|watchdog|tombstone|last_kmsg|strictmode|wtf"'
cpf crash/acca-last-crash.txt "AccA last crash (stack + breadcrumbs)" /data/data/$PKG/files/logs/last-crash.txt
cpf crash/acca-breadcrumbs.txt "AccA breadcrumbs (recent app events, flushed on collect)" /data/data/$PKG/files/logs/breadcrumbs.txt

# --- ACC own logs (flight full = gold; repetitive ones tailed) ---
cpf acc-logs/flight.log     "acc flight log (charge decisions; 100% unique)" "$DD/logs/flight.log"
cpf acc-logs/write.log      "acc write.log (panic-write ledger; reboot cause)" "$DD/logs/write.log"
cpf acc-logs/warnings.log   "acc warnings" "$DD/logs/warnings.log"
# rc22: THE artifact for "my phone turned itself off". accd's shutdown() records the level,
# temperature, status and the whole config immediately before powering the device off, and syncs it
# so it survives. It also records a REFUSED shutdown (offline charging mode). Powering a phone off
# is the most drastic thing this module does, and this file is the only place that says whether it
# did -- yet the collector never gathered it, so a report of an overnight power-off arrived with no
# way to answer the question either way. Found chasing exactly such a report on a fleur.
cpf acc-logs/shutdown-trace.log "acc shutdown trace (WAS IT ACC? every power-off and refusal, with the state at that moment)" "$DD/logs/shutdown-trace.log"
# Kernel-side forensics for the same question: if ACC did NOT do it, these say who did.
cpf kernel/last_kmsg.txt    "previous boot's kernel log (power-off / panic cause)" /proc/last_kmsg
for _ps in /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/console-ramoops /sys/fs/pstore/dmesg-ramoops-0; do
  [ -f "$_ps" ] && cpf "kernel/pstore-${_ps##*/}.txt" "pstore from the previous boot" "$_ps"
done
grab kernel/bootreason.txt "why the device last booted" sh -c "getprop | grep -iE 'bootreason|boot.reason|last.reboot' 2>/dev/null"
cpf acc-logs/early-cap.log  "acc early-cap (boot-time charge guard)" "$DD/logs/early-cap.log"
tailcpf acc-logs/init-tail.log    "acc init (recent)"    "$DD/logs/init.log" 800
tailcpf acc-logs/install-tail.log "acc install (recent)" "$DD/logs/install.log" 800
_acd=$(ls -t $T/accd-*.log 2>/dev/null | head -1); [ -n "$_acd" ] && tailcpf acc-logs/accd-trace-tail.txt "accd loop trace (recent)" "$_acd" 1500
cpf acc-logs/write-ledger.txt "write-ledger (tmpfs)" "$T/.write-ledger"
cpf state.json  "daemon state snapshot" "$T/state.json"
cpf config.txt  "full config" "$DD/config.txt"
grab config-active.txt "active config (no comments)" sh -c "grep -Ev '^\$|^#' '$DD/config.txt' 2>/dev/null"
cpf amps-verified.txt "AMPS verified artifact" /data/local/tmp/acc-compat-verified
grab acc-journals.txt "panic self-heal journals" sh -c 'for j in .probe-blacklist .probe-pending .earlycap-pending .early-boot-count .no-early-cap .acc-compat-blacklist .acc-compat-inflight; do echo "== '"$DD"'/$j =="; cat "'"$DD"'/$j" 2>/dev/null || echo "(absent)"; done'
cpf acc-logs/STALE-backup-config.txt "STALE BACKUP, NOT the live settings. The authoritative file is config-active.txt. Kept only so a diff against it reveals a silent revert." "$DD/backup/config.txt"
cpf acc-logs/backup-module.prop "ACC installed module.prop (the version actually on disk)" "$DD/backup/module.prop"
grab acc-logs/plugins.txt "ACC plugins (user add-ons that can change charging behavior)" sh -c 'ls -la '"$DD"'/plugins/ 2>/dev/null; for f in '"$DD"'/plugins/*; do [ -f "$f" ] && { echo "-- ${f##*/} --"; cat "$f" 2>/dev/null; }; done'
# CATCH-ALL: sweep any OTHER file under acc-data/logs that no named grab above took -- future-proof, so a
# new/unknown ACC or plugin log is captured without editing this script. Big files are tailed.
for _f in $DD/logs/*; do
  [ -f "$_f" ] || continue; _bn=${_f##*/}
  case "$_bn" in init.log|install.log) continue ;; esac
  [ -e "$STAGE/acc-logs/$_bn" ] && continue
  if [ "$(wc -c <"$_f" 2>/dev/null || echo 0)" -gt 50000 ]; then tail -c 50000 "$_f" > "$STAGE/acc-logs/$_bn" 2>/dev/null; else cp -f "$_f" "$STAGE/acc-logs/$_bn" 2>/dev/null; fi
  [ -s "$STAGE/acc-logs/$_bn" ] && man "OK     acc log (swept, unenumerated) -> acc-logs/$_bn"
done

# --- AccA app state (its own settings/profiles/schedules -- decisive for any app-side fault) ---
cpf acca-prefs.xml "AccA settings (shared_prefs: profile, djs_enabled, meter/units/theme)" "/data/data/$PKG/shared_prefs/${PKG}_preferences.xml"
cpf acca-database.db "AccA database (profiles + schedules; open with sqlite -- sqlite3 absent on most phones)" "/data/data/$PKG/databases/acca_database"
# Room runs the database in WAL mode, so recent (often ALL) rows live in acca_database-wal and the
# main file alone can open with ZERO tables -- which is exactly what a Pixel 3a bundle showed, making
# the user's profiles unreadable at the moment they were the thing being asked about. The -wal and
# -shm are only meaningful next to the db they belong to, so all three travel together.
cpf acca-database.db-wal "AccA database write-ahead log (REQUIRED with acca-database.db, or it reads empty)" "/data/data/$PKG/databases/acca_database-wal"
cpf acca-database.db-shm "AccA database shared-memory index (companion to the -wal)" "/data/data/$PKG/databases/acca_database-shm"
grab acca-jobs.txt "AccA scheduled jobs (JobScheduler state; for schedule/DJS not applying)" sh -c 'dumpsys jobscheduler 2>/dev/null | grep -iE -A6 "'"$PKG"'" | head -60'
# secondary users / work profile / private space (A15): the same 4 app files under any non-zero user id
for _u in /data/user/*/; do _un=${_u%/}; _un=${_un##*/}; [ "$_un" = 0 ] && continue
  for _rel in shared_prefs/${PKG}_preferences.xml databases/acca_database databases/acca_database-wal files/logs/last-crash.txt files/logs/breadcrumbs.txt; do
    [ -f "$_u$PKG/$_rel" ] && cp -f "$_u$PKG/$_rel" "$STAGE/acca-u${_un}-${_rel##*/}" 2>/dev/null && man "OK     AccA user-$_un -> acca-u${_un}-${_rel##*/}"; done; done

# --- filtered slices (SMART: drop 70-93% noise; also the privacy boundary) ---
grabf android/dmesg-scoped.txt "dmesg [charge/thermal/panic/root filtered]" "$DMPAT" sh -c 'dmesg 2>/dev/null | tail -n 12000'
grabf android/logcat-scoped.txt "logcat [our pkg + charge + errors filtered]" "$LGPAT" sh -c 'logcat -d -b main -b system'
grabf android/avc-scoped.txt   "avc denials [our SELinux context filtered]" "$AVPAT" sh -c 'dmesg 2>/dev/null | grep -iE "avc: *denied"; logcat -d -b main -b system 2>/dev/null | grep -iE "avc: *denied"'
grab android/getprop-curated.txt "getprop [curated: device/charge/boot keys]" sh -c "getprop | grep -iE '$GPPAT'"

# --- root/env context ---
grab env/modules.txt "installed root modules (what else could interact)" sh -c '
  for m in /data/adb/modules/*/; do [ -d "$m" ] || continue
    mid=$(grep -m1 "^id=" "$m/module.prop" 2>/dev/null | cut -d= -f2); mv=$(grep -m1 "^version=" "$m/module.prop" 2>/dev/null | cut -d= -f2)
    st=enabled; [ -f "$m/disable" ] && st=DISABLED; [ -f "$m/remove" ] && st=TO-REMOVE
    echo "$mid  $mv  $st"; done'
grab env/env.txt "environment (mount/applets/module dir/flags)" sh -c '
  echo "== /system mount =="; awk "\$2 ~ /^\/system/ {print \"  \"\$2\" -> \"\$3}" /proc/mounts | sort -u
  echo "== applets =="; for a in logcat dumpsys getprop start-stop-daemon flock setsid timeout pgrep bzip2 toybox busybox; do command -v $a >/dev/null 2>&1 && echo "  $a: $(command -v $a)"; done
  echo "== module dir =="; ls -la /data/adb/modules/acc 2>/dev/null | head -20
  echo "== flags =="; for f in /data/adb/modules/acc/disable /data/adb/modules/acc/remove '"$E"'/disable '"$DD"'/disable '"$DD"'/.no-early-cap; do [ -e "$f" ] && echo "  $f PRESENT"; done'
grab djs.txt "DJS scheduler (module + schedules + last run)" sh -c '
  echo "== djs module =="; grep -h "^version" /data/adb/modules/djs/module.prop 2>/dev/null || echo "(not installed)"
  echo "== running =="; pgrep -f djs.sh >/dev/null && echo yes || echo no
  echo "== schedules/last-run =="; for s in $(find /data/adb/vr25 /data/adb/djs /data/data/'"$PKG"'/files -iname "*djs*" 2>/dev/null | head -6); do [ -f "$s" ] && { echo "-- ${s##*/} --"; tail -20 "$s" 2>/dev/null; }; done'
grab env/daemon-detail.txt "daemon process state (all PIDs=concurrency, stat=D=hung, runtime UID, tmpfs+data listing)" sh -c '
  echo "== accd processes (pid + cmdline; more than one = concurrent-write risk) =="; pgrep -af accd.sh 2>/dev/null || pgrep -f accd.sh 2>/dev/null || echo "(none -- daemon down)"
  echo "== ps state (STAT D = stuck in kernel; USER must be root) =="; for _p in $(pgrep -f accd.sh 2>/dev/null); do ps -o pid,user,stat,wchan,cmd -p $_p 2>/dev/null | grep -v "^\s*PID"; done
  echo "== selinux: $(getenforce 2>/dev/null) =="
  echo "== su on PATH: $(command -v su 2>/dev/null || echo NO) =="
  echo "== tmpfs runtime ('"$T"') =="; ls -la '"$T"' 2>/dev/null
  echo "== data dir ('"$DD"') =="; ls -la '"$DD"' 2>/dev/null'
grab charging/drain.txt "idle-drain evidence (runaway CPU / wakelocks -- the standby-drain class)" sh -c '
  echo "== top CPU (one shot) =="; top -bn1 2>/dev/null | head -15 || top -n1 2>/dev/null | head -15
  echo "== estimated power use (batterystats ranking) =="; dumpsys batterystats 2>/dev/null | grep -iE -A22 "Estimated power use" | head -24
  echo "== wake locks (power) =="; dumpsys power 2>/dev/null | grep -iE -A15 "wake lock|Wake Locks" | head -20'
grab env/app-context.txt "AccA runtime context (foreground/top activity, standby bucket, USB typec/PD)" sh -c '
  echo "== foreground/top activity =="; dumpsys activity activities 2>/dev/null | grep -iE "mResumedActivity|topResumedActivity|'"$PKG"'" | head -6
  echo "== app standby bucket =="; dumpsys usagestats 2>/dev/null | grep -iE "'"$PKG"'" | grep -iE "standby|bucket|package=" | head -6
  echo "== USB typec/PD =="; for t in /sys/class/typec/*; do [ -d "$t" ] || continue; echo "-- ${t##*/} --"; for n in "$t"/*; do [ -f "$n" ] && echo "  ${n##*/}=$(cat "$n" 2>/dev/null)"; done; done'

# ============================================================ CONDITIONAL heavy ============================================================
if $CRASH_SIGNAL; then
  # PRIVACY: we do NOT grab all-app logcat here. Our crash stack is already in crash/logcat-crash.txt +
  # acca-last-crash.txt + the scoped logcat; the crash tier only adds native dumps (our-process crashes).
  # attach only tombstones/anr from THIS boot (or --full): a Java crash has none, so we don't drag stale
  # native dumps; a real native crash this boot is caught. .pb protobuf sibling grabbed raw (A11+).
  _fresh=$BOOT_EPOCH; [ "$MODE" = full ] && _fresh=0
  _n=0; for tb in $(ls -t /data/tombstones/tombstone_* 2>/dev/null | head -3); do
    [ "$(stat -c %Y "$tb" 2>/dev/null || echo 0)" -gt "$_fresh" ] || continue
    # Through cpf, not a hand-rolled cp: cpf is the one place that reports what LANDED rather than
    # what was attempted, so an empty source says EMPTY instead of OK. A Mi A3 carried two zero-byte
    # ANR traces announced as "OK anr-trace (this boot)" -- the same defect this file already fixed
    # for last_kmsg and for the DropBox kernel bodies.
    cpf "crash/$(basename "$tb")" "tombstone (this boot)" "$tb"
    if [ -s "$STAGE/crash/$(basename "$tb")" ]; then _n=$((_n+1)); fi; done
  for an in $(ls -t /data/anr/* 2>/dev/null | head -2); do
    [ "$(stat -c %Y "$an" 2>/dev/null || echo 0)" -gt "$_fresh" ] || continue
    cpf "crash/anr-$(basename "$an").txt" "anr-trace (this boot)" "$an"; done
  man "NOTE   crash-signal -> $_n this-boot tombstone(s) + anr (our crash stack is in crash/logcat-crash.txt + acca-last-crash.txt; NO third-party logcat collected)"
else man "SKIP   no fresh crash signal -> tombstones/anr/full-logcat deferred (run --full to force)"; fi

if $REBOOT_SIGNAL; then
  grab android/dmesg-full.txt "dmesg FULL (reboot/panic context)" sh -c 'dmesg 2>/dev/null'
  for p in /sys/fs/pstore/*; do [ -f "$p" ] && cp -f "$p" "$STAGE/reboot/$(basename "$p").txt" 2>/dev/null && man "OK     pstore -> reboot/$(basename "$p").txt ($(wc -c <"$p")b)"; done
  cpf reboot/last_kmsg.txt "last_kmsg (legacy)" /proc/last_kmsg
  # vendor panic stores for phones WITHOUT pstore (MediaTek / Samsung) -- capture readable ones, note the dirs
  for _vp in /proc/sec_log /proc/mtk_ram_console; do [ -f "$_vp" ] && { tail -c 200000 "$_vp" > "$STAGE/reboot/vendor-${_vp##*/}.txt" 2>/dev/null; [ -s "$STAGE/reboot/vendor-${_vp##*/}.txt" ] && man "OK     vendor panic store -> reboot/vendor-${_vp##*/}.txt"; }; done
  for _vd in /data/aee_exp /sys/class/sec/sec_debug; do [ -e "$_vd" ] && man "OK     vendor panic-store dir present: $_vd (pull manually if pstore was empty)"; done
  # The kernel log belongs to THIS tier, not to --full: Android drains /sys/fs/pstore into DropBox
  # as SYSTEM_LAST_KMSG, so on a phone whose pstore has already been drained the loop above finds an
  # empty directory and the body is the only copy left. Gating it on --full meant a normal bundle
  # from a phone that had just rebooted abnormally carried no kernel log at all.
  _dbx="$STAGE/crash/dropbox-bodies"; mkdir -p "$_dbx" 2>/dev/null; _dbn=${_dbn:-0}
  _dbk=0; _dblost=0
  for f in $(ls -t /data/system/dropbox/*KMSG* /data/system/dropbox/*kmsg* /data/system/dropbox/*watchdog* 2>/dev/null | awk '!seen[$0]++'); do
    [ "$_dbk" -ge 3 ] && break
    # DropBox leaves a ZERO-BYTE *.lost placeholder where it has purged a body, and the index still
    # lists the event. Copying those announces an attachment that carries nothing and spends the
    # budget a surviving body needs -- a Mi A3 offered seven lost placeholders and no real log.
    [ -s "$f" ] || { _dblost=$((_dblost+1)); continue; }
    cp -f "$f" "$_dbx/" 2>/dev/null && { _dbk=$((_dbk+1)); _dbn=$((_dbn+1)); man "OK     dropbox kernel-body -> crash/dropbox-bodies/$(basename "$f")"; }
  done
  [ "$_dblost" -gt 0 ] && man "NOTE   $(echo $_dblost) kernel-log body/bodies already purged by DropBox (zero-byte placeholder) -- listed in the index, not attachable"
  rmdir "$_dbx" 2>/dev/null || :
  _rbn=$(ls "$STAGE/reboot"/*.txt 2>/dev/null | wc -l)
  man "NOTE   reboot-signal fired -> full dmesg + $(echo $_rbn) file(s) in reboot/ (an EMPTY pstore is normal: once Android drains it, the previous boot's kernel log is a SYSTEM_LAST_KMSG body under crash/)"
else man "SKIP   normal/no reboot signal -> pstore/last_kmsg/full-dmesg deferred (reboot-history still recorded them)"; fi

# ============================================================ EXTRA (--full only) ============================================================
if [ "$MODE" = full ]; then
  grab android/getprop-full.txt "getprop FULL" getprop
  grab android/avc-full.txt "avc FULL (all apps)" sh -c 'dmesg 2>/dev/null | grep -iE "avc: *denied"; logcat -d -b main -b system 2>/dev/null | grep -iE "avc: *denied"'
  cpf charging/power_supply-raw.log "acc raw power_supply mining dump" "$(ls -t $DD/logs/power_supply-*.log 2>/dev/null | head -1)"
  _dbx="$STAGE/crash/dropbox-bodies"; mkdir -p "$_dbx"; _dbn=${_dbn:-0}
  # Kernel bodies FIRST and on their own budget. Android drains /sys/fs/pstore into DropBox as
  # SYSTEM_LAST_KMSG, so after an abnormal reboot the previous boot's kernel log lives HERE and the
  # pstore tier above finds nothing. The old glob (crash|anr|panic|tombstone) matched none of these
  # names, so the index advertised a last_kmsg event the bundle could never carry. Kept separate from
  # the app-body loop below so a burst of ANRs cannot push the decisive file out of the head -6.
  for f in $(ls -t /data/system/dropbox/*crash* /data/system/dropbox/*anr* /data/system/dropbox/*panic* /data/system/dropbox/*tombstone* 2>/dev/null | head -6); do
    cp -f "$f" "$_dbx/" 2>/dev/null && { _dbn=$((_dbn+1)); man "OK     dropbox-body -> crash/dropbox-bodies/$(basename "$f")"; }; done
  [ "$_dbn" = 0 ] && rmdir "$_dbx" 2>/dev/null
  man "NOTE   --full -> added full getprop/avc + raw power_supply + dropbox bodies"
fi

# ============================================================ SMART DEDUP ============================================================
# last_kmsg is ~99% identical to pstore console-ramoops (same ramoops buffer, two paths). If both were
# attached, keep pstore full and reduce last_kmsg to a 60-line tail (the divergent end), noting the saving.
_pscon=$(ls "$STAGE/reboot/console-ramoops"* 2>/dev/null | head -1)
if [ -n "$_pscon" ] && [ -f "$STAGE/reboot/last_kmsg.txt" ]; then
  sort -u "$_pscon" > "$STAGE/.ps$$" 2>/dev/null; sort -u "$STAGE/reboot/last_kmsg.txt" > "$STAGE/.lk$$" 2>/dev/null
  _psl=$(wc -l <"$STAGE/.ps$$"); _lkfull=$(wc -c <"$STAGE/reboot/last_kmsg.txt")
  _common=$(comm -12 "$STAGE/.ps$$" "$STAGE/.lk$$" 2>/dev/null | wc -l); rm -f "$STAGE/.ps$$" "$STAGE/.lk$$"
  if [ "${_psl:-0}" -gt 0 ] && [ $(( _common * 100 / _psl )) -ge 90 ]; then
    tail -n 60 "$STAGE/reboot/last_kmsg.txt" > "$STAGE/reboot/last_kmsg-tail.txt" 2>/dev/null; rm -f "$STAGE/reboot/last_kmsg.txt"
    man "SMART  last_kmsg is $(( _common * 100 / _psl ))% identical to pstore -> kept 60-line tail only (saved $(( _lkfull - $(wc -c <"$STAGE/reboot/last_kmsg-tail.txt") ))b)"
  fi
fi

# ===== optional live sample =====
if $SAMPLE; then
  { echo "20s read-only sample (level status current voltage input_suspend):"
    i=0; while [ $i -lt 20 ]; do
      echo "$(date +%H:%M:%S 2>/dev/null) L=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null) S=$(cat /sys/class/power_supply/battery/status 2>/dev/null) I=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null) V=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null) sup=$(cat /sys/class/power_supply/battery/input_suspend 2>/dev/null)"
      i=$((i+1)); sleep 1
    done; } > "$STAGE/charging/sample-20s.txt"
  man "OK     20s live sample -> charging/sample-20s.txt"
fi

# ===== redaction (privacy: mask serial/MAC/email/telephony-id; keep every line) =====
_redact(){ _ser=$(getprop ro.serialno 2>/dev/null); find "$STAGE" -type f 2>/dev/null | while IFS= read -r f; do
  case "$f" in *.txt|*.log|*.json) ;; *) continue ;; esac
  sed -E \
    -e 's#\[([a-z0-9._]*serial[a-z0-9._]*)\]: \[[^]]*\]#[\1]: [REDACTED]#g' \
    -e 's#\[([a-z0-9._]*(imei|imsi|iccid|meid|android_id)[a-z0-9._]*)\]: \[[^]]*\]#[\1]: [REDACTED]#g' \
    -e 's#([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}#[MAC]#g' \
    -e 's#[A-Za-z0-9._%+-]+@[A-Za-z][A-Za-z0-9.-]*\.[A-Za-z]{2,}#[EMAIL]#g' \
    "$f" > "$f.__r" 2>/dev/null && [ -s "$f.__r" ] && mv -f "$f.__r" "$f" 2>/dev/null || rm -f "$f.__r" 2>/dev/null
  if [ ${#_ser} -ge 6 ]; then sed "s#${_ser}#[REDACTED-SERIAL]#g" "$f" > "$f.__r" 2>/dev/null && [ -s "$f.__r" ] && mv -f "$f.__r" "$f" 2>/dev/null || rm -f "$f.__r" 2>/dev/null; fi
done; }
_redact

# ===== pack =====
man ""; man "OK     redaction: serial/MAC/email/telephony-id masked"
man "schema=$SCHEMA collector=$COLLECTOR mode=$MODE sample=$SAMPLE crash=$CRASH_SIGNAL reboot=$REBOOT_SIGNAL device=$DEV time=$(date 2>/dev/null)"
BUNDLE=""
if command -v bzip2 >/dev/null 2>&1; then
  _b="$OUT/acc-diag-${DEV}-${TS}.tar.bz2"
  ( cd "$STAGE" && tar -cf - . 2>/dev/null | bzip2 -9 > "$_b" ) 2>/dev/null
  [ -s "$_b" ] && BUNDLE="$_b" || rm -f "$_b"
fi
if [ -z "$BUNDLE" ]; then
  BUNDLE="$OUT/acc-diag-${DEV}-${TS}.tgz"
  ( cd "$STAGE" && tar -czf "$BUNDLE" . 2>/dev/null ) || ( cd "$STAGE" && tar -cf - . 2>/dev/null | gzip -9 > "$BUNDLE" )
fi

echo "================ ACC diagnostic collected ================"
cat "$SUM" 2>/dev/null || :
echo
echo "[manifest] captured $(grep -c '^OK' "$MAN") sources; crash-signal=$CRASH_SIGNAL reboot-signal=$REBOOT_SIGNAL"
echo "bundle: $BUNDLE"   # machine-readable line parsed by acc.sh and the AccA app -- keep it
if [ "$MODE" = full ]; then
  echo ">> FULL report ready -- every raw log (only for a stubborn bug we asked you to capture)."
else
  echo ">> QUICK report ready -- the usual choice; a crash or reboot is auto-included."
  echo "   Asked for a full report?  run:  acc --diag --full"
fi
echo
echo "   YOUR REPORT FILE:"
echo "     $BUNDLE"
echo "   SEND IT TO US -- pick one:"
echo "     - in Termux:     termux-open --send '$BUNDLE'   (opens the Share menu)"
echo "     - file manager:  open Downloads, tap this file, then Share"
echo "   Privacy: this reads only your charging, reboot and root-module info, plus this app. Serial/MAC/email stripped."
echo "=========================================================="
rm -rf "$STAGE"
