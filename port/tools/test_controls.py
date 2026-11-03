#!/usr/bin/env python3
"""Operate every Settings row the way a click does and measure what it changes.

The control inventory only read the source. This drives each row through its real
action in a hidden process with disposable data and preferences, reads the value
back, and compares the final shader output with a baseline that excludes whatever
was already moving. No window, mouse input or screen capture. A row can be fine and
still show nothing in the menu scene: audio, camera, physics and cheats need a mission.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid

from PIL import Image
import numpy as np

SKIP = {'Full_screen'}   # takes the display, and the hidden process has no window to move

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, required=True, help='inside an app with its own bundle identifier, never the game\'s')
parser.add_argument('--game', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
parser.add_argument('--tabs', nargs='*', help='only these Settings tabs')
args = parser.parse_args()
game = args.game.resolve()
if not game.is_relative_to(Path('/private/tmp')):
    raise SystemExit('Use a disposable game-data clone under /private/tmp, never player data.')
if subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier', str(args.binary.parents[1] / 'Info.plist')], capture_output=True, text=True).stdout.strip() == 'org.silentstorm.mac':
    raise SystemExit('Refusing: this binary shares the game\'s identity, so opening the game would bring this test forward.')
args.evidence.mkdir(parents=True, exist_ok=False)
suite = 'com.silentstorm.controls-test.' + str(uuid.uuid4())
exported = subprocess.run(['defaults', 'export', 'org.silentstorm.mac', '-'], check=True, capture_output=True).stdout
subprocess.run(['defaults', 'import', suite, '-'], input=exported, check=True)
subprocess.run(['defaults', 'write', suite, 's2.pauseInBackground', '-int', '0'], check=True)
subprocess.run(['defaults', 'write', suite, 's2.masterVolume', '-float', '0'], check=True)
env = os.environ.copy()
env.update(S2_HEADLESS='1', S2_NO_ACTIVATE='1', S2_HEADLESS_PRESENT='1', S2_TEST_DEFAULTS_SUITE=suite)
for name in ('_s2cmd.txt', '_s2out.txt', '_input.txt', '_shotfinal.req', '_shotfinal.png'):
    (game / name).unlink(missing_ok=True)
log = (args.evidence / 'run.log').open('wb')
process = subprocess.Popen([str(args.binary), '--game-dir', str(game), '-windowed'], cwd=game, env=env, stdout=log, stderr=subprocess.STDOUT)
log.close()


def wait_for(predicate, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'Game exited unexpectedly: {process.returncode}')
        if predicate():
            return
        time.sleep(.05)
    raise TimeoutError('The hidden process did not respond.')


def command(text):
    dest = game / '_s2cmd.txt'
    wait_for(lambda: not dest.exists())
    temp = game / '_s2cmd.tmp'
    temp.write_text(text + '\n')
    temp.replace(dest)
    wait_for(lambda: not dest.exists())


def frame():
    path = game / '_shotfinal.png'
    previous = path.stat().st_mtime_ns if path.exists() else 0
    (game / '_shotfinal.req').touch()
    wait_for(lambda: path.exists() and path.stat().st_mtime_ns > previous)
    return np.asarray(Image.open(path).convert('RGB').resize((160, 120), Image.BOX), dtype=float)


def last(prefix):
    return [x for x in (game / '_s2out.txt').read_text(errors='replace').splitlines() if x.startswith(prefix)][-1]


try:
    command('cmd mainmenu')
    time.sleep(5)
    command('cmd setvar gfx_resolution = 1280x800\ncmd setvar gfx_register_resolution = 1\ncmd gfx_recreate')
    time.sleep(5)
    command('row -1 list')
    count = int(re.search(r'count=(\d+)', last('rows ')).group(1))
    # pixels that move by themselves (fire, smoke) are left out of every comparison
    baseline = [frame() for _ in range(5) if not time.sleep(.5)]
    reference = np.median(baseline, axis=0)
    moving = np.max([abs(f - reference).max(axis=2) for f in baseline], axis=0) > 3
    measure = lambda a, b: float(abs(a - b).mean(axis=2)[~moving].mean())
    results = []
    previous = baseline[-1]
    for index in range(count):
        # look before touching: Full screen must never be operated, it takes over one of the user's displays
        command(f'row {index} info')
        row = dict(re.findall(r'(\w+)=([^ ]+)', last('row ')))
        if row['title'] in SKIP or (args.tabs and row['tab'].replace('_', ' ') not in args.tabs):
            continue
        command(f'row {index} alt')
        row = dict(re.findall(r'(\w+)=([^ ]+)', last('row ')))
        # a renderer rebuild waits half a second, then the scene has to come back
        settle = 2.4 if row['title'].endswith('⟳') else 1.0
        time.sleep(settle)
        changed = frame()
        command(f'row {index} restore')
        time.sleep(settle)
        restored = frame()
        # each row against the frames on either side of it, so a slowly drifting scene does not read as a change
        difference, noise = measure(changed, previous), measure(restored, previous)
        previous = restored
        kept = abs(float(row['after']) - float(row['target'])) <= max(1e-3, abs(float(row['target'])) * .02)
        results.append({'tab': row['tab'].replace('_', ' '), 'title': row['title'].replace('_', ' '), 'before': float(row['before']),
                        'target': float(row['target']), 'after': float(row['after']), 'kept': kept, 'enabled': row['enabled'] == '1',
                        'frame_change': round(difference, 3), 'noise': round(noise, 3),
                        'visible': difference > max(.25, noise * 2.5)})
        print(index, results[-1], flush=True)
    (game / '_s2cmd.txt').write_text('quit\n')
    process.wait(timeout=30)
    (args.evidence / 'controls.json').write_text(json.dumps({'moving_fraction': float(moving.mean()), 'rows': results}, indent=2) + '\n')
    ignored = [r for r in results if not r['kept']]
    print(f'{len(results)} rows, {len(ignored)} did not keep their value, exit {process.returncode}', flush=True)
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
    subprocess.run(['defaults', 'delete', suite], capture_output=True)
