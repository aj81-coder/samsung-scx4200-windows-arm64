# SPDX-License-Identifier: Apache-2.0
"""General document tests: real IPP/raster/renderer, fake sender or mock USB."""
from pathlib import Path
import ctypes,json,sys,time,hashlib,shutil,threading,struct,gzip
ROOT=Path(__file__).resolve().parent.parent
base=ROOT/'native-background/test-engine.py'
source=base.read_text().split('\ntry:\n    for name,fn in ')[0]
source=source.replace("ROOT/'build/background'/", "ROOT/'build/general'/")
source=source.replace("ROOT/'build/background/x64'", "ROOT/'build/general/x64'")
source=source.replace("ROOT/'build/background-tests/x64/SCX4200-Reliable-Bridge.exe'", "ROOT/'build/general-tests/x64/SCX4200-Reliable-Bridge.exe'")
exec(compile(source,str(base),'exec'))
tools=DEST/'test-tools';tools.mkdir()
shutil.copy2(ROOT/'build/general/test-tools/SCX4200-Test-Sender.exe',tools/'SCX4200-Test-Sender.exe')
shutil.copy2(ROOT/'build/async/test-tools/renderer-stub.exe',tools/'renderer-stub.exe')
ns['TOOLS']=tools
def terminal(self,job):
    return until(lambda:(state if (state:=self.state(job))>=7 else None),'No terminal job',300)
Session.terminal=terminal

class Memory(ctypes.Structure):
    _fields_=[('cb',ctypes.c_uint32),('faults',ctypes.c_uint32)]+[(n,ctypes.c_size_t) for n in ('peak_working','working','quota_peak_paged','quota_paged','quota_peak_nonpaged','quota_nonpaged','pagefile','peak_pagefile')]
psapi=ctypes.WinDLL('psapi',use_last_error=True)
psapi.GetProcessMemoryInfo.argtypes=[ctypes.c_void_p,ctypes.POINTER(Memory),ctypes.c_uint32]
class Watch:
    def __init__(self,s):self.s=s;self.peak=0;self.max_pgm=0;self.done=False;self.thread=threading.Thread(target=self.run);self.thread.start()
    def run(self):
        while not self.done:
            mem=Memory();mem.cb=ctypes.sizeof(mem)
            if psapi.GetProcessMemoryInfo(int(self.s.proc._handle),ctypes.byref(mem),mem.cb):self.peak=max(self.peak,mem.peak_working)
            self.max_pgm=max(self.max_pgm,len(list(self.s.folder.glob('bridge-*/job-*/*.pgm*'))))
            time.sleep(.02)
    def finish(self):self.done=True;self.thread.join();return dict(peak_engine_working_bytes=self.peak,maximum_simultaneous_pgm_files=self.max_pgm)

def page_bundle(job,index,expected_pgm,label):
    with (job/'document.scxjob').open('rb') as f:
        require(f.read(8)==b'SCXJOB06','Bundle magic');count=struct.unpack('>I',f.read(4))[0]
        require(index<count,'Bundle index missing')
        for i in range(index+1):
            head=f.read(36);require(len(head)==36,'Bundle page header missing');length=struct.unpack('>I',head[:4])[0]
            if i==index:payload=f.read(length)
            else:f.seek(length,1)
    require(hashlib.sha256(payload).digest()==head[4:],'Bundle hash changed')
    pgm=DEST/(label+'.pgm');qpdl=DEST/(label+'.qpdl');pgm.write_bytes(expected_pgm);qpdl.write_bytes(payload)
    return ns['verify'].verify(pgm,qpdl,DEST/(label+'-decoded.png'))

def long_document(count=25):
    s=Session('long_'+str(count)+'_pages');watch=Watch(s)
    try:
        (s.folder/'stub-release.txt').write_text('complete')
        doc=ns['FIRST']+(ns['SECOND'][4:]*(count-1));jid=jobid(s.create());response,elapsed=s.send(jid,doc,True)
        require(response['status']<0x400 and s.terminal(jid)==9,'Long document failed')
        run=next(s.folder.glob('bridge-*'));job=run/f'job-{jid:06d}';summary=json.loads((job/'bridge-result.json').read_text())
        require(summary['document_pages']==count,'Page count lost high bits')
        require(summary['acknowledged_bytes']==summary['usb_bytes'],'Incomplete acknowledgment')
        pixels=[page_bundle(job,0,ns['PGM1'],f'long-{count}-first'),page_bundle(job,count-1,ns['PGM2'],f'long-{count}-last')]
        require(not list(job.glob('*.pgm*')),'Decoded pages retained after conversion')
        require(s.calls()==['call'],'Long document split/replayed sender')
        memory=watch.finish();require(memory['maximum_simultaneous_pgm_files']<=1,'Multiple decoded pages retained');require(memory['peak_engine_working_bytes']<160*1024*1024,'Engine memory grew unbounded')
        s.stop();return dict(pages=count,decoded_bytes=count*2480*3507,send_seconds=elapsed,pixels=pixels,**memory)
    finally:
        if not watch.done:watch.finish()
        s.close()

def dense_document():
    # Literal PackBits: >32MiB actual PWG bytes despite gzip being compact.
    page=bytearray(ns['HEADER'])
    for y in range(3507):
        row=bytes([255])*48+bytes((x+y)%256 for x in range(2480-48)) if y>=63 else bytes([255])*2480
        page.append(0)
        for x in range(0,2480,128):
            packet=row[x:x+128];page.append(257-len(packet) if len(packet)>1 else 0);page.extend(packet)
    doc=bytes(page)+bytes(page[4:])*4
    require(len(doc)>32*1024*1024,'Fixture did not cross former upload limit')
    s=Session('five_dense_pages_over_32MiB',mock=True);watch=Watch(s)
    try:
        jid=jobid(s.create());start=time.monotonic();response,elapsed=s.send(jid,doc,True)
        require(response['status']<0x400 and s.terminal(jid)==9,'Dense document failed')
        run=next(s.folder.glob('bridge-*'));job=run/f'job-{jid:06d}'
        require(len(list(job.glob('mock-transport.json')))==1,'Dense document missed single mock boundary')
        memory=watch.finish();require(memory['maximum_simultaneous_pgm_files']<=1,'Multiple dense pages retained');require(memory['peak_engine_working_bytes']<160*1024*1024,'Dense input uses unbounded engine memory')
        s.stop();return dict(pages=5,pwg_spool_bytes=len(doc),gzip_bytes=len(gzip.compress(doc,mtime=0)),send_seconds=elapsed,total_seconds=time.monotonic()-start,chunked_gzip=True,**memory)
    finally:
        if not watch.done:watch.finish()
        s.close()

def cancellation_conversion():
    s=Session('cancel_during_conversion',renderer='delay')
    try:
        jid=jobid(s.create());s.send(jid,ns['TWO']);until(lambda:(s.folder/'second-renderer-started.txt').exists(),'Renderer not waiting')
        require(s.ep.request(8,ipp.attribute(0x21,'job-id',jid))['status']<0x400,'Conversion cancel rejected')
        require(s.terminal(jid)==7 and not s.calls(),'Canceled conversion reached sender');s.stop(failed=True)
        return dict(sender_calls=0,dirty_lock=True)
    finally:s.close()

def sustained_general():
    s=Session('repeated_documents_no_session_allowance')
    try:
        (s.folder/'stub-release.txt').write_text('complete')
        for _ in range(12):
            jid=jobid(s.create());s.send(jid,ns['FIRST'],True);require(s.terminal(jid)==9,'Repeated document failed')
        run=next(s.folder.glob('bridge-*'));summary=json.loads((run/'session-result.json').read_text())
        require(summary['decoded_bytes']>90*1024*1024 and summary['maximum_session_pages'] is None,'Old decode/session cap remains')
        require(len(list(run.glob('job-*')))<=10,'History grows without bound');require(not list(run.glob('job-*/*.pgm*')),'Completed decoded pages remain')
        require(len(s.calls())==12,'Repeated sender count differs');s.stop();return summary
    finally:s.close()

try:
    for name,fn in [('25_page_document',long_document),('257_page_document',lambda:long_document(257)),('gzip_chunked_pwg_over_32MiB',dense_document),('repeat_jobs_over_90MiB_decode',sustained_general),('cancel_during_conversion',cancellation_conversion),('async_cancel_dirty_restart',ns['test_wait_cancel']),('cancel_during_receive',ns['test_cancel_receive']),('uncertain_no_replay',ns['uncertain_failure'])]:
        detail=fn();results.append(dict(name=name,result='PASS',detail=detail));print(name+': PASS',flush=True)
    for name,doc in [('truncated_page',ns['FIRST'][:-80]),('one_byte_trailing_header',ns['FIRST']+ns['SECOND'][4:5])]:
        detail=ns['invalid'](name,doc);results.append(dict(name=name,result='PASS',detail=detail));print(name+': PASS',flush=True)
except Exception as exc:
    results.append(dict(name='blocking_failure',result='FAIL',error=str(exc)));print(str(exc),flush=True)
report=dict(result='PASS' if all(t['result']=='PASS' for t in results) else 'FAIL',tests=results,usb_access=False,
            test_bridge_sha256=hashlib.sha256(ns['TEST'].read_bytes()).hexdigest(),production_bridge_sha256=hashlib.sha256((ns['BIN']/'SCX4200-Reliable-Bridge.exe').read_bytes()).hexdigest(),sender_sha256=hashlib.sha256((ns['BIN']/'SCX4200-Bridge-Sender.exe').read_bytes()).hexdigest(),source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
(DEST/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(result=report['result'],tests=len(results))))
sys.exit(0 if report['result']=='PASS' else 1)
