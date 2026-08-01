#!/usr/bin/env python3
"""
Build a Magisk/KernelSU-flashable ACC zip with correct UNIX permissions.

Why this exists: 7-Zip on Windows writes DOS attributes only (create_system=0), so every
file extracts mode-less. On KernelSU that means install/*.sh are not executable, the module
install fails, and the module disappears after reboot. Info-ZIP's `zip` on Linux stores
create_system=3 + mode<<16, which is what we reproduce here.

The file list AND the per-path modes are taken from a known-good zip that is proven to
install, so the output is structurally identical to a working release apart from content.
"""
import os, sys, zipfile

REPO = r'C:\Users\PC\Desktop\PROJECTS\ACC'
GOOD = r'C:\Users\PC\Desktop\acc_rc21_hardened_202505301.zip'
OUT  = sys.argv[1] if len(sys.argv) > 1 else r'C:\Users\PC\Desktop\acc_rc22_LEAKFIX_202505302.zip'

# new in rc22 that the older known-good zip predates; ship them executable like their siblings
EXTRA = [('install/diag-collect.sh', 0o100755), ('install/reboot-archive.sh', 0o100755)]


def add(zf, arcname, mode, data=None, src=None):
    zi = zipfile.ZipInfo(arcname, date_time=(2026, 7, 23, 12, 0, 0))
    zi.create_system = 3                    # 3 = Unix, so external_attr is honoured by unzip
    zi.external_attr = (mode & 0xFFFF) << 16
    if arcname.endswith('/'):
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
    """Inner flashable uninstaller, also with proper modes."""
    up = os.path.join(REPO, 'install', 'uninstall.sh')
    with open(up, 'rb') as f:
        body = f.read().replace(b'#!/system/bin/sh', b'#!/sbin/sh', 1)
    out = os.path.join(REPO, 'bin', 'acc_flashable_uninstaller.zip')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        add(z, 'META-INF/', 0o40755)
        add(z, 'META-INF/com/', 0o40755)
        add(z, 'META-INF/com/google/', 0o40755)
        add(z, 'META-INF/com/google/android/', 0o40755)
        add(z, 'META-INF/com/google/android/update-binary', 0o100755, data=body)
        add(z, 'META-INF/com/google/android/updater-script', 0o100644, data=b'#MAGISK\n')
    return out


def main():
    print('rebuilding inner uninstaller with unix modes...')
    print('  ->', build_uninstaller())

    template = []
    with zipfile.ZipFile(GOOD) as z:
        for zi in z.infolist():
            mode = (zi.external_attr >> 16) & 0xFFFF
            template.append((zi.filename, mode))

    missing, written, dirs = [], 0, 0
    with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, mode in template:
            if name.endswith('/'):
                add(z, name, mode or 0o40755)
                dirs += 1
                continue
            src = os.path.join(REPO, name.replace('/', os.sep))
            if not os.path.isfile(src):
                missing.append(name)
                continue
            if not mode:
                # the known-good zip stored no mode for a few entries (update-binary among
                # them). Magisk runs update-binary via `sh`, but KernelSU may exec it, so
                # anything script-like gets 0755 rather than relying on the installer.
                mode = 0o100755 if (name.endswith('.sh') or name.endswith('update-binary')) else 0o100644
            add(z, name, mode, src=src)
            written += 1
        for name, mode in EXTRA:
            src = os.path.join(REPO, name.replace('/', os.sep))
            if os.path.isfile(src):
                add(z, name, mode, src=src)
                written += 1
            else:
                missing.append(name + ' (EXTRA)')

    print(f'  files={written} dirs={dirs} -> {OUT}')
    if missing:
        print('  MISSING from repo (skipped):')
        for m in missing:
            print('   ', m)

    # verify
    with zipfile.ZipFile(OUT) as z:
        infos = z.infolist()
        unix = sum(1 for i in infos if ((i.external_attr >> 16) & 0xFFFF))
        hostunix = sum(1 for i in infos if i.create_system == 3)
        execs = sum(1 for i in infos if (((i.external_attr >> 16) & 0o777) == 0o755) and not i.filename.endswith('/'))
        print(f'VERIFY entries={len(infos)} with-unix-mode={unix} host=unix:{hostunix} exec-files={execs}')
        for probe in ('module.prop', 'install/accd.sh', 'install/diag-collect.sh',
                      'META-INF/com/google/android/update-binary'):
            for i in infos:
                if i.filename == probe:
                    print(f'   {probe:48s} mode={oct((i.external_attr >> 16) & 0xFFFF)} host={i.create_system}')
                    break
            else:
                print(f'   {probe:48s} !! ABSENT')


if __name__ == '__main__':
    main()
