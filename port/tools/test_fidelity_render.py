#!/usr/bin/env python3
"""Measure actual offscreen presentation, maximum preset and round-trip restoration.

Uses disposable data and preferences. No window, mouse input or OS screen capture.
Frames are SDR shader output; they cannot establish physical-display HDR or PC parity.
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

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--game', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
args = parser.parse_args()
game = args.game.resolve()
if not game.is_relative_to(Path('/private/tmp')) or not (game / '_loadslot.txt').is_file():
    raise SystemExit('Requires a disposable /private/tmp data clone with a tutorial save.')
args.evidence.mkdir(parents=True, exist_ok=False)
env = os.environ.copy()
suite = 'com.silentstorm.fidelity-test.' + str(uuid.uuid4())
env.update(S2_HEADLESS='1', S2_NO_ACTIVATE='1', S2_HEADLESS_PRESENT='1',
           S2_RENDER_AUDIT='1', S2_PERF='1', S2_TEST_DEFAULTS_SUITE=suite)
process = None
captures = {}


def wait_for(predicate, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'Game exited: {process.returncode}')
        if predicate():
            return
        time.sleep(.1)
    raise TimeoutError('Renderer operation timed out.')


def start(number):
    global process
    for name in ('_s2cmd.txt', '_s2out.txt', '_saveload.log', '_shotfinal.req', '_shot.req', '_perf.txt', '_renderaudit.json'):
        (game / name).unlink(missing_ok=True)
    with (args.evidence / f'run-{number}.log').open('wb') as handle:
        process = subprocess.Popen(['/usr/bin/nice', '-n', '10', str(args.binary),
                                    '--game-dir', str(game), '-windowed', '-loadslot'],
                                   cwd=game, env=env, stdout=handle, stderr=subprocess.STDOUT)
    wait_for(lambda: (game / '_saveload.log').exists() and
             'LOAD-SLOT-DONE' in (game / '_saveload.log').read_text(errors='replace'))


def command(text):
    dest = game / '_s2cmd.txt'
    wait_for(lambda: not dest.exists())
    temp = game / '_s2cmd.tmp'
    temp.write_text(text + '\n')
    temp.replace(dest)
    wait_for(lambda: not dest.exists())


def capture(name):
    path = game / '_shotfinal.png'
    raw_path = game / '_shot.png'
    before = path.stat().st_mtime_ns if path.exists() else 0
    raw_before = raw_path.stat().st_mtime_ns if raw_path.exists() else 0
    # The most recent completed two-second window precedes expensive PNG readback.
    perf_lines = (game / '_perf.txt').read_text().splitlines() if (game / '_perf.txt').exists() else []
    (game / '_shot.req').touch()
    (game / '_shotfinal.req').touch()
    wait_for(lambda: path.exists() and path.stat().st_mtime_ns > before)
    # JSON is written after the image; wait for the corresponding frame metadata.
    wait_for(lambda: (game / '_renderaudit.json').exists() and
             (game / '_renderaudit.json').stat().st_mtime_ns >= path.stat().st_mtime_ns)
    shutil.copy2(path, args.evidence / f'{name}-final.png')
    wait_for(lambda: raw_path.exists() and raw_path.stat().st_mtime_ns > raw_before)
    shutil.copy2(game / '_shot.png', args.evidence / f'{name}-backbuffer.png')
    data = json.loads((game / '_renderaudit.json').read_text())
    data['preceding_hidden_throughput_window'] = perf_lines[-1] if perf_lines else None
    data['rss_kib'] = int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(process.pid)], text=True))
    image = np.asarray(Image.open(path).convert('RGB'), dtype=np.float32)
    data['image'] = {'mean_rgb': image.mean(axis=(0, 1)).tolist(),
                     'nonblack_pixel_fraction': float(np.any(image > 0, axis=2).mean()),
                     'clipped_white_pixel_fraction': float(np.all(image >= 255, axis=2).mean())}
    assert data['image']['nonblack_pixel_fraction'] > .1, data
    captures[name] = data
    return data


def stop(number):
    global process
    command('quit')
    process.wait(timeout=30)
    assert process.returncode == 0, process.returncode
    process = None
    for src in ('_perf.txt', '_s2out.txt'):
        if (game / src).exists():
            shutil.copy2(game / src, args.evidence / f'run-{number}-{src.lstrip("_")}')


try:
    start(1)
    command('graphics original')
    time.sleep(4)
    original = capture('original')
    assert original['source'] == original['output'] == [1024, 768], original
    command('graphics maximum')
    time.sleep(8)
    maximum = capture('maximum')
    assert maximum['world_effects_current_frame'], maximum
    assert maximum['source'] == maximum['output'] and maximum['scaling_path'] == 'native', maximum
    assert maximum['anisotropic_override'] == 16 and maximum['ao_target'][0] > 0, maximum
    assert maximum['source'][0] > 1024 and maximum['source'][1] > 768, maximum
    for key, value in [('gfx_depth_tex_resolution', 4096), ('gfx_cl_cube_resolution', 256),
                       ('gfx_register_resolution', 2), ('gfx_fsaa', 0)]:
        command('get ' + key)
        assert re.search(rf'{key} live=1 value={value}(?: |\n)', (game / '_s2out.txt').read_text()), key
    command('graphics original')
    time.sleep(2)
    command('graphics enhanced')
    time.sleep(4)
    restored = capture('maximum-restored')
    for key in ('source', 'output', 'world_target', 'anisotropic_override', 'sharpen', 'scaling_path'):
        assert restored[key] == maximum[key], (key, restored, maximum)
    command('cmd setvar gfx_resolution = 1024x768\ncmd gfx_recreate')
    time.sleep(5)
    capture('maximum-matched-resolution')
    # Prove the final shader really executes, rather than merely reporting a setting.
    command('mac saturation 0\nmac sharpen 0')
    time.sleep(1)
    capture('grayscale-proof')
    final = np.asarray(Image.open(args.evidence / 'grayscale-proof-final.png').convert('RGB'), dtype=np.int16)
    raw = np.asarray(Image.open(args.evidence / 'grayscale-proof-backbuffer.png').convert('RGB'), dtype=np.int16)
    assert np.abs(final[:, :, 0] - final[:, :, 1]).max() <= 1, 'Final shader did not desaturate.'
    assert np.abs(raw[:, :, 0] - raw[:, :, 1]).max() > 20, 'Source was already monochrome.'
    stop(1)
    env['S2_HEADLESS_PRESENT_SIZE'] = '1536x1152'
    start(2)
    command('mac saturation 1\nmac sharpen 0.25\nmac upscaler 0')
    time.sleep(5)
    metalfx = capture('metalfx-proof')
    assert metalfx['source'] == [1024, 768] and metalfx['output'] == [1536, 1152], metalfx
    assert metalfx['scaling_path'] == 'MetalFX', metalfx
    stop(2)
    # Exercise the same one-shot preference used to prepare the player's next launch.
    subprocess.run(['defaults', 'write', suite, 's2.pendingMaximumFidelity', '-bool', 'true'], check=True)
    env.pop('S2_HEADLESS_PRESENT_SIZE', None)
    start(3)
    time.sleep(6)
    pending = capture('maximum-next-launch')
    assert pending['source'] == maximum['source'] and pending['anisotropic_override'] == 16, pending
    stop(3)
    cleared = subprocess.run(['defaults', 'read', suite, 's2.pendingMaximumFidelity'], capture_output=True)
    assert cleared.returncode != 0, 'One-shot profile preference was not consumed.'
    logs = '\n'.join(p.read_text(errors='replace') for p in args.evidence.glob('run-*.log'))
    assert '[texture-allocation] 2d=4096x4096' in logs, 'No actual 4096-square target allocation.'
    assert '[sampler-audit] anisotropy=16' in logs, 'No actual 16x sampler.'
    bad = [line for line in logs.splitlines() if any(s in line.lower() for s in
           ('shader compile failed', 'command buffer failed', 'error domain=mtl', 'unimplemented:', 'not translated'))]
    assert not bad, bad
    report = {'passed': True, 'preference_suite': suite, 'captures': captures,
              'limits': ['SDR offscreen output, no physical HDR verification',
                         'Same tutorial save; animation/time not locked between captures',
                         'No released Windows executable reference run',
                         'Hidden throughput is not on-screen FPS or input latency']}
    (args.evidence / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: actual final shader, native-resolution maximum profile, restore and MetalFX 1.5x.', flush=True)
except BaseException:
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    raise
