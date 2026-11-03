#!/usr/bin/env python3
"""Bounded, resumable HD pack builder and on-disk validator (standard library only)."""
import argparse
import collections
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys


def manifest(path):
    rows = {}
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        v = list(map(int, line.split()))
        if len(v) != 9:
            raise ValueError('Regenerate the manifest with the fixed game: expected id and 8 fields (policy v2).')
        rows[v[0]] = v[1:]
    return rows


def eligible(r, cap=2048):
    usage, w, h, dxt, bump, cube, terrain, protected = r
    return usage != 0 and not protected and not bump and not cube and terrain != 2 and max(w, h) < cap


def validate(path, row, cap=2048):
    """Validate the complete MMP payload, eligibility and aspect/scale against its DB record."""
    if not eligible(row, cap):
        return 'protected or already at size cap'
    data = path.read_bytes()
    if len(data) < 24:
        return 'truncated header'
    sig, fmt, avg, w, h, mips = struct.unpack('<IIIiii', data[:24])
    if sig != 0x504d4d or fmt not in range(1, 10) or not (0 < w <= cap and 0 < h <= cap and 0 < mips <= 14):
        return 'invalid header'
    ow, oh = row[1:3]
    if ow <= 0 or oh <= 0 or w <= ow or w % ow or h % oh or w // ow != h // oh or w // ow not in (2, 4):
        return 'invalid enlargement'
    size = 24
    for _ in range(mips):
        if fmt <= 5:
            size += max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * (8 if fmt == 1 else 16)
        else:
            size += w * h * (4 if fmt == 6 else 2)
        w, h = max(1, w // 2), max(1, h // 2)
    return None if size == len(data) else 'truncated or excess mip payload'


def pixel_failures(report):
    """Reasons from a `texpack compare` table. Structure checks cannot see lost colour; this measures the pixels."""
    failures = {}
    lines = Path(report).read_text().splitlines()
    names = lines[0].split()
    for line in lines[1:]:
        r = dict(zip(names, map(float, line.split())))
        src, hd, mip_src, mip_hd = r['src_mean'], r['hd_mean'], r['mip_src'], r['mip_hd']
        if src >= 4 and not 0.9 <= hd / src <= 1.1:
            reason = f'colour {src:.1f} became {hd:.1f}'
        elif r['hidden_frac'] > 0.001 and r['hidden_src'] > 8 and r['hidden_hd'] < r['hidden_src'] * 0.8:
            reason = f"hidden colour {r['hidden_src']:.1f} became {r['hidden_hd']:.1f}"
        elif mip_src >= 8 and not 0.87 <= mip_hd / mip_src <= 1.15:
            reason = f'distant colour {mip_src:.1f} became {mip_hd:.1f}'
        elif r['alpha_err'] > 8:
            reason = f"alpha moved {r['alpha_err']:.1f}"
        else:
            continue
        failures[str(int(r['id']))] = reason
    return failures


def audit(out, rows, cap):
    valid, invalid = [], {}
    for p in sorted(out.iterdir()):
        if not p.name.isdigit():
            continue
        id_ = int(p.name)
        reason = validate(p, rows[id_], cap) if id_ in rows else 'unknown texture'
        if reason:
            invalid[p.name] = reason
        else:
            valid.append(id_)
    return valid, invalid


def run(args):
    rows = manifest(args.manifest)
    out = Path(args.game) / 'hd/Textures'
    out.mkdir(parents=True, exist_ok=True)
    valid, invalid = audit(out, rows, args.cap)
    if invalid and not args.quarantine:
        raise ValueError(f'{len(invalid)} unsafe overrides; rerun with --quarantine to move them aside')
    if invalid:
        q = Path(args.work) / 'quarantine'
        q.mkdir(parents=True, exist_ok=True)
        for name in invalid:
            dest = q / name
            if dest.exists():
                raise ValueError(f'Quarantine destination exists: {dest}')
            shutil.move(str(out / name), str(dest))
    res = str(Path(args.game) / 'res/Textures.res')
    available = {int(i) for i in subprocess.check_output([args.texpack, 'ids', res], text=True).split()}
    candidates = {i for i, r in rows.items() if eligible(r, args.cap)}
    wanted = candidates & available
    report = {'valid': len(valid), 'quarantined': invalid, 'eligible': len(wanted),
              'unavailable_source': sorted(candidates - available), 'failed': []}
    if args.audit:
        print(json.dumps(report, indent=2))
        return 0

    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    if wanted <= set(valid):
        (work / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
        return 0
    png, batch, up = (work / n for n in ('png', 'batch-v2', 'up-v2'))
    for p in (png, batch, up):
        p.mkdir(parents=True, exist_ok=True)
    # Re-extract on every invocation: inexpensive and also recovers originals stranded by an interrupted batch.
    subprocess.run([args.texpack, 'extract', res, args.manifest, str(png)], check=True)
    groups = collections.defaultdict(list)
    for p in sorted(png.glob('*.png')):
        id_ = int(p.stem.split('_')[0])
        if id_ in wanted and id_ not in valid:
            groups[id_].append(p)
    # Fixed work list, at most two attempts. An encoder returning success without producing a file is a failure.
    pending = sorted(groups)
    for attempt in range(2):
        retry = []
        while pending:
            chosen, count = [], 0
            while pending and (count < args.batch or not chosen):
                id_ = pending.pop(0)
                chosen.append(id_)
                count += len(groups[id_])
            for folder in (batch, up):
                for p in folder.glob('*.png'):
                    p.unlink()
            for id_ in chosen:
                for p in groups[id_]:
                    shutil.copy2(p, batch / p.name)
            with (work / 'upscale-v2.log').open('a') as log:
                status = subprocess.run([args.upscaler, '-i', str(batch), '-o', str(up), '-n', args.model,
                                         '-m', args.models, '-f', 'png'], stdout=subprocess.DEVNULL,
                                        stderr=log, timeout=args.timeout).returncode
            if status == 0:
                subprocess.run([args.texpack, 'build', res, args.manifest, str(up), str(out),
                                '--max', str(args.cap)], check=True, timeout=args.timeout)
            for id_ in chosen:
                p = out / str(id_)
                if p.exists() and validate(p, rows[id_], args.cap) is None:
                    valid.append(id_)
                else:
                    retry.append(id_)
            print(f'Validated {len(set(valid))}/{len(wanted)}; attempt {attempt + 1}, retry {len(retry)}', flush=True)
        pending = retry
        if not pending:
            break
    report['valid'] = len(set(valid))
    report['failed'] = sorted(set(pending) | (wanted - set(valid) - set(groups)))
    (work / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 1 if report['failed'] else 0


def pixels(args):
    """Compare every override with its source and move any that fail aside; the game then uses the original."""
    out = Path(args.game) / 'hd/Textures'
    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    table = work / 'pixels.tsv'
    subprocess.run([args.texpack, 'compare', str(Path(args.game) / 'res/Textures.res'), str(out), str(table)],
                   check=True, stdout=subprocess.DEVNULL, timeout=args.timeout)
    failures = pixel_failures(table)
    if failures and args.quarantine:
        q = work / 'pixel-quarantine'
        q.mkdir(parents=True, exist_ok=True)
        for name in failures:
            shutil.move(str(out / name), str(q / name))
    (work / 'pixels.json').write_text(json.dumps(failures, indent=2) + '\n')
    print(json.dumps({'checked': len(table.read_text().splitlines()) - 1, 'failed': len(failures)}, indent=2))
    return 1 if failures and not args.quarantine else 0


def main():
    tools = Path.home() / 'Library/Developer/SilentStormTools'
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('game'); p.add_argument('manifest'); p.add_argument('work')
    p.add_argument('--audit', action='store_true'); p.add_argument('--quarantine', action='store_true')
    p.add_argument('--pixels', action='store_true', help='measure overrides against their sources after building')
    p.add_argument('--cap', type=int, default=2048); p.add_argument('--batch', type=int, default=100)
    p.add_argument('--timeout', type=int, default=1200)
    native_tool = Path(__file__).resolve().parents[4] / 'runtime/native-tools/s2texpack'
    p.add_argument('--texpack', default=os.environ.get('TEXPACK', str(native_tool)))
    p.add_argument('--upscaler', default=os.environ.get('UPSCALER', str(tools / 'dl-upscayl/upscayl/upscayl-bin-20251207-174704-macos/upscayl-bin')))
    p.add_argument('--models', default=os.environ.get('MODELS', str(tools / 'dl-models')))
    p.add_argument('--model', default=os.environ.get('MODEL', 'ultrasharp-4x'))
    args = p.parse_args()
    try:
        status = run(args)
        return pixels(args) or status if args.pixels else status
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        print(f'HD pack stopped: {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
