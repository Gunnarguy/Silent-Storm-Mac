#!/usr/bin/env python3
"""Install a local native bundle without launching it, retaining the previous app."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build', type=Path, required=True)
parser.add_argument('--backup', type=Path, required=True)
args = parser.parse_args()
app = Path('/Applications/Silent Storm.app')
replacement = app.parent / '.SilentStorm-input-repair.app'
previous = app.parent / '.SilentStorm-before-input-repair.app'
binary = Path('Contents/MacOS/Silent Storm')
if not (args.build / app.name / binary).is_file():
    raise SystemExit('The requested native build is missing.')
if args.backup.exists() or replacement.exists() or previous.exists():
    raise SystemExit('Backup or replacement already exists; inspect before retrying.')
processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True)
if any(line.strip().endswith(str(binary)) for line in processes.splitlines()):
    raise SystemExit('Silent Storm is running. Close it before installing.')

with tempfile.TemporaryDirectory(prefix='ss-native-install-', dir='/private/tmp') as directory:
    stage = Path(directory) / app.name
    shutil.copytree(args.build / app.name, stage)
    subprocess.run(['xattr', '-cr', str(stage)], check=True)
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(stage)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(stage)], check=True)
    symbols = subprocess.check_output(['nm', '-u', str(stage / binary)], text=True)
    for forbidden in ('_CGWarpMouseCursorPosition', '_CGAssociateMouseAndMouseCursorPosition'):
        if forbidden in symbols:
            raise SystemExit(f'Refusing to install a build that still imports {forbidden}.')
    args.backup.mkdir(parents=True)
    shutil.copytree(stage, replacement)
    app.rename(previous)
    try:
        replacement.rename(app)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        digest = hashlib.sha256((app / binary).read_bytes()).hexdigest()
        if digest != hashlib.sha256((stage / binary).read_bytes()).hexdigest():
            raise RuntimeError('Installed binary differs from the verified staged binary.')
    except BaseException:
        if app.exists():
            shutil.move(str(app), args.backup / 'rejected.app')
        previous.rename(app)
        raise
    shutil.move(str(previous), args.backup / app.name)

# The interrupted screenshot request belongs to this repair, not the player.
# Preserve it outside the live game directory so it cannot unexpectedly open the
# menu when the player next launches the app.
command = Path.home() / 'Library/Application Support/Silent Storm/Silent Storm/_s2cmd.txt'
if command.exists() and command.read_text() == 'cmd mainmenu\n':
    shutil.move(str(command), args.backup / 'interrupted-menu-capture.txt')
report = {'installed': str(app), 'backup': str(args.backup), 'binary_sha256': digest,
          'signature': 'verified deep strict', 'pointer_warp_imports': False,
          'launched': False, 'interactive_mouse_validation': 'pending'}
(args.backup / 'install.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
