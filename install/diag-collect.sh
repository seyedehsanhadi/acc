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
MODE=quick; SAMPLE=false; SAMPLE_SECS=20
for a in "$@"; do case "$a" in
  --full) MODE=full ;;
  --quick|--core|--min) MODE=quick ;;
  --sample) SAMPLE=true ;;
  --sample=*) SAMPLE=true; SAMPLE_SECS=${a#--sample=} ;;
esac; done

# THE TWO TIERS ARE NOW ACTUALLY DIFFERENT. `--core` gated only the EXTRA block and the crash/reboot
# conditionals, so it collected essentially everything: measured on a Mi A3 it ran 267s against the
# full run's 176s -- a "quick" mode that was not quick, and nobody could tell because the two were
# never timed side by side.
#
# QUICK is the set that answers a report on its own: what ACC decided (state.json, flight log, its
# own traces and ledgers), what it decided it WITH (config, switch, live snapshot, power_supply),
# what it is holding right now (the runtime latches), whether the daemon is alive, and whether the
# phone rebooted or powered off. FULL adds the corroborating bulk -- dmesg, logcat, getprop, avc,
# the AccA database, the vendor-specific probes -- which is decisive perhaps one report in five and
# costs the other four a multi-minute wait.
#
# Sources are named rather than tiered inline: one list is auditable in a glance, and the alternative
# is a mode test wrapped around forty scattered calls.
_QUICK='
 state.json config.txt config-active.txt acc-journals.txt amps-verified.txt
 charging/acc-i.txt charging/power-supply.txt charging/switches.txt
 acc-logs/flight.log acc-logs/warnings.log acc-logs/write.log acc-logs/write-ledger.txt
 acc-logs/shutdown-trace.log acc-logs/accd-trace-tail.txt acc-logs/acc-cli-trace-tail.txt
 acc-logs/backup-module.prop acc-logs/plugins.txt acc-logs/schedules.txt
 env/runtime-state.txt env/daemon-detail.txt env/modules.txt env/env.txt
 reboot/bootreason.txt reboot/reboot-history.txt
 crash/acca-last-crash.txt crash/acca-breadcrumbs.txt
 charging/dumpsys-battery.txt crash/dropbox-index.txt android/avc-scoped.txt
'
# Collapse the newlines the list is written with: the membership test below matches " name ", so an
# entry sitting at the end of a line would never match.
_QUICK=" $(echo $_QUICK) "
# true when this destination is collected in the current mode
_want(){ [ "$MODE" = full ] && return 0
  # kernel/ is the previous boot's own account of itself -- last_kmsg and the pstore variants. On a
  # "my phone turned itself off" report that is often the only thing that answers the question, which
  # makes it quick-tier by the same rule as shutdown-trace.log. Dropping it cost a real failure:
  # t64 caught the A3 producing neither the file nor the EMPTY manifest line for /proc/last_kmsg.
  # Matched by prefix because the pstore destinations are named after whatever the kernel exposes.
  case "$1" in kernel/*) return 0 ;; esac
  case "$_QUICK" in *" $1 "*) return 0 ;; esac
  return 1; }
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
true > "$MAN"; true > "$SUM"; true > "$FS"

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
else
  # NO APPLET, NO EXCUSE. Degrading to running bare meant every bound in this file was inert on any
  # device without busybox -- which is the Mi A3: its full bundle took 8m36s against 1m21s on a
  # Pixel, and one source (a find over /sys and /proc) ran 56s inside a guard that advertised 30.
  # A user waiting nine minutes at a blank screen is the failure this whole tier was written to
  # prevent, and it hit hardest on the slowest phones, which are the ones most likely to be
  # reporting a bug. Background the command, poll for it, kill it when the deadline passes: the
  # shell can do this alone and the semantics (exit 124 on overrun) match timeout(1).
  # The deadline is wall clock, not an iteration count: counting `sleep 1` rounds assumes the sleep
  # and the fork are free, and on the A3 a "3 second" bound measured 8 seconds. A fractional sleep,
  # where the shell has one, also keeps the common case (a source that finishes at once) from
  # paying a full second per collection -- 54 sources is a minute of pure polling.
  _TSLP=1; sleep 0.2 2>/dev/null && _TSLP=0.2
  _tmo(){ _t=$1; shift
    "$@" & _tpid=$!
    _tend=$(( $(date +%s 2>/dev/null || echo 0) + _t ))
    while kill -0 "$_tpid" 2>/dev/null; do
      [ "$(date +%s 2>/dev/null || echo 0)" -ge "$_tend" ] && {
        # Kill the GRANDCHILDREN too. Every bounded source here is an `sh -c` wrapper, so killing
        # the wrapper alone leaves the dumpsys or find inside it running and still holding the
        # output file -- the bound reports 124 while the phone keeps working, which is the hang the
        # bound exists to prevent.
        ps -A -o pid,ppid 2>/dev/null | while read -r _cp _pp; do
          [ "$_pp" = "$_tpid" ] && kill -9 "$_cp" 2>/dev/null; done
        kill -9 "$_tpid" 2>/dev/null; wait "$_tpid" 2>/dev/null; return 124; }
      sleep $_TSLP
    done
    wait "$_tpid" 2>/dev/null; return $?; }
fi
# grab CMD... into a staged file
# _n holds the destination because `shift 2` has already moved it out of $1 by the time the manifest
# line is written. Without it every grab entry named the COMMAND it ran - 22 of the 45 lines in a
# bluejay bundle read "-> sh" - so a responder looking for those files had nothing to look for.
# A bundle that took 8.6 minutes on a Mi A3 and 81 seconds on a Pixel, same collector and same
# flags, cannot be tuned by guessing: nothing recorded WHICH source ate the time. Stamp the slow
# ones into the manifest -- only >=3s, so a fast run stays silent -- and the next slow bundle names
# its own culprit instead of costing another round trip.
_SLOWLOG="$STAGE/.slow"
_T_RUN0=$(date +%s 2>/dev/null || echo 0)
grab(){ _want "$1" || { man "SKIP   $2 (not in quick tier -- run --full)"; return 0; }
  _o="$STAGE/$1"; _n="$1"; _l="$2"; shift 2
  _t0=$(date +%s 2>/dev/null || echo 0)
  _tmo "$DIAG_TMO" "$@" > "$_o" 2>/dev/null; _rc=$?
  _t1=$(date +%s 2>/dev/null || echo 0); _el=$(( _t1 - _t0 ))
  [ "$_el" -ge 1 ] 2>/dev/null && echo "$_el $_n" >> "$_SLOWLOG"
  if [ "$_rc" = 124 ]; then man "TIMEOUT $_l (over ${DIAG_TMO}s; partial output kept if any)"; fi
  if [ -s "$_o" ]; then man "OK     $_l -> ${_n} ($(wc -c <"$_o")b)"; else man "EMPTY  $_l"; rm -f "$_o"; fi; }
# FILTERED grab: keep only lines matching PATTERN; record raw->kept in _FILTERSTATS (loss accounting)
grabf(){ _want "$1" || { man "SKIP   $2 (not in quick tier -- run --full)"; return 0; }
  _o="$STAGE/$1"; _l="$2"; _pat="$3"; _nm="$1"; shift 3; _raw="$STAGE/.raw$$"
  _t0=$(date +%s 2>/dev/null || echo 0)
  _tmo "$DIAG_TMO" "$@" > "$_raw" 2>/dev/null; _rc=$?
  _t1=$(date +%s 2>/dev/null || echo 0); _el=$(( _t1 - _t0 ))
  [ "$_el" -ge 1 ] 2>/dev/null && echo "$_el $_nm" >> "$_SLOWLOG"
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
cpf(){ _want "$1" || { man "SKIP   $2 (not in quick tier -- run --full)"; return 0; }
  if [ -f "$3" ]; then
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
tailcpf(){ _want "$1" || { man "SKIP   $2 (not in quick tier -- run --full)"; return 0; }
  if [ -f "$3" ]; then tail -n "$4" "$3" > "$STAGE/$1" 2>/dev/null
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
  [ "$MODE" = quick ] && echo "  QUICK tier: ACC's own decisions, inputs, latches and reboot record. For dmesg/logcat/getprop/avc/AccA-db: acc --diag --full"
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
      _c=$(_tmo 5 sh -c 'tr "\0" " " < "$1"' sh "/proc/$_p/cmdline" 2>/dev/null)
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
  # APatch reports through neither `magisk -V` nor `ksud -V`. A kansas (moto g 2025) bundle read
  # "magisk=n/a ksud=n/a" beside a live daemon, which reads as "no root at all" -- the wrong first
  # question to ask a user whose module is plainly running. Its marker is its own busybox tree.
  _rap=n/a; [ -d /data/adb/ap ] && _rap=$(cat /data/adb/ap/version 2>/dev/null || echo present)
  echo "  root   : magisk=$(magisk -V 2>/dev/null || echo n/a) ksud=$(ksud -V 2>/dev/null || echo n/a) apatch=$_rap  busybox=$(command -v busybox >/dev/null && echo yes || echo no)  crypto=$(getprop ro.crypto.state)"
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
  # BUILD FINGERPRINT. The version string is hand-bumped and lags the code: a kansas bundle and a
  # bluejay bundle both said v2025.5.18-6.5.1-rc25-test21 / 202505354 while their accd.sh differed
  # (one wrote 11 flight fields, the other 12). Version alone therefore cannot answer "which code
  # is this user actually running", which is the first question of every bug report. Hash the two
  # files that decide behaviour; degrade to size+mtime where no md5 applet exists.
  _fp(){ [ -f "$1" ] || { echo "absent"; return; }
    md5sum "$1" 2>/dev/null | cut -c1-8 || echo "$(wc -c <"$1" 2>/dev/null)b/$(date -r "$1" +%m%d-%H%M 2>/dev/null)"; }
  echo "  build  : accd=$(_fp $E/accd.sh) acc=$(_fp $E/acc.sh) batt-if=$(_fp $E/batt-interface.sh)  (hash, not version -- compare across bundles)"
  # IS THE FLIGHT RECORDER CARRYING TEMPERATURE? Field 12 is the raw pack temperature and it is the
  # only temperature history a bundle has; the collector's own reads are single instants, and by the
  # time a user collects, a phone that tripped max_temp an hour ago has cooled. A kansas bundle wrote
  # 11 fields where a bluejay on the same version string wrote 12 -- so the column can be missing
  # either because the running accd predates it or because $temp never resolved on that device, and
  # a thermal report is unanswerable in both cases. Say so here rather than letting a responder
  # count commas.
  _flf=$(tail -1 "$DD/logs/flight.log" 2>/dev/null | awk -F, '{print NF}' 2>/dev/null)
  case "${_flf:-0}" in
    0) echo "  flight : NO RECORDS -- the daemon has written no flight log (see acc-logs/)" ;;
    *) [ "${_flf:-0}" -ge 12 ] 2>/dev/null && : || echo "  flight : ${_flf} fields, NO TEMPERATURE COLUMN -- this build's recorder predates field 12, or \$temp never resolved on this device. Thermal reports (max_temp/shutdown_temp) CANNOT be answered from this bundle." ;;
  esac
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
  # ============================ WHAT ACTUALLY HAPPENED ============================
  # A user wrote that his pack passed max_temp and charging did not stop, and the bundle could not
  # settle it: the collector's temperature is the single instant it ran, and by then the phone had
  # cooled. The history was there all along -- flight.log carries temperature in field 12 and the
  # charge state beside it -- but nothing read it, so the one question the report asked went
  # unanswered while its evidence sat in the bundle.
  #
  # The daemon cannot answer it either: flight_rec is called untagged everywhere (accd.sh:1125), so
  # every line reads "loop". The log records STATE, never a decision. What it does record is enough
  # to settle the question by inference: if field 12 says ACC read 47C while max_temp was 45 and the
  # next samples still say Charging with chDisabledByAcc=false, then ACC saw the temperature and did
  # not act -- which is the finding. Cheap, too: awk over a file that is already in the bundle.
  #
  # Temperature unit: raw kernel value, so >=100 is deci-C (251 = 25.1C) and below that is whole C.
  # tempFactor is not applied here -- it is in the config beside this, and guessing with it would
  # make a wrong reading look like a right one.
  echo "[what happened, from flight.log -- ACC's own record]"
  if [ -s "$DD/logs/flight.log" ]; then
    _cfgT=$(grep -m1 '^temperature=' "$DD/config.txt" 2>/dev/null | tr -d 'temperature=()')
    _cfgC=$(grep -m1 '^capacity=' "$DD/config.txt" 2>/dev/null | tr -d 'capacity=()')
    awk -F, -v T="$_cfgT" -v C="$_cfgC" '
      BEGIN { split(T,t," "); ct=t[1]; mt=t[2]; rt=t[3]; st=t[4]
              split(C,c," "); pcap=c[4]
              first=0; gap=0; plug=0; unplug=0; n=0; tmin=99999; tmax=-99999
              hotmax=0; hotmax_charging=0; hotshut=0; hotshut_on=0; over=0; prevpres=""; pgap=0 }
      NF<4 { next }
      { n++; ts=$1+0; cap=$2+0; st4=$4; pres=$6+0; dis=$7; raw=$12
        if (first==0) { first=ts; prevts=ts }
        # A gap only means something WHILE PLUGGED. Unplugged the loop naps and Android dozes, so an
        # idle phone shows 40-60min gaps that are correct behaviour -- both test phones did, and
        # warning on those would cry wolf on every overnight bundle. Plugged, the daemon is meant to
        # be deciding every few seconds, so a gap there is the "daemon hung while acc.lock said
        # alive" signature that flight.log is the only honest witness to.
        if (ts-prevts > gap) gap=ts-prevts
        if (pres==1 && prevpres==1 && ts-prevts > pgap) pgap=ts-prevts
        prevts=ts; last=ts; lastcap=cap
        if (prevpres!="" && pres==1 && prevpres==0) plug++
        if (prevpres!="" && pres==0 && prevpres==1) unplug++
        prevpres=pres
        charging = (st4=="Charging" && dis=="false")
        if (charging && pcap>0 && cap>pcap) over++
        if (raw ~ /^-?[0-9]+$/ && raw != "") {
          tc = (raw+0 >= 100 || raw+0 <= -100) ? (raw+0)/10 : raw+0
          if (tc<tmin) tmin=tc; if (tc>tmax) tmax=tc
          if (mt>0 && tc>=mt) { hotmax++; if (charging) hotmax_charging++ }
          if (st>0 && tc>=st) { hotshut++; if (charging) hotshut_on++ }
          tseen++ } }
      END {
        if (n==0) { print "  (flight log present but empty)"; exit }
        dur=(last-first)/3600
        printf "  window   : %.1fh of daemon history, %d samples, largest gap %.0fmin (unplugged naps are normal)\n", dur, n, gap/60
        if (pgap>600)
          printf "  (!) daemon: %.0fmin with NO flight record WHILE PLUGGED -- the loop was not running. acc.lock and a live PID do not prove it was; this file is the only honest heartbeat.\n", pgap/60
        printf "  plugged  : %d plug-in, %d unplug events; battery %d%% at the end\n", plug, unplug, lastcap
        if (tseen==0)
          print "  temp     : NO TEMPERATURE IN THE LOG (field 12 absent) -- a thermal report CANNOT be answered from this bundle"
        else {
          printf "  temp     : %.1fC min, %.1fC max over the window (config: cooldown %s, max %s, resume %s, shutdown %s)\n", tmin, tmax, ct, mt, rt, st
          if (hotmax==0 && hotshut==0)
            printf "  thermal  : the pack never reached max_temp (%sC) while the daemon was watching -- a thermal complaint about THIS window has no basis in the data\n", mt
          if (hotmax>0 && hotmax_charging==0)
            printf "  thermal  : reached max_temp (%sC) on %d samples and charging was stopped every time -- the limit WORKED\n", mt, hotmax
          if (hotmax_charging>0)
            printf "  (!) thermal: ACC READ >=max_temp (%sC) on %d samples AND WAS STILL CHARGING on %d of them -- it saw the temperature and did not pause. This is the defect, not a missing reading.\n", mt, hotmax, hotmax_charging
          if (hotshut>0)
            printf "  (!) thermal: reached shutdown_temp (%sC) on %d samples (%d while charging) -- check acc-logs/shutdown-trace.log: an entry means ACC powered off, NO entry means it did not fire\n", st, hotshut, hotshut_on
        }
        if (over>0)
          printf "  (!) limit : charging continued above pause_capacity (%s%%) on %d samples -- the limit did not hold\n", pcap, over
        else if (pcap>0) printf "  limit    : never charged past pause_capacity (%s%%) in this window\n", pcap
      }' "$DD/logs/flight.log" 2>/dev/null
  else
    echo "  NO FLIGHT LOG -- the daemon has written no charge history. Nothing here can be answered from behaviour; start with env/daemon-detail.txt."
  fi
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
# THIRD FALLBACK IS THE ONLY ONE THAT SURVIVES A BROKEN INSTALL. /dev/acc is a symlink and `acc`
# needs a PATH entry; a bluejay left with /dev/acc pointing at a deleted staging tree produced an
# EMPTY acc-i.txt -- the live snapshot missing in exactly the state that most needs explaining.
# $E/acc.sh is the file on disk and cannot be dangling.
grab charging/acc-i.txt        "acc live snapshot (acc -i: STATUS/CURRENT/INPUT_SUSPEND/CTRL_LIMIT)" sh -c '/dev/acc -i 2>/dev/null || acc -i 2>/dev/null || /system/bin/sh '"$E"'/acc.sh -i 2>/dev/null'
# One fork, not 210. The old loop read 21 named nodes across every supply with a cat each and
# ONE grep per supply, not 21 reads. Measured on a Mi A3: 21 `cat`s per supply cost 19s, 21 greps
# cost 15s, a single grep -E over each supply's uevent costs 0s. Same values -- the kernel builds
# uevent from the same properties -- and the curated name list survives as the filter.
# Nodes a driver exposes as a file but omits from uevent are appended after.
grab charging/power-supply.txt "power_supply full nodes (health/charge_type/limits/counter/full)" sh -c '
  for s in /sys/class/power_supply/*; do [ -f "$s/uevent" ] || continue
    echo "== ${s##*/} =="
    grep -E "^POWER_SUPPLY_(TYPE|STATUS|PRESENT|ONLINE|HEALTH|CHARGE_TYPE|CAPACITY|TEMP|VOLTAGE_NOW|CURRENT_NOW|POWER_NOW|INPUT_SUSPEND|CHARGE_CONTROL_LIMIT|CHARGE_CONTROL_LIMIT_MAX|INPUT_CURRENT_LIMIT|CONSTANT_CHARGE_CURRENT_MAX|CONSTANT_CHARGE_VOLTAGE_MAX|CHARGE_COUNTER|CHARGE_FULL|CHARGE_FULL_DESIGN|CHARGE_STOP_LEVEL|CHARGE_START_LEVEL)=" "$s/uevent" 2>/dev/null | sed "s/^POWER_SUPPLY_/  /"
    for n in charge_stop_level charge_start_level input_suspend charge_control_limit; do
      [ -f "$s/$n" ] && ! grep -q "^POWER_SUPPLY_$(echo $n | tr a-z A-Z)=" "$s/uevent" 2>/dev/null \
        && echo "  $n=$(cat "$s/$n" 2>/dev/null)"; done; done'
grab charging/power-supply-uevent.txt "power_supply FULL uevent (EVERY driver prop -- generic; catches nodes the curated list misses)" sh -c '
  for s in /sys/class/power_supply/*; do [ -f "$s/uevent" ] && { echo "== ${s##*/} =="; cat "$s/uevent" 2>/dev/null; }; done'
grab charging/battery-defender.txt "battery-defender / trickle counters (a vendor charge cap ACC does not set and cannot override)" sh -c '
  _any=0
  for s in /sys/class/power_supply/*; do
    [ -d "$s" ] || continue
    for n in bd_trickle_cnt bd_trickle_dry_run bd_trickle_reset_sec bd_trickle_recharge_soc \
             bd_clear charge_disable charging_enabled batt_slate_mode; do
      v=$(cat "$s/$n" 2>/dev/null); [ -n "$v" ] && { echo "${s##*/}/$n = $v"; _any=1; }
    done
  done
  [ "$_any" = 1 ] || echo "(no defender/trickle nodes on this device)"'
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
    # EVERY readable node in that directory. On this driver the firmware owns the charge current
    # whenever the native limit is active, so "ACC asked for X and the pack draws Y" is only
    # answerable from that driver own state - the defender counters especially.
    echo "    -- full $_gcsl node dump --"
    for _n in "$_gcsl"/*; do
      [ -f "$_n" ] || continue
      _v=$(head -1 "$_n" 2>/dev/null) || continue
      [ -n "$_v" ] || continue
      echo "       ${_n##*/} = $_v"
    done
  else
    echo "  generic switch path (no native firmware limit in use)"
  fi
  echo "    configured chargingSwitch = $(grep -m1 "^chargingSwitch=" '"$DD"'/config.txt 2>/dev/null)"
  echo "== candidates/working (acc-data) =="; for f in '"$DD"'/logs/*compat* '"$DD"'/logs/switch* '"$DD"'/logs/*ctrl-files* '"$DD"'/logs/acc-p*; do [ -f "$f" ] && { echo "-- ${f##*/} --"; cat "$f" 2>/dev/null; }; done'
# `grep . file1 file2 ...` reads every zone in ONE fork; the old loop forked twice per zone, so a
# phone with 80 zones paid 160 processes. Measured 23s on a Mi A3.
grab charging/thermal.txt      "thermal (zones + throttle)" sh -c 'dumpsys thermalservice 2>/dev/null; echo "---- zones (type=temp) ----"
  grep -H . /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sed "s#/sys/class/thermal/##;s#/temp:#=#" > "$TMPDIR/.tzv" 2>/dev/null
  grep -H . /sys/class/thermal/thermal_zone*/type 2>/dev/null | sed "s#/sys/class/thermal/##;s#/type:#=#" |
  while IFS== read -r _z _t; do echo "$_t=$(grep -m1 "^$_z=" "$TMPDIR/.tzv" 2>/dev/null | cut -d= -f2)"; done
  rm -f "$TMPDIR/.tzv"'
grab charging/doze-power.txt   "doze/deviceidle + power (standby drain, schedule-miss)" sh -c 'echo "== deviceidle =="; dumpsys deviceidle 2>/dev/null; echo; echo "== power (head) =="; dumpsys power 2>/dev/null | head -120'
grab charging/dumpsys-battery.txt "dumpsys battery (HAL snapshot)" sh -c 'dumpsys battery 2>/dev/null'

# --- reboot (persistent record always; raw dumps are CONDITIONAL) ---
grab reboot/bootreason.txt "boot/reset reason: canonical + raw + history + PON/POFF latch + bootstat" sh -c '
  getprop | grep -iE "boot.?reason"; echo "---- PON/POFF (Qualcomm PMIC latch, if exposed) ----"
  # A wildcard find over /sys and /proc for this latch measured 87 SECONDS on a Mi A3 and returned
  # nothing on any phone here -- it was the entire cost of this source. The latch lives at a handful
  # of known Qualcomm paths; probing them directly costs 0s and finds it where it exists.
  for f in /sys/module/qpnp_power_on/parameters/pon_reason /sys/module/qpnp_power_on/parameters/poff_reason            /sys/class/qcom-power-on/*/pon_reason /sys/class/qcom-power-on/*/poff_reason            /proc/pon_reason /proc/poff_reason /sys/devices/platform/soc/*/qcom,power-on*/pon_reason; do
    [ -f "$f" ] && echo "$f = $(cat "$f" 2>/dev/null | head -1)"; done
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
cpf acc-logs/warnings.log   "acc warnings" "$DD/warnings.log"
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
# kernel/bootreason.txt re-ran a whole `getprop` for the same keys reboot/bootreason.txt had just
# collected. On a Mi A3 getprop is slow enough that the pair cost a minute between them.
if [ -s "$STAGE/reboot/bootreason.txt" ]; then
  grep -iE 'bootreason|boot.reason|last.reboot' "$STAGE/reboot/bootreason.txt" > "$STAGE/kernel/bootreason.txt" 2>/dev/null
  [ -s "$STAGE/kernel/bootreason.txt" ] && man "OK     why the device last booted -> kernel/bootreason.txt ($(wc -c <"$STAGE/kernel/bootreason.txt")b, reused from reboot/bootreason.txt)" || rm -f "$STAGE/kernel/bootreason.txt"
else
  grab kernel/bootreason.txt "why the device last booted" sh -c "getprop | grep -iE 'bootreason|boot.reason|last.reboot' 2>/dev/null"
fi
cpf acc-logs/early-cap.log  "acc early-cap (boot-time charge guard)" "$DD/logs/early-cap.log"
tailcpf acc-logs/init-tail.log    "acc init (recent)"    "$DD/logs/init.log" 800
tailcpf acc-logs/install-tail.log "acc install (recent)" "$DD/logs/install.log" 800
_acd=$(ls -t $T/accd-*.log 2>/dev/null | head -1); [ -n "$_acd" ] && tailcpf acc-logs/accd-trace-tail.txt "accd loop trace (recent)" "$_acd" 1500
# THE CLI TRACE, which is a different file from the daemon's. `acc -s` runs as its own process and
# writes acc-<device>.log; a scheduled profile switch that failed is recorded THERE and nowhere
# else. A OnePlus 8 Pro bundle carried a 141 KB CLI trace that no bundle ever collected, so the
# one command under investigation was the one thing missing. Excludes accd-*.log, taken above.
_acl=$(ls -t $T/acc-*.log 2>/dev/null | grep -v '/accd-' | head -1); [ -n "$_acl" ] && tailcpf acc-logs/acc-cli-trace-tail.txt "acc CLI trace (recent) - where a failed acc -s is recorded" "$_acl" 1500
grab acc-logs/schedules.txt "scheduled profiles: what fired today, what it ran, and any failed attempts" sh -c 'echo "== now: $(date +%H:%M:%S) =="; if [ -d '"$T"'/schedules ]; then for s in '"$T"'/schedules/*; do [ -e "$s" ] || continue; echo "-- ${s##*/} --"; cat "$s" 2>/dev/null; done; else echo "(no schedules directory - nothing has fired since boot)"; fi; echo "== at lines in the config =="; grep -n "^:" "'"$DD"'/config.txt" 2>/dev/null || echo "(none)"' 
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
  # A TAIL OF AN ARCHIVE IS NOT AN ARCHIVE. This sweep takes whatever is in acc-data/logs, and that
  # directory is not all text: the 2026-09-09 Fairphone 5 bundle carried acc-logs-FP5.tgz at
  # EXACTLY 50000 bytes, headerless, `file` calling it "data" and tar refusing it -- while the
  # manifest recorded "OK". The one file in the bundle nobody could open was the one the collector
  # itself had truncated, and it said so nowhere.
  #
  # Text is tailed as before, because the last 50 kB of a log is the useful part. A compressed or
  # otherwise binary blob is only useful whole: take it if it fits, and say plainly that it was
  # skipped if it does not, rather than shipping a fragment that reads as a corrupt file.
  _oversize=0; [ "$(wc -c <"$_f" 2>/dev/null || echo 0)" -gt 50000 ] && _oversize=1
  case "$_bn" in
    *.gz|*.tgz|*.bz2|*.tbz2|*.xz|*.zip|*.zst|*.png|*.jpg|*.pb|*.bin|*.db|*.dump)
      if [ "$_oversize" = 1 ]; then
        man "SKIP   binary, ${_bn} is $(wc -c <"$_f" 2>/dev/null) bytes - a tail of it would not open"
        continue
      fi
      cp -f "$_f" "$STAGE/acc-logs/$_bn" 2>/dev/null ;;
    *)
      if [ "$_oversize" = 1 ]; then tail -c 50000 "$_f" > "$STAGE/acc-logs/$_bn" 2>/dev/null
      else cp -f "$_f" "$STAGE/acc-logs/$_bn" 2>/dev/null; fi ;;
  esac
  [ -s "$STAGE/acc-logs/$_bn" ] && man "OK     acc log (swept, unenumerated)$([ "$_oversize" = 1 ] && echo ', tailed to 50000b') -> acc-logs/$_bn"
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
  # AccA does NOT install DJS as a Magisk module: Djs.isDjsInstalled() tests
  # <app filesDir>/djs/service.sh, so looking only under /data/adb/modules/djs reported
  # "(not installed)" on phones that had it. Two bundles were collected that way while the user was
  # asking why his schedules had not run, and neither could answer the question.
  echo "== djs module =="
  { grep -h "^version" /data/adb/modules/djs/module.prop 2>/dev/null     || grep -h "^version" /data/adb/vr25/djs/module.prop 2>/dev/null     || { [ -f /data/data/'"$PKG"'/files/djs/service.sh ] && echo "installed in app filesDir (no module.prop)"; }     || echo "(not installed)"; }
  echo "== install paths =="
  for _d in /data/adb/modules/djs /data/adb/vr25/djs /data/data/'"$PKG"'/files/djs; do
    [ -e "$_d" ] && echo "  present: $_d" || echo "  absent:  $_d"
  done
  # pgrep -f matches THIS shell too: the pattern is in our own command line, so the answer was
  # always "yes" whether or not anything was scheduled.
  echo "== running =="; pgrep -f "[d]js.sh" >/dev/null && echo yes || echo no
  # The runtime AccA actually drives is /dev/.vr25/djs/djsc, and its --list is the only thing that
  # can answer "are my schedules there". Two bundles were collected while that was the question and
  # neither said anything about it.
  echo "== djsc runtime =="
  if [ -x /dev/.vr25/djs/djsc ]; then
    echo "  /dev/.vr25/djs/djsc present"
    echo "== schedules (djsc --list) =="; /dev/.vr25/djs/djsc --list . 2>&1 | head -40
  else
    echo "  /dev/.vr25/djs/djsc ABSENT -- AccA schedules cannot run"
  fi
  echo "== schedules/last-run (files) =="; for s in $(find /data/adb/vr25 /data/adb/djs /data/data/'"$PKG"'/files -iname "*djs*" -type f 2>/dev/null | head -8); do echo "-- $s --"; tail -20 "$s" 2>/dev/null; done'
grab env/daemon-detail.txt "daemon process state (all PIDs=concurrency, stat=D=hung, runtime UID, tmpfs+data listing)" sh -c '
  # `pgrep -f accd.sh` matches THIS collector: the pattern is inside our own command line, so the
  # two staging shells are listed as daemons under a header that calls more than one a concurrent-
  # write risk. A bluejay bundle reported 3 PIDs for 1 daemon. Drop our own process group.
  _selfpg=$$; _accpids=""; for _p in $(pgrep -f accd.sh 2>/dev/null); do
    [ "$_p" = "$_selfpg" ] && continue
    case "$(ps -o cmd -p $_p 2>/dev/null)" in *diag-collect*|*_MANIFEST*|*pgrep*) continue ;; esac
    _accpids="$_accpids $_p"; done
  echo "== accd processes (pid + cmdline; more than one = concurrent-write risk) =="
  if [ -n "${_accpids# }" ]; then for _p in $_accpids; do echo "$_p $(ps -o cmd -p $_p 2>/dev/null | grep -v "^ *CMD" | head -1)"; done
  else echo "(none -- daemon down)"; fi
  echo "== ps state (STAT D = stuck in kernel; USER must be root) =="; for _p in $_accpids; do ps -o pid,user,stat,wchan,cmd -p $_p 2>/dev/null | grep -v "^\s*PID"; done
  echo "== selinux: $(getenforce 2>/dev/null) =="
  echo "== su on PATH: $(command -v su 2>/dev/null || echo NO) =="
  echo "== tmpfs runtime ('"$T"') =="; ls -la '"$T"' 2>/dev/null
  echo "== data dir ('"$DD"') =="; ls -la '"$DD"' 2>/dev/null'
# THE LATCHES, NOT JUST THEIR NAMES. daemon-detail lists these files; until now nothing read them.
# Every one is the daemon's own conclusion about this phone -- the learned polarity anchor, the
# current source, the native-limit holds, the last switch known to work, the warn flags -- and the
# last three product bugs (polarity unstable latch, native limit latched, temp hold) turned on
# exactly these values. Together they are under 2 KB, so there is no reason not to carry them.
grab env/runtime-state.txt "daemon LATCHES: learned polarity, current source, native holds, last good switch, warn flags (the values, not the filenames)" sh -c '
  for _f in '"$T"'/.batt-interface.sh '"$T"'/.config '"$T"'/.cc-src '"$T"'/.cc_then '"$T"'/.bc-cache             '"$T"'/.mcc '"$T"'/.dummy-mcc '"$T"'/.dummy-temp '"$T"'/.nthot '"$T"'/.nvheld '"$T"'/.dpol             '"$T"'/.nap-ref '"$T"'/acc.lock '"$T"'/ch-curr-ctrl-files '"$T"'/.hvcontract '"$T"'/.hvrecover             '"$DD"'/.se-polarity '"$DD"'/.se-cc '"$DD"'/.last-good-switch '"$DD"'/.user-locked             '"$DD"'/.reboot-archived-boot '"$DD"'/.mtk-currentcmd-revert; do
    [ -e "$_f" ] || continue
    echo "-- ${_f} --"; head -c 2048 "$_f" 2>/dev/null; echo; done
  echo "-- warn flags --"
  for _w in '"$DD"'/.warn-*; do [ -e "$_w" ] || continue; echo "  ${_w##*/} = $(head -c 64 "$_w" 2>/dev/null)"; done
  echo "-- state-export dir ('"$T"'/.se) --"
  for _f in '"$T"'/.se/*; do [ -f "$_f" ] || continue; echo "  ${_f##*/} = $(head -c 200 "$_f" 2>/dev/null)"; done'

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
  # A ramoops console buffer is 2 MB and it is the reason a "quick" bundle from a Pixel weighed
  # 582 KB compressed. The panic or the shutdown message is at the END of that buffer, so quick
  # takes the last 2000 lines and full takes the whole thing.
  for p in /sys/fs/pstore/*; do [ -f "$p" ] || continue
    if [ "$MODE" = full ]; then cp -f "$p" "$STAGE/reboot/$(basename "$p").txt" 2>/dev/null       && man "OK     pstore -> reboot/$(basename "$p").txt ($(wc -c <"$p")b)"
    else tail -n 2000 "$p" > "$STAGE/reboot/$(basename "$p").txt" 2>/dev/null       && man "OK     pstore (last 2000 lines; --full for all $(wc -c <"$p")b) -> reboot/$(basename "$p").txt ($(wc -c <"$STAGE/reboot/$(basename "$p").txt")b)"; fi; done
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
# reboot/ and kernel/ each copied /sys/fs/pstore/console-ramoops-0, byte for byte: a bluejay bundle
# carried the same 2,097,058-byte file twice (md5 20b71688...). Same ramoops buffer, two collectors
# that never knew about each other. Keep the kernel/ copy, point at it from reboot/.
for _dupe in console-ramoops-0 console-ramoops dmesg-ramoops-0; do
  _a="$STAGE/kernel/pstore-$_dupe.txt"; _b="$STAGE/reboot/$_dupe.txt"
  [ -f "$_a" ] && [ -f "$_b" ] || continue
  [ "$(wc -c <"$_a")" = "$(wc -c <"$_b")" ] || continue
  _sz=$(wc -c <"$_b"); rm -f "$_b"
  echo "identical to kernel/pstore-$_dupe.txt (${_sz}b) -- deduplicated, read that file" > "$_b"
  man "SMART  reboot/$_dupe.txt was byte-identical to kernel/pstore-$_dupe.txt -> deduplicated (saved ${_sz}b)"
done
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
  # TEMPERATURE BELONGED HERE FROM THE START. This is the only series the collector takes itself,
  # and a thermal complaint (max_temp did not pause, shutdown_temp did not fire) is answered by a
  # temperature trend or not at all. The rest of the row was already here; T was not.
  #
  # Duration is `--sample[=SECONDS]` because 20s shows a thermal ramp nothing at all, while a user
  # who is holding the phone plugged in can afford a minute. Default stays 20s -- the collector is
  # one-tap and the wait is already 30-60s before this runs -- and it is capped at 300s so no
  # mistyped argument leaves a user staring at a dead screen.
  case "$SAMPLE_SECS" in ''|*[!0-9]*) SAMPLE_SECS=20 ;; esac
  [ "$SAMPLE_SECS" -lt 5 ] && SAMPLE_SECS=5; [ "$SAMPLE_SECS" -gt 300 ] && SAMPLE_SECS=300
  # THE TICK IS `read`, A BUILTIN. Six `cat`s per second measured 60s of wall clock for a sample
  # calling itself 20 seconds -- the sample was three times longer than it claimed. Piping uevent
  # through grep was no better (measured 12s vs 13s per 10 ticks); parsing it with the shell's own
  # `read` is 3s. battery/uevent carries every field; input_suspend is not a uevent property, so it
  # is read only where the file exists.
  _SUPN=/sys/class/power_supply/battery/input_suspend; [ -f "$_SUPN" ] || _SUPN=
  { echo "${SAMPLE_SECS}s read-only sample (level status current voltage temp input_suspend):"
    i=0; while [ $i -lt "$SAMPLE_SECS" ]; do
      _L= _S= _I= _V= _T=
      while IFS== read -r _k _v; do case "$_k" in
        POWER_SUPPLY_CAPACITY) _L=$_v ;; POWER_SUPPLY_STATUS) _S=$_v ;; POWER_SUPPLY_CURRENT_NOW) _I=$_v ;;
        POWER_SUPPLY_VOLTAGE_NOW) _V=$_v ;; POWER_SUPPLY_TEMP) _T=$_v ;;
      esac; done < /sys/class/power_supply/battery/uevent
      echo "$(date +%H:%M:%S 2>/dev/null) L=$_L S=$_S I=$_I V=$_V T=$_T sup=${_SUPN:+$(cat $_SUPN 2>/dev/null)}"
      i=$((i+1)); sleep 1
    done; } > "$STAGE/charging/sample-${SAMPLE_SECS}s.txt"
  man "OK     ${SAMPLE_SECS}s live sample (incl. temperature) -> charging/sample-${SAMPLE_SECS}s.txt"
fi

# ===== redaction (privacy: mask serial/MAC/email/telephony-id; keep every line) =====
# ONE sed per file, not two. The serial pass rewrote every file a second time for a single fixed
# string; folded into the same expression list it is free. Measured 27s of a 294s A3 run.
_redact(){ _ser=$(getprop ro.serialno 2>/dev/null); _serx=
  [ ${#_ser} -ge 6 ] && _serx="-e s#${_ser}#[REDACTED-SERIAL]#g"
  find "$STAGE" -type f 2>/dev/null | while IFS= read -r f; do
  case "$f" in *.txt|*.log|*.json) ;; *) continue ;; esac
  sed -E \
    -e 's#\[([a-z0-9._]*serial[a-z0-9._]*)\]: \[[^]]*\]#[\1]: [REDACTED]#g' \
    -e 's#\[([a-z0-9._]*(imei|imsi|iccid|meid|android_id)[a-z0-9._]*)\]: \[[^]]*\]#[\1]: [REDACTED]#g' \
    -e 's#([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}#[MAC]#g' \
    -e 's#[A-Za-z0-9._%+-]+@[A-Za-z][A-Za-z0-9.-]*\.[A-Za-z]{2,}#[EMAIL]#g' \
    $_serx     "$f" > "$f.__r" 2>/dev/null && [ -s "$f.__r" ] && mv -f "$f.__r" "$f" 2>/dev/null || rm -f "$f.__r" 2>/dev/null
done; }
_redact

# ===== pack =====
if [ -s "$_SLOWLOG" ]; then
  man ""; man "TIMING sources taking 1s or more (whole-run wall clock is the sum of these plus the sample):"
  sort -rn "$_SLOWLOG" | while read _es _en; do man "       ${_es}s  $_en"; done
fi
rm -f "$_SLOWLOG"
man ""; man "OK     redaction: serial/MAC/email/telephony-id masked"
man "schema=$SCHEMA collector=$COLLECTOR mode=$MODE sample=$SAMPLE crash=$CRASH_SIGNAL reboot=$REBOOT_SIGNAL device=$DEV time=$(date 2>/dev/null)"
BUNDLE=""
_T_PACK0=$(date +%s 2>/dev/null || echo 0)
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
_T_END=$(date +%s 2>/dev/null || echo 0)
echo "   timing: $(( _T_END - _T_RUN0 ))s total, of which $(( _T_END - _T_PACK0 ))s packing (per-stage breakdown in _MANIFEST.txt)"
echo "=========================================================="
rm -rf "$STAGE"
