#!/usr/bin/env python3
"""Install a verified local build and quarantine unsafe HD atlases, preserving a rollback copy."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('hd_pack', HERE / 'texpack/hd_pack.py')
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)

build = Path('/private/tmp/ss-finish-build')
manifest = Path('/private/tmp/ss-finish-evidence/manifest-v2.tsv')
game = Path.home() / 'Library/Application Support/Silent Storm/Silent Storm'
app = Path('/Applications/Silent Storm.app')
backup = HERE.parents[2] / 'backups/2026-10-25-font-and-hd-repair'
stage = Path('/private/tmp/ss-finish-delivery/Silent Storm.app')
if stage.exists() or backup.exists():
    raise SystemExit('Staging or backup already exists; inspect it before retrying installation.')

rows = pack.manifest(manifest)
valid, invalid = pack.audit(game / 'hd/Textures', rows, 2048)
available = {int(i) for i in subprocess.check_output([str(build / 's2texpack'), 'ids', str(game / 'res/Textures.res')], text=True).split()}
wanted = {i for i, r in rows.items() if pack.eligible(r)} & available
if wanted != set(valid):
    raise SystemExit(f'Live pack differs from verified pack: missing {sorted(wanted - set(valid))}')
if any(reason != 'protected or already at size cap' for reason in invalid.values()):
    raise SystemExit(f'Unexpected corrupt overrides: {invalid}')

stage.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(build / 'Silent Storm.app', stage)
subprocess.run(['xattr', '-cr', str(stage)], check=True)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(stage)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(stage)], check=True)
backup.mkdir(parents=True)
shutil.copytree(app, backup / 'Silent Storm.app')
shutil.copy2(game / 'hd/texture_manifest.tsv', backup / 'texture_manifest.tsv')
for name in invalid:
    dest = backup / 'unsafe-atlases' / name
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(game / 'hd/Textures' / name), dest)
shutil.copy2(manifest, game / 'hd/texture_manifest.tsv')

# The previous bundle is backed up. Stage on the destination volume before replacing the live bundle.
replacement = Path('/Applications/.SilentStorm-repair.app')
previous = Path('/Applications/.SilentStorm-previous.app')
if replacement.exists() or previous.exists():
    raise SystemExit('An application replacement is already present; inspect before retrying.')
shutil.copytree(stage, replacement)
app.rename(previous)
try:
    replacement.rename(app)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
except BaseException:
    if app.exists():
        app.rename(Path('/Applications/.SilentStorm-rejected.app'))
    previous.rename(app)
    raise
shutil.move(str(previous), backup / 'replaced-bundle.app')
report = {'installed': str(app), 'backup': str(backup), 'valid_hd_textures': len(valid),
          'quarantined_atlases': sorted(invalid, key=int), 'source_missing': sorted({i for i, r in rows.items() if pack.eligible(r)} - available)}
(backup / 'repair.json').write_text(json.dumps(report, indent=2) + '\n')
shutil.copy2(build / 's2texpack', backup / 's2texpack')
print(json.dumps(report, indent=2))
