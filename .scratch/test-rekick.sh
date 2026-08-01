#!/system/bin/sh
# Contract test for rekick_charger() in install/accd.sh.
# Extracts the REAL function and drives it against a stubbed sysfs tree. Runs under bash on the
# PC and under mksh (/system/bin/sh) on the device -- the daemon's actual interpreter.
SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)/install/accd.sh}"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1  >> $2"; FAIL=$((FAIL+1)); }
extract(){ awk '/^  rekick_charger\(\) \{/,/^  \}/' "$SRC"; }

# run: $1=gap $2=preset-stamp-age-seconds("" = none)  -> "rc|node|stamp-exists"
run(){
  GAP="$1"; AGE="$2"
  T=/tmp/rk.$$; [ -d /data/local/tmp ] && T=/data/local/tmp/rk.$$
  rm -rf "$T"; mkdir -p "$T/battery" "$T/tmp"
  echo 0 > "$T/battery/rerun_aicl"
  ( cd "$T"
    TMPDIR="$T/tmp"; REKICK_MIN_GAP="$GAP"
    _wlog(){ :; }
    if [ -n "$AGE" ]; then echo $(( $(date +%s) - AGE )) > "$TMPDIR/.rekick-at"; fi
    eval "$(extract)"
    rekick_charger; rc=$?
    printf '%s|%s|%s' "$rc" "$(cat battery/rerun_aicl)" "$([ -f "$TMPDIR/.rekick-at" ] && echo stamped || echo nostamp)"
  )
  rm -rf "$T"
}

echo "=== rekick_charger() contract  (shell: ${0##*/} via $(readlink -f /proc/$$/exe 2>/dev/null || echo sh)) ==="

r=$(run 300 ""); echo "  [first kick]      -> $r"
case "$r" in 0\|1\|stamped) ok "first kick fires immediately and stamps (no delay for a real stall)";;
  *) no "expected rc=0, node=1, stamped" "$r";; esac

r=$(run 300 5); echo "  [repeat in 5s]    -> $r"
case "$r" in 1\|0\|stamped) ok "repeat inside the window is SUPPRESSED (node untouched)";;
  *) no "expected rc=1, node=0 (not rewritten), stamped" "$r";; esac

r=$(run 300 600); echo "  [after 600s gap]  -> $r"
case "$r" in 0\|1\|stamped) ok "re-arms once the window has passed";;
  *) no "expected rc=0, node=1 after the gap" "$r";; esac

r=$(run 60 90); echo "  [gap=60, age=90]  -> $r"
case "$r" in 0\|1\|stamped) ok "window is configurable via REKICK_MIN_GAP";;
  *) no "expected rc=0 with a shorter gap" "$r";; esac

r=$(run 300 299); echo "  [1s before gap]   -> $r"
case "$r" in 1\|0\|stamped) ok "boundary: still suppressed 1s before the window expires";;
  *) no "expected rc=1 just inside the window" "$r";; esac

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ]
