#!/system/bin/sh
# Run installed front-ends with a private config. These cases contain no hardware settings.
M=${execDir:-/data/adb/vr25/acc}
W=${TMPDIR_T:-/data/local/tmp}/config-cli-$$
mkdir -p "$W"
C=$W/config.txt
cp "$M/default-config.txt" "$C"
P=0; F=0
check(){ if [ "$1" = "$2" ]; then P=$((P+1)); echo "PASS $3"; else F=$((F+1)); echo "FAIL $3: <$1> expected <$2>"; fi; }
run(){ local cli=$1; shift; timeout -k 2 25 "$M/$cli" "$C" "$@" > "$W/call.log" 2>&1; }
run acca.sh -s language=de
check "$?" 0 'AccA scalar setting succeeds'
check "$(sed -n 's/^language=//p' "$C")" de 'AccA scalar setting is persisted'
run acc.sh -c a ': audit_edit; at 23:59 echo audit_edit'
check "$?" 0 'scheduled command append succeeds'
check "$(grep -c '^: audit_edit;' "$C")" 1 'one scheduled command is saved'
run acca.sh -s ui_refresh=61
check "$?" 0 'another writer preserves scheduled commands'
check "$(grep -c '^: audit_edit;' "$C")" 1 'scheduled command survives a config merge'
run acc.sh -c d audit_edit
check "$?" 0 'scheduled command deletion succeeds'
check "$(grep -c '^: audit_edit;' "$C")" 0 'scheduled command was removed'
printf 'language=fr\n: audit_import; at 23:59 echo audit_import\n' > "$W/import.txt"
run acc.sh -s "$W/import.txt"
check "$?" 0 'config import completes without deadlocking'
check "$(sed -n 's/^language=//p' "$C")" fr 'imported scalar is present'
check "$(grep -c '^: audit_import;' "$C")" 1 'imported scheduled command is present'
check "$(sed -n 's/^uiRefresh=//p' "$C")" 61 'import preserves an unrelated setting'
cp "$C" "$W/before-bad"
printf 'temperature=(\n' > "$W/bad.txt"
run acc.sh -s "$W/bad.txt"; rc=$?
[ "$rc" != 0 ] && cmp -s "$C" "$W/before-bad"; check "$?" 0 'invalid import reports failure and preserves the original'
echo "t-config-cli: $P passed, $F failed"
[ "$F" = 0 ]
