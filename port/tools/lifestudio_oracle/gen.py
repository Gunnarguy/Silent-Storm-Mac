#!/usr/bin/env python3
# gen.py <game dir> <work dir> : extract every animator buffer (Heads.res) and sequence (Sequences.res), list
# the macro muscles of tree.mma, and write the same test script for both drivers:
#   <work>/oracle.cmd (real LifeStudioHeadAPI.dll under Wine) and <work>/native.cmd (port/platform/src/lifestudio.cpp)
# Cases: rest pose of every head; every named macro at -0.7 and 0.9 on three heads; 30 sequences sampled over
# their length on two heads; 40 frames mixing three sequences; 400 random head/sequence/time frames.
import os, random, struct, sys

game, work = sys.argv[1], sys.argv[2]
res = os.path.join(game, 'res')
os.makedirs(os.path.join(work, 'bufs'), exist_ok=True)
os.makedirs(os.path.join(work, 'seqs'), exist_ok=True)

# ---- buffers: Heads.res stores each stream after 0x02 + u32 (length*2+1)
def streams(path, magics):
    d = open(path, 'rb').read()
    out = []
    o = 0
    while True:
        hits = [x for x in (d.find(m, o) for m in magics) if x >= 0]
        if not hits:
            return out
        o = min(hits)
        v = struct.unpack_from('<I', d, o - 4)[0] if o >= 5 else 0
        if o >= 5 and d[o - 5] == 2 and v & 1 and o + (v >> 1) <= len(d):
            out.append(d[o:o + (v >> 1)])
            o += v >> 1
        else:
            o += 4

heads = streams(os.path.join(res, 'Heads.res'), [struct.pack('<I', 0xAD5A018D), struct.pack('<I', 0x37D30DC0)])
for i, b in enumerate(heads):
    open(os.path.join(work, 'bufs', 'h%03d.bin' % i), 'wb').write(b)
seqs = streams(os.path.join(res, 'Sequences.res'), [b'MMSF'])
for i, b in enumerate(seqs):
    open(os.path.join(work, 'seqs', 's%04d.bin' % i), 'wb').write(b)
print('heads', len(heads), 'sequences', len(seqs))

# ---- macro names (named kind-1 records of tree.mma)
tree = open(os.path.join(game, 'tree.mma'), 'rb').read()
macros = []
def walk(o):
    while True:
        h = struct.unpack_from('<8I', tree, o)
        p = tree[o + 32:o + 32 + h[3]]
        if h[0] == 1 and h[2] and not h[1] & 1:
            n = struct.unpack_from('<I', p, h[2])[0]
            macros.append(p[h[2] + 4:h[2] + 4 + n])
        o += 32 + h[3]
        if h[1] & 2:
            o = walk(o)
        if not h[1] & 4:
            return o
walk(0x20)
macros = [m for m in dict.fromkeys(macros) if b' ' not in m]

def seq_time(i):
    return struct.unpack_from('<I', seqs[i], 12)[0]

random.seed(7)
H = lambda i: os.path.join(work, 'bufs', 'h%03d.bin' % i)
S = lambda i: os.path.join(work, 'seqs', 's%04d.bin' % i)
full = [i for i, b in enumerate(heads) if b[:4] == struct.pack('<I', 0xAD5A018D) and struct.unpack_from('<i', b, 4)[0] > 0]
compact = [i for i, b in enumerate(heads) if b[:4] == struct.pack('<I', 0x37D30DC0) and struct.unpack_from('<i', b, 4)[0] > 0]
neck = [i for i in compact if b'Neck_Zone_0' in heads[i]]
plain = [i for i in compact if i not in neck]
pick_heads = [x[0] for x in (full, neck, plain) if x]   # full layout, compact with neck zones, compact without
seq_pick = random.sample(range(len(seqs)), min(30, len(seqs)))
combos = [(random.sample(range(len(seqs)), 3), [random.randrange(0, 3000) for _ in range(3)]) for _ in range(40)]
sweep = [(random.randrange(len(heads)), [(s, random.randrange(0, seq_time(s) + 20)) for s in random.sample(range(len(seqs)), 10)]) for _ in range(40)]

for side in ('oracle', 'native'):
    out = os.path.join(work, side)
    os.makedirs(out, exist_ok=True)
    tree_path = 'tree.mma'   # both drivers run with the work dir as cwd
    c = []
    def begin(h):
        c.extend(['load ' + H(h), 'fill 1', 'tree ' + tree_path, 'reg'])
    for i in range(len(heads)):
        c.extend(['load ' + H(i), 'fill 1', 'out %s/rest_%03d.bin' % (out, i)])
    for h in pick_heads:
        begin(h)
        for k, m in enumerate(macros):
            for j, v in enumerate((-0.7, 0.9)):
                c.extend(['clear', 'add %s %g' % (m.decode('cp1251'), v), 'phys', 'out %s/mm_%03d_%d_%d.bin' % (out, h, k, j)])
    for h in pick_heads[:2]:
        begin(h)
        for s in seq_pick:
            c.append('seq ' + S(s))
            for k in range(52):
                c.extend(['clear', 'render %d' % (seq_time(s) * k // 50 + k % 3), 'phys', 'out %s/sq_%03d_%04d_%d.bin' % (out, h, s, k)])
    for h in pick_heads:
        begin(h)
        for k, (ss, ts) in enumerate(combos):
            c.append('clear')
            for s, t in zip(ss, ts):
                c.extend(['seq ' + S(s), 'render %d' % t])
            c.extend(['phys', 'out %s/cb_%03d_%d.bin' % (out, h, k)])
    for h, frames in sweep:
        begin(h)
        for k, (s, t) in enumerate(frames):
            c.extend(['clear', 'seq ' + S(s), 'render %d' % t, 'phys', 'out %s/sw_%03d_%d.bin' % (out, h, k)])
    c.append('quit')
    open(os.path.join(work, side + '.cmd'), 'w', encoding='cp1251').write('\n'.join(c) + '\n')
print('cases written')
