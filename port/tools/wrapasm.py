"""wrap(file, signature, portable): keep a function's original body for x86 MSVC and add a portable body."""
import re
def wrap(path, sig, portable, occurrence=0):
    s = open(path, encoding='latin-1').read()
    i = -1
    for _ in range(occurrence + 1):
        i = s.find(sig, i + 1)
        assert i >= 0, (path, sig)
    a = s.find('{', i); depth = 0; j = a
    while True:
        c = s[j]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: break
        j += 1
    body = s[a + 1:j]
    if '#if defined(_M_IX86)' in body:
        return
    s = s[:a + 1] + '\n#if defined(_M_IX86)' + body + '#else\n' + portable.strip('\n') + '\n#endif\n' + s[j:]
    open(path, 'w', encoding='latin-1').write(s)

def wrap_block(path, anchor, portable, occurrence=0):
    """Wrap the __asm/_asm { ... } block that starts at the first asm keyword after `anchor`."""
    s = open(path, encoding='latin-1').read()
    i = -1
    for _ in range(occurrence + 1):
        i = s.find(anchor, i + 1)
        assert i >= 0, (path, anchor)
    m = re.compile(r'(__asm|_asm)\s*\{').search(s, i)
    assert m, (path, anchor)
    a = s.find('{', m.start()); depth = 0; j = a
    while True:
        c = s[j]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: break
        j += 1
    line_start = s.rfind('\n', 0, m.start()) + 1
    block = s[line_start:j + 1]
    if s[max(0, line_start - 22):line_start].find('#if defined(_M_IX86)') >= 0:
        return
    s = s[:line_start] + '#if defined(_M_IX86)\n' + block + '\n#else\n' + portable.strip('\n') + '\n#endif' + s[j + 1:]
    open(path, 'w', encoding='latin-1').write(s)
