#!/usr/bin/env python3
"""Exercise the on-screen Original / Enhanced control in a real window.

Earlier switch tests ran hidden and sent a text command, so neither the control
nor the window was ever involved. This copy of the app has its own bundle
identifier, so it cannot read or write the player's preferences, and it uses a
disposable game folder. Its window opens behind the user's windows and never takes
focus. Clicks are AppKit events sent to that window from inside the process, so the
system pointer is never moved and nothing captures the screen.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import time

import numpy as np
from PIL import Image

SUITE = 'com.silentstorm.window-test'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True, help='built Silent Storm.app')
parser.add_argument('--game', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
parser.add_argument('--player-profile', action='store_true', help="start from a copy of the player's saved preferences")
args = parser.parse_args()
game = args.game.resolve()
if not game.is_relative_to(Path('/private/tmp')):
    raise SystemExit('Use a disposable game-data clone under /private/tmp, never player data.')
args.evidence.mkdir(parents=True, exist_ok=False)

stage = args.evidence / 'SilentStormWindowTest.app'
shutil.copytree(args.app, stage, symlinks=True)
with (stage / 'Contents/Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
info['CFBundleIdentifier'] = SUITE
with (stage / 'Contents/Info.plist').open('wb') as handle:
    plistlib.dump(info, handle)
subprocess.run(['xattr', '-cr', str(stage)], check=True)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(stage)], check=True, capture_output=True)

subprocess.run(['defaults', 'delete', SUITE], capture_output=True)
if args.player_profile:
    exported = subprocess.run(['defaults', 'export', 'org.silentstorm.mac', '-'], check=True, capture_output=True).stdout
    subprocess.run(['defaults', 'import', SUITE, '-'], input=exported, check=True)
# The window sits behind others: keep the loop running and stay silent.
subprocess.run(['defaults', 'write', SUITE, 's2.pauseInBackground', '-int', '0'], check=True)
subprocess.run(['defaults', 'write', SUITE, 's2.masterVolume', '-float', '0'], check=True)

for name in ('_s2cmd.txt', '_s2out.txt', '_input.txt', '_settings.req', '_shot.req', '_shot.png'):
    (game / name).unlink(missing_ok=True)
env = os.environ.copy()
env.pop('S2_HEADLESS', None)
env.update(S2_NO_ACTIVATE='1', S2_LOG_TEXTURES='1')
log = (args.evidence / 'run.log').open('wb')
process = subprocess.Popen([str(stage / 'Contents/MacOS/Silent Storm'), '--game-dir', str(game), '-windowed'],
                           cwd=game, env=env, stdout=log, stderr=subprocess.STDOUT)
log.close()


def wait_for(predicate, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'Game exited unexpectedly: {process.returncode}')
        if predicate():
            return
        time.sleep(.1)
    raise TimeoutError('The window run did not complete the requested operation.')


def command(text):
    dest = game / '_s2cmd.txt'
    wait_for(lambda: not dest.exists())
    temp = game / '_s2cmd.tmp'
    temp.write_text(text + '\n')
    temp.replace(dest)
    wait_for(lambda: not dest.exists())


def last(prefix):
    return [x for x in (game / '_s2out.txt').read_text(errors='replace').splitlines() if x.startswith(prefix)][-1]


def fields(line):
    return dict(re.findall(r'(\w+)=([^ ]+)', line))


def selector(action='state'):
    command(f'graphics selector-{action}')
    return fields(last('selector '))


def status():
    command('graphics status')
    return fields(last('graphics mode='))


def shot(name):
    path = game / '_shot.png'
    previous = path.stat().st_mtime_ns if path.exists() else 0
    (game / '_shot.req').touch()
    wait_for(lambda: path.exists() and path.stat().st_mtime_ns > previous)
    shutil.copy2(path, args.evidence / (name + '.png'))
    return Image.open(args.evidence / (name + '.png')).size


steps = []
failures = []


def record(name, **values):
    steps.append({'step': name, **values})
    print(name, json.dumps(values), flush=True)


try:
    command('mac pauseInBackground 0')
    command('cmd mainmenu')
    time.sleep(6)
    start = selector()
    before = status()
    record('start', selector=start, status=before, frame=shot('start'))
    if start['hitControl'] != '1':
        failures.append('A click at the control reaches ' + start['hitClass'] + ', not the control.')
    if start['hidden'] != '0' or start['alpha'] != '1' or start['visible'] != '1':
        failures.append('The control or its window is not visible: ' + str(start))

    selector('original')
    time.sleep(5)
    after = status()
    moved = selector()
    record('click Original', selector=moved, status=after, frame=shot('original'))
    if after['mode'] != 'Original':
        failures.append('First click on Original left the mode at ' + after['mode'])
    if moved['control'] != start['control']:
        failures.append(f"The control moved from {start['control']} to {moved['control']}, so a second click at the same place misses it.")

    selector('enhanced')
    time.sleep(5)
    back = status()
    final = selector()
    record('click Enhanced', selector=final, status=back, frame=shot('enhanced'))
    if back['mode'] != 'Enhanced':
        failures.append('Clicking Enhanced left the mode at ' + back['mode'])
    if back['resolution'] != before['resolution']:
        failures.append(f"Enhanced came back at {back['resolution']}, not {before['resolution']}.")
    for name in ('start', 'original', 'enhanced'):
        pixels = np.asarray(Image.open(args.evidence / (name + '.png')).convert('RGB'), dtype=int)
        height, width, _ = pixels.shape
        magenta = int(((pixels[..., 0] > 200) & (pixels[..., 2] > 200) & (pixels[..., 1] < 80)).sum())
        if magenta:
            failures.append(f'{name}: {magenta} magenta pixels, so an edge of the frame was never painted.')
        # the two rows of menu labels are warm text on black near the bottom of the screen
        band = pixels[int(height * .85):]
        text = (band[..., 0] > 90) & (band[..., 0] > band[..., 2] * 1.5)
        rows = np.where(text.any(axis=1))[0]
        tallest = max(map(len, np.split(rows, np.where(np.diff(rows) > 2)[0] + 1))) if len(rows) else 0
        share = tallest / height * 100
        record(f'{name} text', height_percent=round(share, 2))
        if not 2.8 <= share <= 3.8:
            failures.append(f'{name}: menu text is {share:.2f}% of screen height, not the 3.3% it has at 1024x768.')
    command('quit')
    process.wait(timeout=30)
    sizes = {}
    for id_, w, h in re.findall(r'\[texture-data\] (\d+) (\d+)x(\d+)', (args.evidence / 'run.log').read_text(errors='replace')):
        sizes.setdefault(id_, set()).add((int(w), int(h)))
    swapped = sum(len(v) > 1 for v in sizes.values())
    record('textures swapped', changed_dimensions=swapped)
    if not swapped:
        failures.append('No texture changed size between Original and Enhanced.')
    report = {'passed': not failures, 'failures': failures, 'steps': steps, 'exit': process.returncode}
    (args.evidence / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS' if not failures else 'FAIL', *failures, sep='\n', flush=True)
    raise SystemExit(1 if failures else 0)
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
    subprocess.run(['defaults', 'delete', SUITE], capture_output=True)
