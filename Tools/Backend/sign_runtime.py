#!/usr/bin/env python3
"""Sign every embedded Mach-O, then framework bundles and the helper app."""
import argparse
import plistlib
from pathlib import Path
import subprocess

MAGIC = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
         b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'}


def sign(path, identity, entitlements=None):
    command = ['codesign', '--force', '--sign', identity]
    if identity != '-':
        command += ['--options', 'runtime']
    if entitlements:
        command += ['--entitlements', str(entitlements)]
    subprocess.run(command + [str(path)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--identity', required=True)
    args = parser.parse_args()
    executable = args.app / 'Contents/MacOS/chordadmin-analysis'
    entries = list(args.app.rglob('*'))
    for path in entries:
        if not path.is_file() or path.is_symlink() or path == executable or path.name == 'yt-dlp':
            continue
        with path.open('rb') as handle:
            if handle.read(4) in MAGIC:
                entitlements = Path(__file__).with_name('deno-entitlements.plist') if path.name == 'deno' else None
                sign(path, args.identity, entitlements)
    for path in sorted(entries, key=lambda p: len(p.parts), reverse=True):
        if path.is_dir() and not path.is_symlink() and path.suffix in ('.framework', '.bundle', '.app'):
            sign(path, args.identity)
    sign(executable, args.identity, Path(__file__).with_name('analysis-entitlements.plist'))
    sign(args.app, args.identity, Path(__file__).with_name('analysis-entitlements.plist'))
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
    print('Signed and verified local analysis helper.')


if __name__ == '__main__':
    main()
