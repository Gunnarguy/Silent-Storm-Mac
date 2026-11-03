#!/usr/bin/env python3
"""Collect clang fix-its for mechanical MSVC-isms across the game sources and apply them once.

Usage: fixits.py [--apply] [--only-failing spike.json]
Only fix-its attached to these diagnostics are applied:
  missing 'typename', explicit qualification required (this->), and 'template' keyword fixes.
"""
import json, os, re, subprocess, sys, collections
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SAFE = ("missing 'typename'", "explicit qualification required", "use 'template' keyword", "requires 'typename'")

spike = open(os.path.join(HERE, 'spike.py')).read()
ns = {'__file__': os.path.join(HERE, 'spike.py')}
# reuse the flag and source discovery from spike.py without running it
exec(spike.split('jobs=')[0].replace("TARGET=sys.argv[1] if len(sys.argv)>1 else 'x86_64'", "TARGET='x86_64'"), ns)
flags, srcs, mods = ns['flags'], ns['srcs'], ns['mods']
jobs = [(m, f) for m in mods for f in srcs.get(m, [])]
if '--only-failing' in sys.argv:
    res = json.load(open(sys.argv[sys.argv.index('--only-failing') + 1]))
    bad = {(m, f) for m, f, e in res if e}
    jobs = [j for j in jobs if j in bad]

fix_re = re.compile(r'^fix-it:"(.*?)":\{(\d+):(\d+)-(\d+):(\d+)\}:"(.*)"$')

def run(job):
    m, f = job
    d = os.path.join(ROOT, m)
    p = subprocess.run(['taskpolicy', '-b'] + flags + ['-fdiagnostics-parseable-fixits', f'-I{d}', os.path.join(d, f)],
                       capture_output=True, text=True, cwd=d, errors='replace')
    out, last = [], ''
    for line in p.stderr.splitlines():
        if ': error:' in line:
            last = line
        mm = fix_re.match(line)
        if mm and any(s in last for s in SAFE):
            out.append((os.path.realpath(mm.group(1)), int(mm.group(2)), int(mm.group(3)), int(mm.group(4)), int(mm.group(5)), mm.group(6)))
    return out

fixes = set()
with ThreadPoolExecutor(6) as ex:
    for r in ex.map(run, jobs):
        fixes.update(r)
by_file = collections.defaultdict(set)
for fx in fixes:
    if fx[0].startswith(ROOT) and '/third_party/' not in fx[0]:
        by_file[fx[0]].add(fx[1:])
print(f'{len(jobs)} files scanned, {sum(map(len, by_file.values()))} unique safe fix-its in {len(by_file)} files')
if '--apply' in sys.argv:
    for path, fx in by_file.items():
        lines = open(path, encoding='latin-1', newline='').read().split('\n')
        for l1, c1, l2, c2, text in sorted(fx, reverse=True):
            if l1 != l2:
                continue
            text = text.encode().decode('unicode_escape')
            s = lines[l1 - 1]
            lines[l1 - 1] = s[:c1 - 1] + text + s[c2 - 1:]
        open(path, 'w', encoding='latin-1', newline='').write('\n'.join(lines))
    print('applied')
