# SPDX-License-Identifier: Apache-2.0
"""Check release PE/imports, test hashes and unchanged printing components."""
from pathlib import Path
import hashlib,json,struct,sys
root=Path(__file__).resolve().parent.parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
tests=json.loads(Path(sys.argv[1]).read_text())
if tests['result']!='PASS' or tests['usb_access'] is not False:raise ValueError('Device-free tests must pass')
required={'async_response_and_cancel','repeated_jobs_and_pixels','cancel_during_receive','production_binary_mock_smoke','dense_raster_sanity','uncertain_acknowledgment','one_byte_next_header','cancel_during_conversion','gzip_decoded_32MiB_bound'}
if not required.issubset({t['name'] for t in tests['tests'] if t['result']=='PASS'}):raise ValueError('Required acceptance tests missing')
if tests['test_source_sha256']!=sha(Path(__file__ ).with_name('test-async.py')):raise ValueError('Tests changed after run')
if tests['test_bridge_sha256']!=sha(root/'build/async-tests/x64/SCX4200-Reliable-Bridge.exe'):raise ValueError('Stale test binary')
if tests['test_sender_sha256']!=sha(root/'build/async/test-tools/SCX4200-Test-Sender.exe'):raise ValueError('Stale test sender')
post=json.loads((root/'build/async/post-cancel-20261014/results.json').read_text())
if post['result']!='PASS' or post['usb_access'] is not False or post['test_bridge_sha256']!=tests['test_bridge_sha256']:raise ValueError('Post-cancel admission evidence failed or stale')
if post['test_source_sha256']!=sha(Path(__file__).with_name('test-post-cancel.py')):raise ValueError('Post-cancel test changed')
baseline=json.loads((root/'build/reliable/verification.json').read_text())
items=[]
for arch,machine in [('x64',0x8664),('arm64',0xaa64)]:
 for name in ['SCX4200-Reliable-Bridge.exe','cups.dll','SCX4200-Render.exe','SCX4200-Bridge-Sender.exe']:
  p=root/'build/async'/arch/name;b=p.read_bytes()
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
  digest=sha(p)
  if arch=='x64' and tests['binaries'][name]!=digest:raise ValueError('Stale integration evidence')
  if name in ('SCX4200-Render.exe','SCX4200-Bridge-Sender.exe'):
   previous=next(v for v in baseline['binaries'] if v['architecture']==arch and v['name']==name)
   if previous['sha256'].lower()!=digest:raise ValueError('Previously verified print component changed')
  items.append(dict(architecture=arch,name=name,sha256=digest,imports=imports))
sources={}
for arch in ('x64','arm64'):
 for name in ('job-ipp.c','job-process.c','job.c'):
  path=root/'build/async/dep'/arch/'pappl-config'/name
  sources[f'{arch}/{name}']=sha(path)
for name in ('job-ipp.c','job-process.c','job.c'):
 if sources['x64/'+name]!=sources['arm64/'+name]:raise ValueError('Framework guard sources differ by architecture')
for arch in ('x64','arm64'):
 for name in ('http.c','raster-stream.c'):
  sources[f'{arch}/{name}']=sha(root/'build/async/dep'/arch/'cups-config'/name)
for name in ('http.c','raster-stream.c'):
 if sources['x64/'+name]!=sources['arm64/'+name]:raise ValueError('CUPS guard sources differ by architecture')
for name in ('bridge.c','prepare-async-guards.ps1','prepare-http-guards.ps1','build-dependencies.ps1','build-bridge.ps1'):
 sources[name]=sha(Path(__file__).with_name(name))
out=dict(result='PASS',binaries=items,generated_and_application_sources=sources,local_tests=tests,post_cancel_tests=post,
 target_acceptance='Awaiting physical normal-print and ordinary Windows queue cancellation test; direct cancellation and paper refill passed on0.7.')
(root/'build/async/verification.json').write_text(json.dumps(out,indent=2)+'\n')
print('PASS: PE architectures/imports, test hashes, unchanged renderer/sender, generated guard parity')
