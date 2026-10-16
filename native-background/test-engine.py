# SPDX-License-Identifier: Apache-2.0
"""Background lifecycle/retention tests: compile-time fake sender, never USB."""
from pathlib import Path
import ctypes,json,sys,time,hashlib
ROOT=Path(__file__).resolve().parent.parent
DEST=ROOT/'build/background'/('engine-tests-'+time.strftime('%Y%m%d-%H%M%S'))
# Reuse the existing protocol/fixtures/assertions, without executing its runner.
original=ROOT/'native-async-bridge/test-async.py'
source=original.read_text().split('\ntry:\n    for name,fn in ')[0]
source=source.replace("(s.folder/'test-stop.request').unlink();s.start(listener=False)","(s.folder/'test-stop.request').unlink(missing_ok=True);s.start(listener=False)")
saved=sys.argv;sys.argv=[str(original),str(DEST)]
ns={'__file__':str(original),'__name__':'background_test_support'}
exec(compile(source,str(original),'exec'),ns);sys.argv=saved
ns['BIN']=ROOT/'build/background/x64'
ns['TEST']=ROOT/'build/background-tests/x64/SCX4200-Reliable-Bridge.exe'
kernel=ctypes.WinDLL('kernel32',use_last_error=True)
kernel.OpenEventW.argtypes=[ctypes.c_uint32,ctypes.c_int,ctypes.c_wchar_p];kernel.OpenEventW.restype=ctypes.c_void_p
kernel.SetEvent.argtypes=[ctypes.c_void_p];kernel.CloseHandle.argtypes=[ctypes.c_void_p]
kernel.GetProcessHandleCount.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_uint32)]
require=ns['require'];until=ns['until'];ipp=ns['ipp'];jobid=ns['jobid']
class Session(ns['Session']):
    def start(self,listener=True):
        import subprocess,socket
        args=[str(self.folder/'SCX4200-Reliable-Bridge-Test.exe'),'--background']+(['--mock-transport'] if self.mock else [])
        self.proc=subprocess.Popen(args,cwd=self.folder,stdin=subprocess.DEVNULL,stdout=(self.folder/'stdout.log').open('ab'),stderr=(self.folder/'stderr.log').open('ab'),creationflags=subprocess.CREATE_NO_WINDOW)
        if listener:
            def ready():
                require(self.proc.poll() is None,'Server exited early')
                try:
                    with socket.create_connection(('127.0.0.1',8631),.1):return True
                except OSError:return False
            until(ready,'No listener')
    def stop(self,failed=False):
        h=kernel.OpenEventW(2,False,f'Local\\SCX4200.Stop.{self.proc.pid}')
        require(bool(h),'No Stop event')
        try:require(bool(kernel.SetEvent(h)),'Stop signal failed')
        finally:kernel.CloseHandle(h)
        code=self.proc.wait(75)
        require(code==(1 if failed else 0),f'Wrong stop code {code}')
        require((self.folder/'SESSION-ACTIVE.lock').exists()==failed,'Wrong lock state')
    def handles(self):
        value=ctypes.c_uint32()
        require(kernel.GetProcessHandleCount(int(self.proc._handle),ctypes.byref(value)),'Handle query failed')
        return value.value
ns['Session']=Session
results=[]
def sustained():
    s=Session('sustained_24_documents_then_cancel')
    try:
        baseline=None;ids=[]
        (s.folder/'stub-release.txt').write_text('complete fake writes')
        for i in range(24):
            jid=jobid(s.create());response,elapsed=s.send(jid,ns['FIRST'],True)
            require(response['status']<0x400 and s.terminal(jid)==9,f'Document {i+1} failed')
            ids.append(jid)
            if baseline is None:baseline=s.handles()
        run=next(s.folder.glob('bridge-*'));summary=json.loads((run/'session-result.json').read_text())
        require(summary['completed_pages']==24 and summary['maximum_session_pages'] is None,'Session allowance remains')
        require(summary['decoded_bytes']>180*1024*1024,'Did not cross old decoding cap')
        require(len(list(run.glob('job-*')))<=10,'Successful history is unbounded')
        require(len(list(run.glob('job-*/*.pgm')))==1,'Old successful page captures retained')
        until(lambda:not list((run/'spool').rglob('*.pwg')),'Completed spool retained')
        handles=s.handles();require(handles<=baseline+12,'Cancellation handles leak across documents')
        (s.folder/'stub-release.txt').unlink();(s.folder/'stub-waiting.txt').unlink()
        jid=jobid(s.create());s.send(jid,ns['FIRST']);ns['waiting'](s)
        require(s.ep.request(8,ipp.attribute(0x21,'job-id',jid))['status']<0x400,'Cancel rejected')
        require(s.terminal(jid)==7,'Cancellation event did not work after reuse')
        require(len(s.calls())==25,'Sender replay or wrong call count');s.stop(failed=True)
        return dict(completed_documents=24,decoded_bytes=summary['decoded_bytes'],initial_handles=baseline,final_handles=handles,canceled_job=jid)
    finally:s.close()
def restart():
    s=Session('clean_idle_stop_restart')
    try:
        (s.folder/'stub-release.txt').write_text('release')
        jid=jobid(s.create());s.send(jid,ns['FIRST']);require(s.terminal(jid)==9,'Initial document failed');s.stop()
        require(not list(s.folder.glob('bridge-*/job-*/*.pgm')),'Idle clean shutdown retains page data')
        s.start();jid=jobid(s.create());s.send(jid,ns['SECOND']);require(s.terminal(jid)==9,'Fresh idle restart failed');s.stop()
        return dict(clean_restarts=1,documents=2)
    finally:s.close()
def retained_spool():
    s=Session('client_requested_indefinite_retention')
    try:
        (s.folder/'stub-release.txt').write_text('release')
        response=s.ep.request(5,ipp.attribute(0x42,'job-name','retention test')+b'\x02'+ipp.attribute(0x44,'job-retain-until','indefinite'))
        jid=jobid(response);s.send(jid,ns['FIRST']);require(s.terminal(jid)==9,'Retained document failed')
        run=next(s.folder.glob('bridge-*'))
        until(lambda:not list((run/'spool').glob('*')),'Client retention kept spool data')
        s.stop();return dict(client_retention_overridden=True)
    finally:s.close()
try:
    for name,fn in [('sustained_24_then_cancel',sustained),('clean_restart',restart),('retention_override',retained_spool),('async_cancel_dirty_restart',ns['test_wait_cancel']),('cancel_during_receive',ns['test_cancel_receive']),('uncertain_no_replay',ns['uncertain_failure']),('copies_and_format',ns['reject_copies_and_format'])]:
        detail=fn();results.append(dict(name=name,result='PASS',detail=detail));print(name+': PASS',flush=True)
    for name,doc in [('truncated_page',ns['FIRST'][:-80]),('one_byte_trailing_header',ns['FIRST']+ns['SECOND'][4:5])]:
        detail=ns['invalid'](name,doc);results.append(dict(name=name,result='PASS',detail=detail));print(name+': PASS',flush=True)
except Exception as exc:
    results.append(dict(name='blocking_failure',result='FAIL',error=str(exc)));print(str(exc),flush=True)
report=dict(result='PASS' if all(t['result']=='PASS' for t in results) else 'FAIL',tests=results,usb_access=False,
            test_bridge_sha256=hashlib.sha256(ns['TEST'].read_bytes()).hexdigest(),source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
(DEST/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(result=report['result'],tests=len(results))))
sys.exit(0 if report['result']=='PASS' else 1)
