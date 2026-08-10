#!/system/bin/sh
# t64 - the diagnostic manifest must describe the bundle, not the attempt.
#
# THE DEFECT THIS ENCODES
#   rc22 added four collectors that write to $STAGE/kernel/ - last_kmsg and three pstore variants -
#   and never added kernel/ to the mkdir. Every copy failed. cpf swallowed the cp error and logged
#     OK  previous boot's kernel log (power-off / panic cause) -> kernel/last_kmsg.txt (262144b)
#   because it tested whether the SOURCE existed, not whether the destination landed. The closing
#   `captured N sources` line counted those phantoms too.
#
#   So a responder opening the bundle is told the previous boot's kernel log is present, with a byte
#   count, for a file that is not in the tarball. That is worse than no manifest - it stops the
#   search for evidence that was never collected. On a power-off investigation, last_kmsg is often
#   the only thing that answers the question.
#
#   NOTHING in the test tree had ever executed diag-collect.sh. Every check on it was an
#   occurrence-count of source text against rc21, which passes whether or not the code works.
#
# THIS TEST RUNS THE COLLECTOR. Root required; it stages into its own directory and removes it.

ID=t64
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS  $*"; }
no(){ F=$((F+1)); echo "  FAIL  $*"; }
fin(){ echo "$ID: $P passed, $F failed"; [ "$F" -eq 0 ] && exit 0 || exit 1; }

execDir=${execDir:-/data/adb/vr25/acc}
DC=$execDir/diag-collect.sh
[ -f "$DC" ] || { echo "      note  diag-collect.sh not installed; nothing to check"; fin; }

# ---- 1: every directory written to is created ---------------------------------------------------------
# Source-level and cheap, and it generalises past the one that broke: collect every $STAGE/<dir>/
# destination the script writes, and require each to appear in a mkdir.
# `\?` is a GNU sed extension. Toybox sed rejects it, and this line silently produced garbage -
# "cpf \"kernel cpf cpf cpf" as a directory name - which then failed the assertion for the wrong
# reason. Strip the quote as its own edit instead. (Toybox trap count for this campaign: 8.)
_dirs=$(grep -oE '(cpf|tailcpf|grab|grabf) +"?[a-z0-9_-]+/' "$DC"         | sed 's/^[a-z]*  *//; s/^"//; s|/$||' | sort -u)
_mk=$(grep -oE 'mkdir -p [^;]*' "$DC")
_miss=
for _d in $_dirs; do
  printf '%s' "$_mk" | grep -q "STAGE/$_d\"" || _miss="$_miss $_d"
done
[ -z "$_miss" ] \
  && ok "every staging subdirectory the collectors write to is created ($(printf '%s' "$_dirs" | tr '\n' ' '))" \
  || no "collectors write to subdirectories that are never created:$_miss"

# ---- 2: OK is earned by the destination ----------------------------------------------------------------
_cpf=$(sed -n '/^cpf()/,/^  else man "ABSENT/p' "$DC")
printf '%s' "$_cpf" | grep -qE '\[ -s "\$STAGE/\$1" \]' \
  && ok "cpf checks the destination before recording OK" \
  || no "cpf records OK based on the source alone - a failed copy is reported as captured"

_tcp=$(sed -n '/^tailcpf()/,/^  else man "ABSENT/p' "$DC")
printf '%s' "$_tcp" | grep -qE '\[ -s "\$STAGE/\$1" \]' \
  && ok "tailcpf checks the destination before recording OK" \
  || no "tailcpf records OK based on the source alone"

# ---- 3: run it, and hold the manifest to the bundle ------------------------------------------------------
# The invariant that matters and that no amount of source reading can establish: every OK line names a
# file that is actually there.
[ "$(id -u 2>/dev/null)" = 0 ] || { echo "      note  not root; skipping the live collection"; fin; }

_out=$(sh "$DC" --core 2>&1)
# The bundle is named acc-diag-<device>-<stamp>.tar.bz2 and announced on a "bundle:" line. The old
# pattern looked for "accdiag" and ".tar.gz" - neither of which the collector has ever produced - so
# this reported "no bundle" on a run that made one.
_tar=$(printf '%s' "$_out" | sed -n 's/^bundle: //p' | tail -1)
[ -n "$_tar" ] || _tar=$(printf '%s' "$_out" | grep -oE '/[^ ]*acc-diag-[^ ]*\.tar\.[a-z0-9]+' | tail -1)
_work=${TMPDIR:-/data/local/tmp}/t64-$$
rm -rf "$_work"; mkdir -p "$_work" 2>/dev/null

if [ -n "$_tar" ] && [ -f "$_tar" ]; then
  ok "the collector produced a bundle ($(wc -c <"$_tar")b)"
  # bz2, not gz. -xf lets tar pick the decompressor rather than asserting the wrong one.
  tar -xf "$_tar" -C "$_work" 2>/dev/null || tar -xjf "$_tar" -C "$_work" 2>/dev/null
  _root=$(find "$_work" -name _MANIFEST.txt 2>/dev/null | head -1)
  if [ -n "$_root" ]; then
    _base=$(dirname "$_root")
    _phantom=0; _names=
    # Each OK line ends with "-> <relative path> (...)"; pull that path and test for it in the bundle.
    while IFS= read -r _line; do
      case "$_line" in *' -> '*) :;; *) continue;; esac
      _rel=$(printf '%s' "$_line" | sed 's/.* -> //;s/ (.*//')
      [ -n "$_rel" ] || continue
      if [ ! -f "$_base/$_rel" ]; then
        _phantom=$(( _phantom + 1 )); _names="$_names $_rel"
      fi
    done <<EOFMAN
$(grep '^OK' "$_root")
EOFMAN
    [ "${_phantom:-0}" -eq 0 ] \
      && ok "every OK line in the manifest names a file that is in the bundle" \
      || no "${_phantom} manifest OK line(s) name files absent from the bundle:$_names"

    # And the specific regression: where the kernel evidence exists on this device, it must arrive.
    # THE SOURCE'S SIZE CANNOT BE TRUSTED HERE.
    #
    # /proc/last_kmsg is procfs: it stats as 0 bytes while returning 254KB when read. `[ -s ]` on it
    # is therefore meaningless, and an assertion built on it demanded an EMPTY manifest line for a
    # file that had arrived intact. Judge by what reached the BUNDLE, which is the only thing this
    # test is really about, and accept either outcome as long as the manifest agrees with it.
    if [ -f /proc/last_kmsg ]; then
      _lk=$_base/kernel/last_kmsg.txt
      if [ -s "$_lk" ]; then
        grep -qE 'OK .*last_kmsg' "$_root"           && ok "/proc/last_kmsg reached the bundle ($(wc -c <"$_lk")b) and the manifest says OK"           || no "kernel/last_kmsg.txt is in the bundle but the manifest does not record it as OK"
        grep -qE 'OK .*last_kmsg.*\(0b\)' "$_root"           && no "the manifest reports 0b for a file that carries $(wc -c <"$_lk")b - it is printing the procfs source size, not what landed"           || ok "the manifest's byte count reflects what actually landed, not the procfs source stat"
      else
        grep -qE 'EMPTY.*last_kmsg|EMPTY.*previous boot' "$_root"           && ok "/proc/last_kmsg yielded nothing, and the manifest records EMPTY rather than OK"           || no "/proc/last_kmsg produced no file in the bundle and the manifest does not say EMPTY"
      fi
    else
      grep -qE 'ABSENT.*last_kmsg|ABSENT.*previous boot' "$_root"         && ok "no /proc/last_kmsg here, and the manifest says ABSENT rather than OK"         || echo "      note  no /proc/last_kmsg and no ABSENT line; nothing to check"
    fi
  else
    no "the bundle contains no _MANIFEST.txt"
  fi
else
  no "the collector produced no bundle: $(printf '%s' "$_out" | tail -1)"
fi

rm -rf "$_work" 2>/dev/null
[ -n "$_tar" ] && rm -f "$_tar" 2>/dev/null
fin
