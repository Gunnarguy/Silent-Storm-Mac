#!/usr/bin/env python3
"""Syntax-check every game source file with Homebrew clang and summarise the errors.

Usage: spike.py [x86_64|macos] [--failing]
  x86_64   64-bit Windows target against MinGW headers (dialect and 64-bit check)
  macos    arm64 macOS target with empty Windows header stand-ins (platform surface check)
  --failing  recheck only files that failed last time (results kept in /private/tmp/ssport)
Env: NSITES = how many distinct error sites to print (default 40).
"""
import collections, json, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TARGET = next((a for i, a in enumerate(sys.argv[1:], 1) if not a.startswith('-') and sys.argv[i - 1] != '--mods'), 'x86_64')
OUT = f'/private/tmp/ssport/spike-{TARGET}' + ('-' + sys.argv[sys.argv.index('--mods') + 1].replace(',', '_') if '--mods' in sys.argv else '') + '.json'
CLANG = '/opt/homebrew/opt/llvm/bin/clang++'
MODS = ['Misc', 'FileIO', 'MiscDll', 'Image', 'ADOImport', 'FModSound', 'Input', 'Script', 'DBFormat', 'Main', 'Game']

common = ['-fms-extensions', '-fdelayed-template-parsing', '-fno-operator-names', '-Wno-address-of-temporary',
          '-std=gnu++14', '-fsyntax-only', '-ferror-limit=0', '-w', '-DNDEBUG', '-DexternA5=extern',
          f'-I{ROOT}/port/compat', f'-I{ROOT}/third_party/zlib', f'-I{ROOT}/third_party/libpng',
          f'-I{ROOT}/third_party/squish', f'-I{ROOT}/third_party/lifestudio/include', f'-I{ROOT}/third_party']
if TARGET == 'macos':
    sdk = subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    flags = [CLANG, '--target=arm64-apple-macos14', f'-isysroot{sdk}', f'-I{ROOT}/port/compat/mac', f'-I{ROOT}/port/platform/include'] + common
else:
    tc = f'/opt/homebrew/opt/mingw-w64/toolchain-{TARGET}/{TARGET}-w64-mingw32'
    cxx = sorted(os.listdir(f'{tc}/include/c++'))[-1]
    flags = [CLANG, f'--target={TARGET}-w64-windows-gnu', f'--sysroot={tc}', '-nostdinc++',
             f'-isystem{tc}/include/c++/{cxx}', f'-isystem{tc}/include/c++/{cxx}/{TARGET}-w64-mingw32',
             '-DWIN32', '-D_WINDOWS'] + common

text = open(f'{ROOT}/sources.cmake').read()
srcs = {m.group(1): re.findall(r'"([^"]+)"', m.group(2)) for m in re.finditer(r'set\((\w+)_SRC(.*?)\)', text, re.S)}
if '--mods' in sys.argv:
    MODS = sys.argv[sys.argv.index('--mods') + 1].split(',')
jobs = [(m, f) for m in MODS for f in srcs.get(m, [])]
keep = []
if '--failing' in sys.argv and os.path.exists(OUT):
    prev = json.load(open(OUT))
    bad = {(m, f) for m, f, e in prev if e}
    keep = [r for r in prev if not r[2]]
    jobs = [j for j in jobs if j in bad]

def run(job):
    m, f = job
    d = f'{ROOT}/{m}'
    p = subprocess.run(['taskpolicy', '-b'] + flags + [f'-iquote{d}', f'{d}/{f}'], capture_output=True, text=True, cwd=d, errors='replace')
    return [m, f, [l for l in p.stderr.splitlines() if ': error:' in l or 'fatal error:' in l]]

if __name__ == '__main__':
    res = keep + list(ThreadPoolExecutor(6).map(run, jobs))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(res, open(OUT, 'w'))
    ok = sum(1 for r in res if not r[2])
    print(f'{TARGET}: {ok}/{len(res)} files compile clean; total errors {sum(len(r[2]) for r in res)}')
    per = collections.Counter(); kinds = collections.Counter(); sites = collections.Counter(); ex = {}
    for m, f, e in res:
        per[m] += len(e)
        for l in e:
            mm = re.match(r'(.*?):(\d+):\d+: (?:fatal )?error: (.*)', l)
            if not mm:
                continue
            kinds[re.sub(r"'[^']*'", "'X'", mm.group(3))[:90]] += 1
            k = os.path.normpath(mm.group(1)).replace(ROOT + '/', '') + ':' + mm.group(2)
            sites[k] += 1; ex[k] = mm.group(3)[:110]
    print('errors by module:', dict(per))
    for k, v in kinds.most_common(12):
        print(f'{v:6d}  {k}')
    print('unique sites', len(sites))
    for k, v in sites.most_common(int(os.environ.get('NSITES', '40'))):
        print(v, k, '|', ex[k])
