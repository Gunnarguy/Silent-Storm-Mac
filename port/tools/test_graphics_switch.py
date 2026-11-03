#!/usr/bin/env python3
"""Exercise original/enhanced rendering in an isolated, hidden game process."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--game', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
args = parser.parse_args()
game = args.game.resolve()
if not game.is_relative_to(Path('/private/tmp')):
    raise SystemExit('Use a disposable game-data clone under /private/tmp, never player data.')
if not (game / '_loadslot.txt').exists():
    raise SystemExit('The clone needs _loadslot.txt pointing to an existing tutorial save.')
args.evidence.mkdir(parents=True, exist_ok=False)
for name in ('_s2cmd.txt', '_s2out.txt', '_input.txt', '_settings.req', '_shot.req'):
    path = game / name
    if path.exists(): shutil.move(str(path), args.evidence / ('previous' + name))
env = os.environ.copy()
env.update(S2_HEADLESS='1', S2_NO_ACTIVATE='1', S2_LOG_TEXTURES='1',
           S2_TEST_DEFAULTS_SUITE='com.silentstorm.graphics-test.' + str(uuid.uuid4()))
process = None
logs = []
statuses = []

def start(number):
    global process
    path = args.evidence / f'run-{number}.log'
    logs.append(path)
    (game / '_saveload.log').unlink(missing_ok=True)
    handle = path.open('wb')
    process = subprocess.Popen(['/usr/bin/nice', '-n', '10', str(args.binary), '--game-dir', str(game), '-windowed', '-loadslot'],
                               cwd=game, env=env, stdout=handle, stderr=subprocess.STDOUT)
    handle.close()

def wait_for(predicate, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None: raise RuntimeError(f'Game exited unexpectedly: {process.returncode}')
        if predicate(): return
        time.sleep(.1)
    raise TimeoutError('Hidden renderer did not complete the requested operation.')

def command(text):
    dest = game / '_s2cmd.txt'
    wait_for(lambda: not dest.exists())
    temp = game / '_s2cmd.tmp'
    temp.write_text(text + '\n')
    temp.replace(dest)
    wait_for(lambda: not dest.exists())

def status(expected=None):
    command('graphics status')
    line = [x for x in (game / '_s2out.txt').read_text().splitlines() if x.startswith('graphics mode=')][-1]
    data = dict(re.findall(r'(\w+)=([^ ]+)', line))
    if expected: assert data['mode'] == expected, line
    assert data['mission'] == '1', 'Mission was lost: ' + line
    statuses.append(data)
    return data

def snapshot(name):
    path = game / '_shot.png'
    previous = path.stat().st_mtime_ns if path.exists() else 0
    (game / '_shot.req').touch()
    wait_for(lambda: path.exists() and path.stat().st_mtime_ns > previous)
    shutil.copy2(path, args.evidence / (name + '.png'))

def stop():
    global process
    # The engine's normal quit path saves only the isolated clone's config.
    dest = game / '_s2cmd.txt'
    dest.write_text('quit\n')
    process.wait(timeout=20)
    assert process.returncode == 0, process.returncode
    process = None

try:
    start(1)
    wait_for(lambda: (game / '_saveload.log').exists() and 'LOAD-SLOT-DONE' in (game / '_saveload.log').read_text(errors='replace'))
    command('mac hdTextures 1\nmac terrainDetail 1024\nmac sharpen 0.42\nmac saturation 1.17\ncmd setvar gfx_resolution = 1280x800\ncmd setvar gfx_gamma = 1.09\ncmd gfx_recreate')
    baseline = status('Enhanced')
    assert baseline['resolution'] == '1280x800' and baseline['hd'] == '1', baseline
    time.sleep(3)
    snapshot('enhanced')
    for cycle in range(2):
        command('graphics original')
        original = status('Original')
        assert original['resolution'] == '1024x768' and original['hd'] == '0' and original['terrain'] == '256', original
        assert all(original[key] == '0' for key in ('ao', 'bloom', 'edr', 'sharpen')), original
        if cycle == 0:
            time.sleep(3)
            snapshot('original')
        command('graphics enhanced')
        enhanced = status('Enhanced')
        assert {k: v for k, v in baseline.items() if k != 'generation'} == {k: v for k, v in enhanced.items() if k != 'generation'}, (baseline, enhanced)
    command('graphics original')
    status('Original')
    stop()
    start(2)
    wait_for(lambda: (game / '_saveload.log').exists() and 'LOAD-SLOT-DONE' in (game / '_saveload.log').read_text(errors='replace'))
    status('Original')
    command('graphics enhanced')
    restored = status('Enhanced')
    assert {k: v for k, v in baseline.items() if k != 'generation'} == {k: v for k, v in restored.items() if k != 'generation'}, (baseline, restored)
    command('get gfx_gamma')
    assert 'gfx_gamma live=1 value=1.09' in (game / '_s2out.txt').read_text()
    command('graphics original')
    status('Original')
    command('graphics reset')
    reset = status('Enhanced')
    assert reset['hd'] == '1' and reset['terrain'] == '1024' and reset['sharpen'] == '0.25' and reset['saturation'] == '1', reset
    stop()
    shutil.copy2(game / '_s2out.txt', args.evidence / 'states.log')
    # Confirm the renderer really read different pixel dimensions for a shared
    # texture across source generations, rather than merely changing its label.
    dimensions = {}
    for path in logs:
        for id_, w, h, generation in re.findall(r'\[texture-data\] (\d+) (\d+)x(\d+) generation=(\d+)', path.read_text(errors='replace')):
            dimensions.setdefault(id_, set()).add((int(w), int(h)))
    changed = {key: sorted(values) for key, values in dimensions.items() if len(values) > 1}
    assert changed, 'No texture actually changed source dimensions.'
    report = {'passed': True, 'headless': True, 'preference_suite': env['S2_TEST_DEFAULTS_SUITE'],
              'states': statuses, 'textures_with_changed_dimensions': changed,
              'restart_restored_enhanced_profile': True}
    report['reset_defaults_leaves_original_mode'] = True
    (args.evidence / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: live graphics/source switches, mission retained, profile restored after restart; {len(changed)} textures changed dimensions', flush=True)
except BaseException:
    if process and process.poll() is None:
        process.terminate()
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
    raise
