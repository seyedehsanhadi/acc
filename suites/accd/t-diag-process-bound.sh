#!/system/bin/sh
# Exercise the exact daemon probe with a private proc tree, including an open that blocks.
execDir=${execDir:-/data/adb/vr25/acc}
W=${TMPDIR_T:-/data/local/tmp}/diag-bound-$$
mkdir -p "$W/proc/42"
sed -n '/^  _diag_accd() {/,/^  }/p' "$execDir/diag-collect.sh" | sed "s|/proc/|$W/proc/|g" > "$W/probe.sh"
cat >> "$W/probe.sh" <<'PROBE'
_tmo(){ shift; timeout -k 1 1 "$@"; }
pgrep(){ echo 42; }
_diag_accd
PROBE
P=0; F=0
check(){ if [ "$1" = "$2" ]; then P=$((P+1)); echo "PASS $3"; else F=$((F+1)); echo "FAIL $3: got $1 expected $2"; fi; }
printf 'sh\000/data/adb/vr25/acc/accd.sh\000' > "$W/proc/42/cmdline"
/system/bin/sh "$W/probe.sh"; check "$?" 0 'an exact daemon process is recognized'
printf 'sh\000unrelated.sh\000accd.sh\000' > "$W/proc/42/cmdline"
/system/bin/sh "$W/probe.sh"; check "$?" 1 'an unrelated process mentioning accd is rejected'
rm "$W/proc/42/cmdline"; mkfifo "$W/proc/42/cmdline"
timeout -k 1 3 /system/bin/sh "$W/probe.sh" >/dev/null 2>&1
check "$?" 1 'a blocked process-file open finishes inside the probe deadline'
# Let an old-code command-substitution child finish if its parent timed out.
timeout -k 1 1 /system/bin/sh -c ': > "$1"' sh "$W/proc/42/cmdline" >/dev/null 2>&1 || :
echo "t-diag-process-bound: $P passed, $F failed"
[ "$F" = 0 ]
