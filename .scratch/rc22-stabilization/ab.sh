#!/bin/bash
# ab.sh - switch a phone between build A (rc21 baseline) and build B (working tree), and say
#         with certainty which one is live.
#
#   ./ab.sh id   <ip:port>          what is on the phone right now
#   ./ab.sh A    <ip:port>          install the rc21 baseline
#   ./ab.sh B    <ip:port>          install the working tree
#
# WHY THIS EXISTS
#   module.prop's versionCode has named at least four different builds this week, so it cannot
#   identify one. The checksums of the files that actually run can. Every install writes a
#   build-id file on the phone recording the label, the git commit, and the md5 of each script,
#   and `id` reads it back and re-verifies it against the files on disk -- so a hand-edited or
#   half-finished install is caught rather than trusted.
#
#   A regression today (a native_unlatch guard that latched charge_stop_level on a Pixel) was only
#   caught by flipping A/B on hardware. That flip needs to be one command, or it does not happen.

set -u
# Git Bash rewrites any argument that looks like a unix path into a Windows one, so an adb push to
# /data/local/tmp lands at C:/Program Files/Git/data/local/tmp and fails. Must be set here, not
# inherited, or a caller who forgets it gets a half-installed phone.
export MSYS_NO_PATHCONV=1
REPO="C:/Users/PC/Desktop/PROJECTS/ACC"
ADB="C:/Users/PC/gctools/android-sdk/platform-tools/adb.exe"
FILES="accd.sh batt-interface.sh misc-functions.sh set-ch-curr.sh set-ch-volt.sh write-config.sh"
# Windows-visible on purpose: adb.exe is a Windows binary and cannot stat Git Bash's /tmp.
STAGE="C:/Users/PC/AppData/Local/Temp/acc-ab"

usage(){ echo "usage: $0 {id|A|B} <ip:port>" >&2; exit 2; }
[ $# -eq 2 ] || usage
MODE=$1; DEV=$2

dev(){ "$ADB" -s "$DEV" "$@"; }

# The baseline is PINNED to the rc21 commit, not HEAD. It was HEAD until rc22 was committed, at
# which point "build A" silently became a copy of build B and every A/B from then on would have
# compared a build against itself. Caught when an A install came back carrying B's checksums.
BASE_REF=${BASE_REF:-1406274}

stage_A(){   # rc21 baseline
  rm -rf $STAGE/A; mkdir -p $STAGE/A
  ( cd "$REPO" || exit 1
    git rev-parse --verify --quiet "$BASE_REF" >/dev/null || { echo "baseline ref $BASE_REF not found" >&2; exit 1; }
    for f in $FILES; do git show "$BASE_REF:install/$f" > "$STAGE/A/$f" 2>/dev/null || :; done )
  echo "$STAGE/A"
}
stage_B(){   # the working tree
  rm -rf $STAGE/B; mkdir -p $STAGE/B
  for f in $FILES; do cp "$REPO/install/$f" "$STAGE/B/$f" 2>/dev/null || :; done
  echo "$STAGE/B"
}

install_build(){   # $1 = label, $2 = staging dir
  local label=$1 src=$2 commit stamp f
  if [ "$label" = A ]; then commit=$( cd "$REPO" && git rev-parse --short "$BASE_REF" )
  else commit=$( cd "$REPO" && git rev-parse --short HEAD ); fi
  # --untracked-files=no on purpose: "dirty" must mean a TRACKED file differs from the commit, i.e.
  # the code on the phone is not what that commit says. A scratch directory sitting untracked
  # alongside it changes nothing about the build and must not taint the identity.
  [ -z "$( cd "$REPO" && git status --porcelain --untracked-files=no )" ] || commit="$commit-dirty"

  stamp="label=$label"$'\n'"commit=$commit"$'\n'"installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for f in $FILES; do
    [ -s "$src/$f" ] || { echo "  skip $f (not in this build)"; continue; }
    stamp="$stamp"$'\n'"$f $(md5sum "$src/$f" | cut -c1-12)"
  done

  echo "--- installing build $label ($commit) on $DEV ---"
  for f in $FILES; do
    [ -s "$src/$f" ] || continue
    dev push "$src/$f" "/data/local/tmp/ab.$f" >/dev/null 2>&1 || { echo "  PUSH FAILED $f"; return 1; }
  done

  # Convert line endings and syntax-check EVERY file on the device shell BEFORE replacing any of
  # them. A half-installed set is worse than either build: mksh rejects CRLF, and bash -n on the PC
  # does not prove mksh accepts it.
  dev shell "su -c '
    cd /data/local/tmp || exit 1
    for f in $FILES; do
      [ -f ab.\$f ] || continue
      tr -d \"\r\" < ab.\$f > lf.\$f
      sh -n lf.\$f || { echo \"SYNTAX FAIL \$f\"; exit 1; }
    done
    for f in $FILES; do
      [ -f lf.\$f ] || continue
      cat lf.\$f > /data/adb/vr25/acc/\$f && chmod 755 /data/adb/vr25/acc/\$f
    done
    rm -f ab.* lf.*
    echo INSTALL_OK'" 2>&1 | tr -d '\r' | grep -E "SYNTAX FAIL|INSTALL_OK" || { echo "  install failed"; return 1; }

  printf '%s\n' "$stamp" > $STAGE/build-id
  dev push $STAGE/build-id /data/local/tmp/build-id >/dev/null 2>&1
  dev shell "su -c 'tr -d \"\r\" < /data/local/tmp/build-id > /data/adb/vr25/acc/.build-id'" >/dev/null 2>&1

  # Clear ACC's tmpfs state so each arm starts clean. It survives a daemon restart, so without this
  # one build inherits the other's learned facts and markers -- the polarity cache in particular,
  # where rc21's appending sdp() left three contradictory lines that then showed up as an rc22
  # failure. An A/B that carries state between arms is not an A/B.
  dev shell "su -c 'rm -f /dev/.vr25/acc/.batt-interface.sh /dev/.vr25/acc/.dpol_flips \
    /dev/.vr25/acc/.dpol_unstable /dev/.vr25/acc/.cc_then /dev/.vr25/acc/.mcc-custom \
    /dev/.vr25/acc/.volt-custom /dev/.vr25/acc/ch-curr-ctrl-files /dev/.vr25/acc/.mcc-read \
    /dev/.vr25/acc/.write-ledger /dev/.vr25/acc/.mccrej-* 2>/dev/null'" >/dev/null 2>&1

  # The daemon restart MUST be its own call. Chained inside the same su -c it SIGTERMs the calling
  # shell and adb returns 143 with the restart half-done.
  dev shell "su -c 'acc -D restart >/dev/null 2>&1 &'" >/dev/null 2>&1
  sleep 35
  identify
}

identify(){
  echo "--- $DEV ---"
  dev shell "su -c '
    B=/data/adb/vr25/acc
    have=0
    if [ -f \$B/.build-id ]; then
      have=1; sed -n \"1,3p\" \$B/.build-id
    else
      echo \"label=UNKNOWN (no build-id: installed by hand or by the module installer)\"
    fi
    echo \"prop=\$(sed -n s/^versionCode=//p \$B/module.prop)\"
    ok=1; checked=0
    for f in $FILES; do
      [ -f \$B/\$f ] || continue
      live=\$(md5sum \$B/\$f | cut -c1-12)
      echo \"  \$f \$live\"
      want=\$(sed -n \"s|^\$f ||p\" \$B/.build-id 2>/dev/null)
      if [ -n \"\$want\" ]; then
        checked=\$((checked + 1))
        [ \"\$live\" = \"\$want\" ] || { echo \"    MISMATCH recorded=\$want\"; ok=0; }
      fi
    done
    # An absent build-id gives an EMPTY expectation for every file, so nothing mismatches and the
    # old code reported a clean build. Never claim verification that did not happen.
    if [ \$have = 0 ] || [ \$checked = 0 ]; then
      echo \"  NOT VERIFIED - no recorded build to compare against. Install via this script to fix.\"
    elif [ \$ok = 1 ]; then
      echo \"  verified: all \$checked files match the recorded build\"
    else
      echo \"  *** THIS PHONE IS NOT RUNNING A CLEAN BUILD ***\"
    fi
    P=\$(cat /dev/.vr25/acc/acc.lock 2>/dev/null)
    [ -n \"\$P\" ] && [ -d /proc/\$P ] && echo \"  daemon alive (\$P)\" || echo \"  daemon DOWN\"
    echo \"  level=\$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || cat /sys/class/power_supply/maxfg/capacity 2>/dev/null)% kernel=\$(cat /sys/class/power_supply/battery/status 2>/dev/null)\"
  '" 2>&1 | tr -d '\r'
}

case "$MODE" in
  id) identify ;;
  A)  install_build A "$(stage_A)" ;;
  B)  install_build B "$(stage_B)" ;;
  *)  usage ;;
esac
