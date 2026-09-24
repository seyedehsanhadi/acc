#!/system/bin/sh
# survivor_check must never leave a charge-disable flag latched.
# Motorola's MMI current_max has no getter, so the "old value" a recovery restores came back
# EMPTY and the restore was skipped - the phone was left unable to charge with nothing to undo
# it. Device-evidence: a two-line .acc-compat-inflight on a moto g64 5G (cancunf).
execDir=${execDir:-/data/adb/vr25/acc}
AMPS=${AMPS:-$execDir/amps.sh}
# $0 has no slash when invoked as a bare filename, so ${0%/*} returns the FILENAME and every
# awk lift silently fails. Resolve the directory properly.
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF=.
AWKF=${AWKF:-$SELF/../xf.awk}
P=0; F=0
run(){ # $1=case $2=expected
  W=$(mktemp -d); mkdir -p "$W/psy/mtk-mst-div-chg" "$W/psy/other" "$W/data"
  AMPSD=$W/data; BLF=$AMPSD/.acc-compat-blacklist; JRN=$AMPSD/.acc-compat-inflight
  RCT=$AMPSD/.acc-compat-recent; LYR=$AMPSD/.acc-compat-layer; DLY=$AMPSD/.acc-compat-danger
  PBL=$AMPSD/.probe-blacklist
  _BLTAB=$(printf '\t'); _BLCR=$(printf '\r'); HAVE_TO=0; TO=5
  for fn in rd rd1 lyr_danger lyr_skippable bl_in bl_has bl_add jrn_begin jrn_end survivor_check mtk_current_flag; do
    eval "$(awk -v fn="$fn" -f "$AWKF" "$AMPS")"
  done
  log(){ :; }; warn(){ :; }; bootid(){ echo boot-new; }
  ABN=0; boot_abnormal(){ [ "$ABN" = 1 ]; }
  VENDOR=motorola; getprop(){ case "$1" in ro.product.manufacturer) echo "$VENDOR";; *) echo "";; esac; }
  cat(){ case "$1" in "$WONODE") return 1;; esac; command cat "$@"; }
  MOTO=$W/psy/mtk-mst-div-chg/current_max; PLAIN=$W/psy/other/current_max
  TARGET=; WONODE=
  case $1 in
    jrn-moto)     WONODE=$MOTO; echo 0 > "$MOTO"; jrn_begin "$MOTO" 1 >/dev/null 2>&1
                  echo 1 > "$MOTO"; TARGET=$MOTO;;
    jrn-legacy)   WONODE=$MOTO; echo 1 > "$MOTO"
                  printf '%s\n%s\n%s\n' "$MOTO" 1 "" > "$JRN"; TARGET=$MOTO;;
    jrn-readable) echo 3000000 > "$PLAIN"; jrn_begin "$PLAIN" 0 >/dev/null 2>&1
                  echo 0 > "$PLAIN"; TARGET=$PLAIN;;
    jrn-notmoto)  VENDOR=xiaomi; WONODE=$MOTO; echo 1 > "$MOTO"
                  printf '%s\n%s\n%s\n' "$MOTO" 1 "" > "$JRN"; TARGET=$MOTO;;
    rct-moto)     ABN=1; WONODE=$MOTO; echo 1 > "$MOTO"
                  printf '%s\t%s\t%s\n' "$MOTO" 1 boot-old > "$RCT"; TARGET=$MOTO;;
    rct-notmoto)  ABN=1; VENDOR=xiaomi; WONODE=$MOTO; echo 1 > "$MOTO"
                  printf '%s\t%s\t%s\n' "$MOTO" 1 boot-old > "$RCT"; TARGET=$MOTO;;
    rct-plain)    ABN=1; echo 500000 > "$PLAIN"
                  printf '%s\t%s\t%s\n' "$PLAIN" 500000 boot-old > "$RCT"; TARGET=$PLAIN;;
    rct-sameboot) WONODE=$MOTO; echo 1 > "$MOTO"
                  printf '%s\t%s\t%s\n' "$MOTO" 1 boot-new > "$RCT"; TARGET=$MOTO;;
    rct-normal)   ABN=0; WONODE=$MOTO; echo 1 > "$MOTO"
                  printf '%s\t%s\t%s\n' "$MOTO" 1 boot-old > "$RCT"; TARGET=$MOTO;;
  esac
  # A case that set no TARGET compared empty-to-empty and reported a pass. Refuse to grade it.
  [ -n "$TARGET" ] || { echo "  FAIL $1: harness set no TARGET"; F=$((F+1)); rm -rf "$W"; return; }
  survivor_check >/dev/null 2>&1
  got=$(command cat "$TARGET")
  if [ "$got" = "$2" ]; then P=$((P+1)); else echo "  FAIL $1: got '$got' want '$2'"; F=$((F+1)); fi
  rm -rf "$W"
}
run jrn-moto      0
run jrn-legacy    0
run jrn-readable  3000000
run jrn-notmoto   1
run rct-moto      0
run rct-notmoto   1
run rct-plain     500000
run rct-sameboot  1
run rct-normal    1
echo "t-jrn-writeonly-restore: $P passed, $F failed"
[ "$F" = 0 ]
