# SPDX-License-Identifier: Apache-2.0
"""Check native architecture, import dependencies and fresh mock evidence."""
from pathlib import Path
import hashlib,json,struct,sys
root=Path(__file__).resolve().parent.parent
tests=json.loads(Path(sys.argv[1]).read_text())
if tests['result']!='PASS' or tests['usb_access'] is not False:raise ValueError('Mock integration tests failed')
items=[]
for arch,machine in [('x64',0x8664),('arm64',0xaa64)]:
 for name in ['SCX4200-Reliable-Bridge.exe','cups.dll','SCX4200-Render.exe','SCX4200-Bridge-Sender.exe']:
  p=root/'build/reliable'/arch/name;b=p.read_bytes()
  u16=lambda o:struct.unpack_from('<H',b,o)[0];u32=lambda o:struct.unpack_from('<I',b,o)[0]
  pe=u32(60);opt=pe+24
  if b[pe:pe+4]!=b'PE\0\0' or u16(pe+4)!=machine or u16(opt)!=0x20b:raise ValueError('Wrong PE architecture')
  table=opt+u16(pe+20);sections=[struct.unpack_from('<IIII',b,table+40*i+8) for i in range(u16(pe+6))]
  def offset(rva):return next(rva-va+raw for vs,va,rs,raw in sections if va<=rva<va+max(vs,rs))
  imports=[]
  if u32(opt+120):
   pos=offset(u32(opt+120))
   while u32(pos+12):
    at=offset(u32(pos+12));imports.append(b[at:b.index(0,at)].decode('ascii'));pos+=20
  for dll in imports:
   if dll.lower() not in {'kernel32.dll','advapi32.dll','ws2_32.dll','bcrypt.dll','ntdll.dll','msvcrt.dll','cups.dll','setupapi.dll','user32.dll'} and not dll.lower().startswith('api-ms-win-'):raise ValueError('Unexpected runtime '+dll)
  sha=hashlib.sha256(b).hexdigest()
  if arch=='x64' and tests[name+'_sha256']!=sha:raise ValueError('Stale IPP test evidence')
  items.append(dict(architecture=arch,name=name,sha256=sha,imports=imports))
sender=json.loads((root/'build/reliable-bridge/sender-validation.json').read_text())
for arch in ['x64','arm64']:
 binary=next(b for b in items if b['architecture']==arch and b['name']=='SCX4200-Bridge-Sender.exe')
 if sender[arch+'_sha256'].lower()!=binary['sha256']:raise ValueError('Stale sender tests')
renderer_evidence=json.loads((root/'build/render-print/build-verification.json').read_text())
for arch in ['x64','arm64']:
 expected=next(b for b in renderer_evidence['binaries'] if b['architecture']==arch and b['path'].endswith('SCX4200-Render.exe'))['sha256']
 actual=next(b for b in items if b['architecture']==arch and b['name']=='SCX4200-Render.exe')['sha256']
 if expected!=actual:raise ValueError('Renderer differs from independently tested build')
selftest=json.loads((root/'build/reliable-bridge/sender-self-test.json').read_text())
if selftest['outcome']!='PASS' or selftest['usb_print_writes']!=0:raise ValueError('Sender wait/cancel tests failed')
for arch in ['arm64','x64']:
 expected=sender[arch+'_sha256']
 evidence=next(b for b in selftest['binaries'] if b['Path'].endswith('-'+arch+'.exe'))
 if evidence['Hash'].lower()!=expected.lower():raise ValueError('Stale wait/cancel selftests')
fixture=json.loads((root/'build/reliable/fixture-path-validation.json').read_text())
focused=json.loads((root/'build/reliable/fixture-stub-focused/results.json').read_text())
if fixture['result']!='PASS' or focused['result']!='PASS':raise ValueError('Fresh source fixture checks failed')
if hashlib.sha256((root/'native-reliable-bridge/test-header.bin').read_bytes()).hexdigest()!=fixture['header_sha256']:raise ValueError('Stale fixture header')
output=dict(result='PASS',binaries=items,local_ipp_tests=tests,sender_tests=sender,pending_write_tests=selftest,fresh_source_fixtures=fixture,fresh_source_stub_tests=focused,target_paper_refill='Awaiting physical target paper-wait test; 0.6.0 multipage and repeated jobs physically proved')
(root/'build/reliable/verification.json').write_text(json.dumps(output,indent=2)+'\n')
print('Native architectures, imports, test hashes: PASS')
