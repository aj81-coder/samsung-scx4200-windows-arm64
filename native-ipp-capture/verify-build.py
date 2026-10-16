# SPDX-License-Identifier: Apache-2.0
"""Inspect native architecture/imports and record evidence for packaging."""
import hashlib, json, pathlib, struct
root=pathlib.Path(__file__).resolve().parent.parent
results=[]
for arch,machine in [('x64',0x8664),('arm64',0xaa64)]:
    for name in ['SCX4200-IPP-Capture.exe','cups.dll']:
        p=root/'build'/'ipp'/arch/name
        b=p.read_bytes()
        u16=lambda o:struct.unpack_from('<H',b,o)[0]
        u32=lambda o:struct.unpack_from('<I',b,o)[0]
        pe=u32(60); opt=pe+24
        if b[pe:pe+4]!=b'PE\0\0' or u16(pe+4)!=machine or u16(opt)!=0x20b:
            raise ValueError(f'Wrong PE architecture: {p}')
        table=opt+u16(pe+20)
        sections=[struct.unpack_from('<IIII',b,table+40*i+8) for i in range(u16(pe+6))]
        def offset(rva):
            return next(rva-va+raw for vs,va,rs,raw in sections if va<=rva<va+max(vs,rs))
        imports=[]
        if u32(opt+120):
            pos=offset(u32(opt+120))
            while u32(pos+12):
                at=offset(u32(pos+12))
                imports.append(b[at:b.index(0,at)].decode('ascii'))
                pos+=20
        for dll in imports:
            if dll.lower() not in {'kernel32.dll','advapi32.dll','ws2_32.dll','bcrypt.dll','ntdll.dll','msvcrt.dll','cups.dll'} and not dll.lower().startswith('api-ms-win-'):
                raise ValueError(f'Unexpected dependency {dll}: {p}')
        results.append(dict(architecture=arch,name=name,machine=hex(machine),imports=imports,sha256=hashlib.sha256(b).hexdigest()))
reports=sorted((root/'build/ipp/x64').glob('integration-*.json'))
report=json.loads(reports[-1].read_text(encoding='utf-8-sig'))
if not report['passed'] or 'binaries' not in report: raise ValueError('Missing verified test run')
for result in results[:2]:
    evidence=next(v for v in report['binaries'] if pathlib.Path(v['Path']).name==result['name'])
    if evidence['Hash'].lower()!=result['sha256']: raise ValueError('Tests refer to stale binary')
output=dict(binaries=results,local_tests=report,target_arm64_execution='0.3.0 confirmed on target; 0.3.1 gzip fix awaits target retry',windows_queue_acceptance='0.3.0 queue created with Microsoft IPP Class Driver; target sent Create-Job and gzip Send-Document; no page captured before gzip fix')
(root/'build/ipp/verification.json').write_text(json.dumps(output,indent=2)+'\n')
print(json.dumps(output,indent=2))
