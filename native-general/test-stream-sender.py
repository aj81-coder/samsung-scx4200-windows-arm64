# SPDX-License-Identifier: Apache-2.0
"""Offline tests; production entry point used only with --validate-only."""
from pathlib import Path
import hashlib, struct, subprocess, json, re, datetime
p=Path(__file__).resolve().parent;root=p.parent
out=root/'build/general'/('sender-tests-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
out.mkdir(parents=True)
src=(root/'native-render-print/job_validator.h').read_text()
prefix=''.join(re.findall(r'"(.*)"',src.split('static const unsigned char job_prefix[] =',1)[1].split(';',1)[0]))
prefix=bytes(prefix,'ascii').decode('unicode_escape').encode('latin1')
header=bytes([0,3,0,1,2,9,176,13,181,1,0,1,0,2,1,1,3]);footer=bytes([1,0,1,9,27,37,45,49,50,51,52,53,88])
# A valid all-white 0x0d packet with a long zero terminator/padding section.
payload=bytes(2*1024*1024);band=bytes([12,0,9,176,0,64,13])+struct.pack('>I',len(payload)+4)+payload+bytes(4)
page=prefix+header+band+footer;count=25
bundle=out/'large.scxjob';digest=hashlib.sha256();expected=hashlib.sha256()
with bundle.open('wb') as f:
    h=b'SCXJOB06'+struct.pack('>I',count);f.write(h);digest.update(h)
    for _ in range(count):
        h=struct.pack('>I',len(page))+hashlib.sha256(page).digest();f.write(h);f.write(page);digest.update(h);digest.update(page);expected.update(page)
sender=root/'build/general/x64/SCX4200-Sender.exe';h=digest.hexdigest();results=[]
def run(name,args,code):
    r=subprocess.run(list(map(str,args)),capture_output=True,text=True)
    results.append(dict(name=name,exit=r.returncode,expected=code,stdout=r.stdout,stderr=r.stderr));assert r.returncode==code,results[-1]
run('large validate',[sender,'--jobbundle',bundle,'--sha256',h,'--validate-only'],0)
run('wrong full hash',[sender,'--jobbundle',bundle,'--sha256','0'*64,'--validate-only'],3)
truncated=out/'truncated.scxjob'
with bundle.open('rb') as a,truncated.open('wb') as b:b.write(a.read(12+36+len(page)-1))
run('truncated last page',[sender,'--jobbundle',truncated,'--sha256',hashlib.sha256(truncated.read_bytes()).hexdigest(),'--validate-only'],3)
for name,offset,value in [('page digest',16,1),('page QPDL',48,1),('page count',11,26)]:
    damaged=out/(name.replace(' ','-')+'.scxjob')
    with bundle.open('rb') as a,damaged.open('wb') as b:
        while chunk:=a.read(1024*1024):b.write(chunk)
    with damaged.open('r+b') as f:f.seek(offset);f.write(bytes([value]))
    with damaged.open('rb') as f:bad_hash=hashlib.file_digest(f,'sha256').hexdigest()
    run(name+' with correct full hash',[sender,'--jobbundle',damaged,'--sha256',bad_hash,'--validate-only'],3)
bad_page=bytearray(page);bad_page[0]^=1
bad=out/'invalid-qpdl-correct-hashes.scxjob'
with bad.open('wb') as f:
    f.write(b'SCXJOB06'+struct.pack('>I',1)+struct.pack('>I',len(bad_page))+hashlib.sha256(bad_page).digest()+bad_page)
run('invalid QPDL with both correct hashes',[sender,'--jobbundle',bad,'--sha256',hashlib.sha256(bad.read_bytes()).hexdigest(),'--validate-only'],3)
run('stream delivery harness',[root/'build/general/x64/sender-stream-tests.exe',bundle,h,out/'usb-bytes.bin'],0)
actual=hashlib.file_digest((out/'usb-bytes.bin').open('rb'),'sha256').hexdigest();assert actual==expected.hexdigest()
run('inherited transport self tests',[sender,'--self-test'],0)
(out/'results.json').write_text(json.dumps(dict(result='PASS',pages=count,bundle_bytes=bundle.stat().st_size,payload_sha256=actual,tests=results),indent=2))
print(out/'results.json')
