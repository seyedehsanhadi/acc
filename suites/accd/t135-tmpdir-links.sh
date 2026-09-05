#!/system/bin/sh
# t135 - partial tmpfs loss must rebuild every launcher.

ID=t135
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
SRC=$execDir
W=${TMPDIR:-/data/local/tmp}/t135.$$
rm -rf "$W" 2>/dev/null; mkdir -p "$W/e" "$W/t"
trap 'rm -rf "$W" 2>/dev/null' EXIT
for _n in service acc acca; do : > "$W/e/$_n.sh"; done

run(){
  _src=$1
  rm -rf "$W/t"; mkdir -p "$W/t"
  ln -s "$W/e/service.sh" "$W/t/accd"
  ln -s "$W/e/acca.sh" "$W/t/acca"
  TMPDIR=$W/t; execDir=$W/e; id=acc
  _fn=$(sed -n '/^ensure_tmpdir_links() {/,/^}/p' "$_src")
  eval "$_fn"
  ensure_tmpdir_links
  [ -e "$W/t/acc" ] && [ -e "$W/t/acca" ] && [ -e "$W/t/accd" ]
}

run "$SRC/acc.sh" && ok "acc rebuilds a missing launcher when accd still exists" \
                       || no "acc returns early on a partial tmpfs tree"
run "$SRC/acca.sh" && ok "acca rebuilds a missing launcher when accd still exists" \
                        || no "acca returns early on a partial tmpfs tree"

_tail=$(sed -n '/# other acc commands/,$p' "$SRC/acca.sh" | sed 's/^[[:space:]]*#.*//')
_el=$(printf '%s\n' "$_tail" | grep -n '^ensure_tmpdir_links$' | head -1 | cut -d: -f1)
_xl=$(printf '%s\n' "$_tail" | grep -n 'exec \$TMPDIR/acc' | head -1 | cut -d: -f1)
[ -n "$_el" ] && [ -n "$_xl" ] && [ "$_el" -lt "$_xl" ] \
  && ok "acca fallback repairs tmpfs before delegating commands such as -f" \
  || no "acca fallback reaches the missing acc link before bootstrap"

_fb=$(sed -n '/^  -f|--force|--full)/,/^  -F|--flash)/p' "$SRC/acc.sh" | sed '/^[[:space:]]*#/d')
_el=$(printf '%s\n' "$_fb" | grep -n 'ensure_tmpdir_links' | tail -1 | cut -d: -f1)
_xl=$(printf '%s\n' "$_fb" | grep -nF '"$TMPDIR/acca"' | head -1 | cut -d: -f1)
[ -n "$_el" ] && [ -n "$_xl" ] && [ "$_el" -lt "$_xl" ] \
  && ok "acc -f rebuilds acca before forwarding extra settings" \
  || no "acc -f can call a missing acca link before bootstrap"

sed -n '/^  cfg_srcsafe()/,/^  }/p' "$SRC/acca.sh" | grep -q 'set +e' \
  && ok "acca's incomplete-upgrade fallback disables errexit while sourcing" \
  || no "acca fallback can die inside a dotted config under mksh set -e"

fin
