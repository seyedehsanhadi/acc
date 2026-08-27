#!/usr/bin/env python3
"""
Package the ACC flashable zip so it installs on EVERY root manager.

Why this exists
---------------
Magisk / KernelSU / APatch / TWRP read the file mode out of the zip entry itself:
`create_system = 3` (Unix) plus `external_attr = mode << 16`. Windows zip tools
(7-Zip, PowerShell Compress-Archive, .NET ZipFile) write `create_system = 0` (DOS)
and NO mode bits, so every *.sh extracts non-executable.

Magisk tolerates that and installs anyway, which hides the fault. KernelSU does not:
the install fails and the module DISAPPEARS after the next reboot. That shipped once
(rc22, 2026-07-24) and cost a tester a failed install plus a rollback.

Git Bash on Windows has no `zip` binary, so build.sh's `zip -r9` silently produced
nothing here. This script is the portable replacement: same output on any OS.

Usage:
  python build-zip.py <out.zip>     build (and verify)
  python build-zip.py --verify <z>  verify an existing zip only
Exit code is non-zero if the result would not install, so it can gate a release.
"""
import os, sys, zipfile

REPO = os.path.dirname(os.path.abspath(__file__))

# Dev tooling and notes: present in the repo, must never ship inside a module.
EXCLUDE_NAMES = {
    'build.sh', 'build.bat', 'build-zip.py', 'push.sh', 'push.bat',
    'check-syntax.sh', 'check-syntax.bat', 'obs.sh', 'probe-scheduler.sh',
    'acc-hardtest.sh', 'bt-test.sh',
}
EXCLUDE_PREFIX = ('HANDOFF-', 'FIX-PLAN-')
EXCLUDE_DIRS = {'.git', '.scratch', '__pycache__', '.superpowers', '.github', '.claude', '.vscode'}

# Anything the root manager or recovery has to EXECUTE.
EXEC_SUFFIX = ('.sh',)
EXEC_NAMES = {'update-binary'}

DIR_MODE, EXEC_MODE, DATA_MODE = 0o40755, 0o100755, 0o100644


def is_exec(rel, full):
    if os.path.basename(rel) in EXEC_NAMES or rel.endswith(EXEC_SUFFIX):
        return True
    try:                                    # anything with a shebang is a script
        with open(full, 'rb') as f:
            return f.read(2) == b'#!'
    except OSError:
        return False


def skip(name):
    # Every dot-directory, not a hand-maintained list of the ones we happened to notice. This walks
    # the working tree rather than the tracked release set, so anything sitting in the checkout can
    # ship: a real build put all 28 ignored plan/review/diff files from .superpowers into the
    # flashable zip, plus .github, despite the comment above promising development notes never do.
    # A leading dot is not a filter anyone has to remember to update.
    if name.startswith('.') and name not in ('.',  '..'):
        return True
    return (name in EXCLUDE_NAMES or name.startswith(EXCLUDE_PREFIX)
            or name.startswith('_') or name in EXCLUDE_DIRS)


def add(zf, arc, mode, data=None, src=None):
    zi = zipfile.ZipInfo(arc, date_time=(2026, 1, 1, 0, 0, 0))
    zi.create_system = 3                    # Unix, so external_attr is honoured
    zi.external_attr = (mode & 0xFFFF) << 16
    if arc.endswith('/'):
        zi.external_attr |= 0x10            # MS-DOS directory flag
        zi.compress_type = zipfile.ZIP_STORED
        zf.writestr(zi, b'')
        return
    if data is None:
        with open(src, 'rb') as f:
            data = f.read()
    zi.compress_type = zipfile.ZIP_DEFLATED
    zf.writestr(zi, data)


def build_uninstaller():
    """Inner flashable uninstaller, same permission rules."""
    with open(os.path.join(REPO, 'install', 'uninstall.sh'), 'rb') as f:
        body = f.read().replace(b'#!/system/bin/sh', b'#!/sbin/sh', 1)
    out = os.path.join(REPO, 'bin', 'acc_flashable_uninstaller.zip')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for d in ('META-INF/', 'META-INF/com/', 'META-INF/com/google/', 'META-INF/com/google/android/'):
            add(z, d, DIR_MODE)
        add(z, 'META-INF/com/google/android/update-binary', EXEC_MODE, data=body)
        add(z, 'META-INF/com/google/android/updater-script', DATA_MODE, data=b'#MAGISK\n')
    return out


def build(out):
    build_uninstaller()                     # refresh it with correct modes first
    files = dirs = 0
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for root, dnames, fnames in os.walk(REPO):
            dnames[:] = sorted(d for d in dnames if not skip(d))
            rel_root = os.path.relpath(root, REPO).replace(os.sep, '/')
            if rel_root != '.':
                add(z, rel_root + '/', DIR_MODE)
                dirs += 1
            for name in sorted(fnames):
                if skip(name):
                    continue
                full = os.path.join(root, name)
                rel = name if rel_root == '.' else f'{rel_root}/{name}'
                add(z, rel, EXEC_MODE if is_exec(rel, full) else DATA_MODE, src=full)
                files += 1
    print(f'built {out}\n  files={files} dirs={dirs}')
    return out


def verify(path):
    bad = []
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        names = {i.filename for i in infos}
        for i in infos:
            if i.create_system != 3:
                bad.append(f'{i.filename}: host is not Unix (create_system={i.create_system})')
            if not ((i.external_attr >> 16) & 0xFFFF):
                bad.append(f'{i.filename}: no unix mode bits')
        for req in ('module.prop', 'customize.sh',
                    'META-INF/com/google/android/update-binary',
                    'META-INF/com/google/android/updater-script'):
            if req not in names:
                bad.append(f'MISSING required entry: {req}')
        for i in infos:
            if (i.filename.endswith('.sh') or i.filename.endswith('update-binary')) \
               and not ((i.external_attr >> 16) & 0o111):
                bad.append(f'{i.filename}: not executable')
        for i in infos:
            if i.filename.endswith(('.sh', '.prop', '.txt', 'update-binary', 'updater-script')) \
               and b'\r' in z.read(i.filename):
                bad.append(f'{i.filename}: CRLF line endings (mksh rejects them; versionCode parses as non-numeric)')
        execs = sum(1 for i in infos if (i.external_attr >> 16) & 0o111 and not i.filename.endswith('/'))
        # --verify is a public CLI that promises to verify an arbitrary zip, and it was reading
        # module.prop unconditionally after already recording it as missing. Pointing it at ACC's own
        # flashable uninstaller produced a KeyError traceback instead of a FAILED verdict.
        if 'module.prop' in z.namelist():
            ver = [l for l in z.read('module.prop').decode().splitlines() if l.startswith('version')]
        else:
            ver = ['(no module.prop)']
        print(f'VERIFY entries={len(infos)} exec={execs} {ver}')
    if bad:
        print('FAILED -- this zip would not install on KernelSU/APatch:')
        for b in bad[:20]:
            print('  ', b)
        return False
    print('OK: unix modes + host present on every entry; required files present.')
    return True


if __name__ == '__main__':
    if len(sys.argv) >= 3 and sys.argv[1] == '--verify':
        sys.exit(0 if verify(sys.argv[2]) else 1)
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(0 if verify(build(sys.argv[1])) else 1)
