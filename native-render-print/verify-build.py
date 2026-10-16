# SPDX-License-Identifier: Apache-2.0
"""Record PE architecture, dependencies and test hashes; no device access."""
import hashlib, json, pathlib, struct
root = pathlib.Path(__file__).resolve().parent.parent
items = []
for arch, machine in [('x64', 0x8664), ('arm64', 0xaa64)]:
    for relative in [f'{arch}/SCX4200-Render.exe', f'scx4200-render-print-{arch}.exe']:
        path = root / 'build/render-print' / relative
        data = path.read_bytes()
        u16 = lambda p: struct.unpack_from('<H', data, p)[0]
        u32 = lambda p: struct.unpack_from('<I', data, p)[0]
        pe = u32(60)
        opt = pe + 24
        if data[pe:pe+4] != b'PE\0\0' or u16(pe+4) != machine or u16(opt) != 0x20b:
            raise ValueError(f'Wrong PE architecture: {relative}')
        table = opt + u16(pe+20)
        sections = [struct.unpack_from('<IIII', data, table+40*i+8) for i in range(u16(pe+6))]
        def offset(rva):
            return next(rva-va+raw for vs,va,rs,raw in sections if va <= rva < va+max(vs,rs))
        imports = []
        if u32(opt+120):
            pos = offset(u32(opt+120))
            while u32(pos+12):
                at = offset(u32(pos+12))
                imports.append(data[at:data.index(0, at)].decode('ascii'))
                pos += 20
        if any(d.lower() not in {'kernel32.dll','msvcrt.dll','setupapi.dll','bcrypt.dll','advapi32.dll','user32.dll','ntdll.dll'} and not d.lower().startswith('api-ms-win-') for d in imports):
            raise ValueError(f'Unexpected dependency: {relative}: {imports}')
        items.append(dict(architecture=arch, path=relative, sha256=hashlib.sha256(data).hexdigest(), imports=imports))
tests = json.loads((root/'build/render-print/renderer-tests-final/results.json').read_text())
for item, field in zip(items[:2], ['renderer_sha256','sender_sha256']):
    if item['sha256'] != tests[field]:
        raise ValueError('Tests reference stale binaries')
if tests['result'] != 'PASS':
    raise ValueError('Renderer checks failed')
output = dict(binaries=items, renderer_tests=tests, target_execution='ARM64 renderer and runtime sender await controlled target paper test')
(root/'build/render-print/build-verification.json').write_text(json.dumps(output, indent=2)+'\n')
print(json.dumps(output, indent=2))
