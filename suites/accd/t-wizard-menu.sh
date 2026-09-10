#!/system/bin/sh
# The interactive menu used `exec wizard` to redisplay itself. exec replaces the shell with an
# external COMMAND and there is no `wizard` binary, so thirteen of the sixteen items looked one up,
# failed, and took the whole `acc` process down. Option 4 also runs $TMPDIR/accd through a symlink
# that tmpfs loses on every boot, and the wizard was the one front-end that never rebuilt it.
#
# Private files only: the menu is driven with a scripted choice, no daemon and no config is touched.

ID=t-wizard-menu
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
WZ=$execDir/wizard.sh
AC=$execDir/acc.sh
[ -f "$WZ" ] || { no "missing $WZ"; fin; }

W=${TMPDIR_T:-/data/local/tmp}/wizard-$$
rm -rf "$W"; mkdir -p "$W" 2>/dev/null

echo "--- 1. no menu item may exec a command that does not exist"
n=$(grep -c '^ *exec wizard' "$WZ" 2>/dev/null); case $n in ''|*[!0-9]*) n=0;; esac
[ "$n" = 0 ] && ok "no 'exec wizard' left in the menu" \
  || no "$n menu items still exec a non-existent 'wizard' command"
# ...and that really is fatal: exec of a missing command ends the shell.
r=$( ( exec wizard ) 2>/dev/null; echo "alive" )
[ ".$r" = .alive ] && ok "exec of a missing command is contained here only by a subshell" \
  || no "the fixture could not demonstrate the failure"

echo "--- 2. the menu hands control back instead of ending the process"
if grep -q '^wizard()' "$WZ" || grep -q 'wizard() {' "$WZ"; then
  r=$( . "$WZ" 2>/dev/null
       clear(){ :; }; print_header(){ :; }; print_wizard(){ :; }
       print_choice_prompt(){ echo '?'; }; print_exit(){ echo exit; }
       daemon_ctrl(){ :; }; edit(){ :; }; resetbs(){ :; }
       ensure_tmpdir_links(){ echo LINKS >> "$W/calls"; }
       TMPDIR=$W; mkdir -p "$W"; printf '#!/system/bin/sh\necho ACCD >> "%s/calls"\n' "$W" > "$W/accd"
       chmod 755 "$W/accd"
       echo 4 | wizard >/dev/null 2>&1
       echo "rc=$?" )
  case "$r" in
    rc=0) ok "a menu item returns to its caller: $r" ;;
    *) no "a menu item did not return cleanly: $r" ;;
  esac
  grep -q ACCD "$W/calls" 2>/dev/null && ok "option 4 still starts the daemon" \
    || no "option 4 no longer starts the daemon"
  grep -q LINKS "$W/calls" 2>/dev/null && ok "the wizard rebuilds the tmpfs links first" \
    || no "the wizard runs without rebuilding the tmpfs links it depends on"
else
  no "no wizard function found"
  no "no wizard function found"
  no "no wizard function found"
fi

echo "--- 3. the caller redisplays the menu"
if [ -f "$AC" ]; then
  grep -q 'while wizard; do' "$AC" \
    && ok "acc.sh loops the menu itself" \
    || no "acc.sh has no redisplay loop, so the menu shows once and exits"
else
  ok "no acc.sh in this tree, section skipped"
fi

rm -rf "$W" 2>/dev/null
fin
