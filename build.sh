#!/usr/bin/env sh
# Installation Archives Builder
# Copyright 2018-2024, VR25
# License: GPLv3+
#
# usage: $0 [any_random_arg]
#   e.g.,
#     build.sh (builds $id and generates installable archives)
#     build.sh any_random_arg (only builds $id)


(cd ${0%/*} 2>/dev/null

. ./check-syntax.sh || exit $?

set_prop() {
  sed -i -e "s/^($1=.*/($1=$2/" -e "s/^$1=.*/$1=$2/" \
    ${3:-module.prop} 2>/dev/null
}


id=$(sed -n "s/^id=//p" module.prop)

domain=$(sed -n "s/^domain=//p" module.prop)

# version/versionCode come from module.prop (the canonical Magisk source), so the
# changelog can be formatted freely (title/links first). module.json is ALWAYS
# regenerated to match, so Magisk's updateJson sees this build's real version and a
# zipUrl that points at the matching release asset (basename = id_version_versionCode).
version=$(sed -n "s/^version=//p" module.prop)

versionCode=$(sed -n "s/^versionCode=//p" module.prop)

basename=${id}_${version}_$versionCode

tmpDir=.tmp/META-INF/com/google/android


# update module info (Magisk updateJson target)
cat << EOF > module.json
{
    "busybox": "https://github.com/Magisk-Modules-Repo/busybox-ndk",
    "changelog": "https://raw.githubusercontent.com/seyedehsanhadi/$id/dev/changelog.md",
    "curl": "https://github.com/Zackptg5/Cross-Compiled-Binaries-Android/tree/master/curl",
    "onlineInstaller": "https://github.com/seyedehsanhadi/$id/releases/download/$version/install-online.sh",
    "tgz": "https://github.com/seyedehsanhadi/$id/releases/download/$version/${basename}.tgz",
    "tgzInstaller": "https://github.com/seyedehsanhadi/$id/releases/download/$version/install-tarball.sh",
    "version": "$version",
    "versionCode": $versionCode,
    "zipUrl": "https://github.com/seyedehsanhadi/$id/releases/download/$version/${basename}.zip"
}
EOF


# set ID
for file in ./install*.sh ./install/*.sh ./bundle.sh; do
  if [ -f "$file" ] && grep -Eq '(^|\()id=' $file; then
    grep -Eq "(^|\()id=$id" $file || set_prop id $id $file
  fi
done


# set domain
for file in ./install*.sh ./install/*.sh ./bundle.sh; do
  if [ -f "$file" ] && grep -Eq '(^|\()domain=' $file; then
    grep -Eq "(^|\()domain=$domain" $file || set_prop domain $domain $file
  fi
done


# update README

if [ README.md -ot install/default-config.txt ] \
  || [ README.md -ot install/strings.sh ] \
  || [ README.md -nt README.html ]
then
# default config
  set -e
  { sed -n '1,/#DC#/p' README.md; echo; cat install/default-config.txt; \
    echo; sed -n '/^#\/DC#/,$p' README.md; } > README.md.tmp
# terminal commands
  { sed -n '1,/#TC#/p' README.md.tmp; \
    echo; . ./install/strings.sh; print_help; \
    echo; sed -n '/^#\/TC#/,$p' README.md.tmp; } > README.md
    rm README.md.tmp
  set +e
  # Only regenerate README.html when a markdown converter exists AND it produces
  # non-empty output -- otherwise the redirect would truncate README.html to 0 bytes
  # (this box has no `markdown` binary). Write to a temp and move only on success.
  # Two converters, because the binary is rare and the python module is not. This script already
  # requires python for the zip packer, so `python -m markdown` adds no dependency class.
  if command -v markdown >/dev/null 2>&1; then
    markdown README.md > README.html.tmp 2>/dev/null || :
  elif python3 -c 'import markdown' >/dev/null 2>&1; then
    python3 -m markdown README.md > README.html.tmp 2>/dev/null || :
  elif python -c 'import markdown' >/dev/null 2>&1; then
    python -m markdown README.md > README.html.tmp 2>/dev/null || :
  fi
  [ -s README.html.tmp ] && mv -f README.html.tmp README.html; rm -f README.html.tmp 2>/dev/null || :

  # ...and say so when it did not. README.html SHIPS (`cp -R ... README.*`) and acc.sh hands it to
  # the Android viewer as $dataDir/README.html, with the markdown only as a fallback, so a stale
  # copy is the documentation most users actually read. Without this the skip was silent: the
  # shipped HTML sat three months behind README.md, still showing allowIdleAbovePcap=true after the
  # default became false, and still documenting `acc 3900` as resuming at 3870 rather than 3750.
  # Not fatal - there is no converter on every build box, and blocking the build over a doc format
  # helps nobody - but it must never again be invisible.
  if [ README.html -ot README.md ]; then
    echo "BUILD WARNING: README.html is older than README.md and was NOT regenerated." >&2
    echo "  The shipped HTML readme will contradict the shipped defaults." >&2
    command -v markdown >/dev/null 2>&1       || echo "  Cause: no converter -- install the 'markdown' binary or 'pip install markdown'." >&2
  fi
fi


# update busybox config (from install/setup-busybox.sh) in install/uninstall.sh and install scripts
set -e
for file in ./install/uninstall.sh ./install*.sh; do
  # rc21: ALWAYS re-sync the #BB# block. This was `[ $file -ot install/setup-busybox.sh ]`
  # (mtime-gated) -- which silently STOPPED firing the moment a file was edited after
  # setup-busybox.sh, which is exactly how install/uninstall.sh drifted to a stale, weaker,
  # FATAL busybox block: the one script that most needs the current wide + non-fatal net.
  # Idempotent; content is sourced only from setup-busybox.sh.
  { sed -n '1,/#BB#/p' $file; \
  # Keep the comments. `grep -Ev '^$|^#'` dropped every comment starting at column 0 while
  # leaving indented ones alone, so which rationale survived a build came down to how deeply it
  # happened to be nested. The rc23b note explaining why this block tests $busybox_dir and not
  # $bin_dir sits at column 0, so every single build deleted it -- it was restored by hand once
  # this session and the next build removed it again. That note is the measured record of a bug
  # that left a phone with no daemon and charging uncapped, and it belongs in the generated copies
  # where anyone editing them will read it. Only the file's own header is dropped now: skip
  # leading blanks and comments until the first real statement, then keep everything non-blank.
  awk 'NF==0 && !seen {next} /^#/ && !seen {next} {seen=1; if (NF) print}' install/setup-busybox.sh; \
  sed -n '/^#\/BB#/,$p' $file; } > ${file}.tmp
  mv -f ${file}.tmp $file
done
set +e


# unify installers for flashable zip (customize.sh and update-binary are copies of install.sh)
# N3: force-copy (not -u) -- customize.sh and update-binary ARE install.sh; a stale mtime
# (fresh clone, revert, editor preserving mtime) must never ship old install logic in the zip.
cp -f install.sh customize.sh
cp -f install.sh META-INF/com/google/android/update-binary
# rc6: verify the copies actually synced -- a silently-failed cp (read-only/locked file) used to
# ship a STALE installer inside the flashable zip. Fail loudly instead of hiding it with 2>/dev/null.
cmp -s install.sh customize.sh && cmp -s install.sh META-INF/com/google/android/update-binary \
  || { echo "BUILD ERROR: customize.sh / update-binary did not sync from install.sh" >&2; exit 9; }


if [ bin/${id}_flashable_uninstaller.zip -ot install/uninstall.sh ] || [ ! -f bin/${id}_flashable_uninstaller.zip ]; then
  # generate $id uninstaller flashable zip
  echo "=> bin/${id}_flashable_uninstaller.zip"
  rm -rf bin/${id}_flashable_uninstaller.zip $tmpDir 2>/dev/null
  mkdir -p bin $tmpDir
  sed 's|#!/system/bin/sh|#!/sbin/sh|' install/uninstall.sh > $tmpDir/update-binary
  echo "#MAGISK" > $tmpDir/updater-script
  # This is the RECOVERY artifact: the thing someone flashes when a phone will not boot. The old
  # code called `zip` and swallowed the failure, and Git Bash on Windows has no `zip` at all -- so
  # the branch above had already DELETED the previous zip and this step then produced nothing,
  # silently shipping a release with no recovery path. Prefer python (present wherever build-zip.py
  # runs), keep zip as a fallback, and fail the build loudly rather than continue without it.
  # update-binary must be 0755: recovery execs it directly.
  py=$(command -v python3 || command -v python) 2>/dev/null
  if [ -n "$py" ]; then
    "$py" - .tmp "bin/${id}_flashable_uninstaller.zip" <<'EOF' || { echo "BUILD ERROR: could not package the flashable uninstaller" >&2; exit 9; }
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        dirs.sort(); files.sort()
        for d in dirs:
            rel = os.path.relpath(os.path.join(root, d), src).replace('\\', '/') + '/'
            zi = zipfile.ZipInfo(rel); zi.create_system = 3
            zi.external_attr = (0o40755 << 16) | 0x10
            z.writestr(zi, b'')
        for f in files:
            p = os.path.join(root, f)
            rel = os.path.relpath(p, src).replace('\\', '/')
            mode = 0o100755 if f == 'update-binary' else 0o100644
            zi = zipfile.ZipInfo(rel); zi.create_system = 3
            zi.external_attr = mode << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(p, 'rb') as fh: z.writestr(zi, fh.read())
with zipfile.ZipFile(out) as z:
    names = z.namelist()
    ub = 'META-INF/com/google/android/update-binary'
    assert ub in names, 'update-binary missing'
    assert 'META-INF/com/google/android/updater-script' in names, 'updater-script missing'
    for e in z.infolist():
        assert e.create_system == 3, 'no unix host on ' + e.filename
        assert (e.external_attr >> 16) & 0xFFFF, 'no mode bits on ' + e.filename
    m = (z.getinfo(ub).external_attr >> 16) & 0o777
    assert m == 0o755, 'update-binary is %o, must be 755' % m
print('   uninstaller: %d entries, update-binary 0755, unix modes on all' % len(names))
EOF
  elif command -v zip >/dev/null 2>&1; then
    (cd .tmp
    zip -r9 ../bin/${id}_flashable_uninstaller.zip * \
      | sed 's|.*adding: ||' | grep -iv 'zip warning:')
  else
    echo "BUILD ERROR: no python and no zip -- cannot package the flashable uninstaller" >&2; exit 9
  fi
  [ -s bin/${id}_flashable_uninstaller.zip ] \
    || { echo "BUILD ERROR: flashable uninstaller is missing or empty after packaging" >&2; exit 9; }
  rm -rf .tmp
  echo
fi


[ -z "$1" ] && {

  # cleanup
  rm -rf _builds/${basename}/ 2>/dev/null
  mkdir -p _builds/${basename}/${basename}

  cp bin/${id}_flashable_uninstaller.zip install-online.sh install-tarball.sh _builds/${basename}/

  # generate $id flashable zip -- deterministic name (matches the zipUrl written into module.json
  # above); an rc timestamp suffix here diverged the asset name from the manifest and broke
  # Magisk's updateJson one-tap download.
  basename_=$basename
  echo "=> _builds/${basename}/${basename_}.zip"
  # Root managers read each file's UNIX mode out of the zip entry itself. Windows zip tools
  # (7-Zip, PowerShell) omit it, so every *.sh extracts non-executable: Magisk tolerates that
  # and installs anyway (hiding the fault), but KernelSU/APatch fail and the module DISAPPEARS
  # after the next reboot. That shipped once in rc21 and cost a tester a rollback. Git Bash also
  # has no `zip` at all, so this step silently produced nothing on Windows. build-zip.py writes
  # create_system=3 + real mode bits on every OS and verifies the result, so prefer it.
  py=$(command -v python3 || command -v python) 2>/dev/null
  if [ -n "$py" ]; then
    "$py" build-zip.py _builds/${basename}/${basename_}.zip || {
      echo "BUILD ERROR: flashable zip failed verification -- would not install on KernelSU" >&2; exit 9; }
  elif command -v zip >/dev/null 2>&1; then
    zip -r9 _builds/${basename}/${basename_}.zip \
      * .gitattributes .gitignore .github \
      -x _\*/\* | sed 's|.*adding: ||' | grep -iv 'zip warning:'
  else
    echo "BUILD ERROR: no python and no zip -- cannot package a flashable zip" >&2; exit 9
  fi
  echo

  # prepare files to be included in $id installable tarball
  # acc-compat.sh ships under its fixed name (AccA pushes it by that name on-device + the
  # uninstall *compat* preserve-glob depends on it); amps.sh is the branded standalone copy.
  [ -f acc-compat.sh ] || { echo "BUILD ERROR: acc-compat.sh missing from repo root"; exit 9; }
  [ -f amps.sh ] || { echo "BUILD ERROR: amps.sh missing from repo root"; exit 9; }
  cmp -s acc-compat.sh amps.sh || { echo "BUILD ERROR: acc-compat.sh and amps.sh differ -- they are the same engine under two names; sync them (edit one, copy to the other) before release"; exit 9; }
  cp -R install install.sh License.md README.* module.prop bin/ acc-compat.sh amps.sh \
    _builds/${basename}/${basename}/ 2>&1 \
    | grep -iv "can't preserve"

  # generate $id installable tarball
  cd _builds/${basename}
  echo "=> _builds/${basename}/${basename}.tgz"
  tar -cvf - ${basename} | gzip -9 > ${basename}.tgz
  rm -rf ${basename}/
  echo

})
exit 0
