# SPDX-License-Identifier: Apache-2.0
"""Own-process integration: production tray + real IPP engine + fake USB child."""
from pathlib import Path
import ctypes,hashlib,json,shutil,socket,subprocess,time
from ctypes import wintypes
ROOT=Path(__file__).resolve().parent.parent
base=ROOT/'native-background/test-engine.py'
ns={'__file__':str(base),'__name__':'integration_support'}
exec(compile(base.read_text().split('\ntry:\n    for name,fn in ')[0],str(base),'exec'),ns)
support=ns;ns=support['ns']
OUT=support['DEST'];require=ns['require'];until=ns['until'];Session=support['Session'];ipp=ns['ipp']
results=[]
def run(name,fn):
    detail=fn();results.append(dict(name=name,result='PASS',detail=detail));print(name+': PASS',flush=True)
def pending_stop():
    s=Session('stop_pending_job')
    try:
        jid=ns['jobid'](s.create());start=time.monotonic();s.stop(failed=True)
        return dict(pending_job=jid,stop_seconds=round(time.monotonic()-start,3),lock_retained=True,sender_calls=len(s.calls()))
    finally:s.close()
def guards():
    folder=OUT/'startup_guards';folder.mkdir()
    exe=ROOT/'build/background-tests/x64/SCX4200-Reliable-Bridge.exe'
    # An existing controls marker is preserved; startup must not create a session.
    (folder/'CONTROL-ACTIVE.lock').write_text('control owns this')
    proc=subprocess.run([str(exe),'--background'],cwd=folder,capture_output=True,timeout=5)
    require(proc.returncode==1 and not (folder/'SESSION-ACTIVE.lock').exists(),'Control marker bypassed')
    (folder/'CONTROL-ACTIVE.lock').unlink()
    k=ctypes.WinDLL('kernel32',use_last_error=True)
    k.CreateMutexW.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_wchar_p];k.CreateMutexW.restype=ctypes.c_void_p
    k.ReleaseMutex.argtypes=[ctypes.c_void_p];k.CloseHandle.argtypes=[ctypes.c_void_p]
    gate=k.CreateMutexW(None,True,'Local\\SCX4200.ControlGate');require(bool(gate),'No control mutex')
    try:
        proc=subprocess.run([str(exe),'--background'],cwd=folder,capture_output=True,timeout=5)
        require(proc.returncode==1 and not (folder/'SESSION-ACTIVE.lock').exists(),'Control mutex bypassed')
    finally:k.ReleaseMutex(gate);k.CloseHandle(gate)
    proc=subprocess.run([str(exe)],cwd=folder,capture_output=True,timeout=5)
    require(proc.returncode==64 and not (folder/'SESSION-ACTIVE.lock').exists(),'Implicit background printing enabled')
    return dict(marker_and_mutex_refused=True,explicit_mode_required=True)
def locked_cleanup():
    s=Session('locked_completed_capture')
    handle=None;k=ctypes.WinDLL('kernel32',use_last_error=True)
    k.CreateFileW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p];k.CreateFileW.restype=ctypes.c_void_p
    k.CloseHandle.argtypes=[ctypes.c_void_p]
    try:
        (s.folder/'stub-release.txt').write_text('release')
        first=ns['jobid'](s.create());s.send(first,ns['FIRST']);require(s.terminal(first)==9,'Initial document failed')
        run=next(s.folder.glob('bridge-*'));first_dir=run/f'job-{first:06d}'
        before=(first_dir/'bridge-result.json').read_bytes()
        handle=k.CreateFileW(str(first_dir/'page-01.pgm'),0x80000000,1,None,3,0,None)
        require(handle not in (None,ctypes.c_void_p(-1).value),'Capture lock failed')
        second=ns['jobid'](s.create());s.send(second,ns['FIRST']);require(s.terminal(second)==8,'Cleanup failure not blocked')
        require(s.calls()==['call'],'Cleanup failure sent new data')
        require((first_dir/'bridge-result.json').read_bytes()==before,'Completed result overwritten as failed')
        s.stop(failed=True)
        return dict(prior_result_preserved=True,new_job_aborted_without_sender=True)
    finally:
        if handle not in (None,ctypes.c_void_p(-1).value):k.CloseHandle(handle)
        s.close()
def host_engine():
    app=OUT/'integrated app';data=OUT/'integrated data';app.mkdir();data.mkdir()
    for name in ('SCX4200-Printer.exe','SCX4200-Render.exe','cups.dll'):
        shutil.copy2(ROOT/'build/background/x64'/name,app/name)
    # The bridge only knows its compile-time fake sender; no production sender is copied.
    shutil.copy2(ROOT/'build/background-tests/x64/SCX4200-Reliable-Bridge.exe',app/'SCX4200-Reliable-Bridge.exe')
    shutil.copy2(ROOT/'build/async/test-tools/SCX4200-Test-Sender.exe',app/'SCX4200-Test-Sender.exe')
    (data/'stub-release.txt').write_text('release')
    host=subprocess.Popen([str(app/'SCX4200-Printer.exe'),'--data-dir',str(data)],creationflags=subprocess.CREATE_NO_WINDOW)
    u=ctypes.WinDLL('user32',use_last_error=True);w=ctypes.wintypes
    cbtype=ctypes.WINFUNCTYPE(w.BOOL,w.HWND,w.LPARAM)
    u.EnumWindows.argtypes=[cbtype,w.LPARAM];u.GetWindowThreadProcessId.argtypes=[w.HWND,ctypes.POINTER(w.DWORD)]
    u.PostMessageW.argtypes=[w.HWND,w.UINT,w.WPARAM,w.LPARAM]
    u.SendMessageTimeoutW.argtypes=[w.HWND,w.UINT,w.WPARAM,w.LPARAM,w.UINT,w.UINT,ctypes.POINTER(ctypes.c_size_t)]
    def find_window():
        found=[]
        @cbtype
        def callback(hwnd,param):
            pid=w.DWORD();u.GetWindowThreadProcessId(hwnd,ctypes.byref(pid))
            if pid.value==host.pid:found.append(hwnd)
            return True
        u.EnumWindows(callback,0);return found[0] if found else None
    def ready():
        require(host.poll() is None,'Host exited')
        try:
            with socket.create_connection(('127.0.0.1',8631),.1):return True
        except OSError:return False
    try:
        hwnd=until(find_window,'Own tray window unavailable');until(ready,'Host did not start real engine')
        ep=ipp.Endpoint('http://127.0.0.1:8631/ipp/print')
        jid=ns['jobid'](ep.request(5,ipp.attribute(0x42,'job-name','Own integration test')))
        import gzip
        extra=ipp.attribute(0x21,'job-id',jid)+ipp.attribute(0x22,'last-document',b'\x01')+ipp.attribute(0x49,'document-format','image/pwg-raster')+ipp.attribute(0x44,'compression','gzip')
        require(ep.request(6,extra,gzip.compress(ns['FIRST'],mtime=0))['status']<0x400,'Integrated submit failed')
        until(lambda:ep.request(9,ipp.attribute(0x21,'job-id',jid))['attributes'].get('job-state',[0])[0]==9,'Nested sender job failed',40)
        require((data/'stub-calls.txt').read_text().splitlines()==['call'],'Wrong nested sender call count')
        # Simulate Windows asking this own host to end its session; no real logoff.
        outcome=ctypes.c_size_t();start=time.monotonic()
        require(u.SendMessageTimeoutW(hwnd,0x11,0,0,2,5000,ctypes.byref(outcome)),'Logoff query hung')
        elapsed=time.monotonic()-start
        until(lambda:not (data/'SESSION-ACTIVE.lock').exists(),'Idle logoff left dirty lock',3)
        require(elapsed<3.5,'Idle logoff exceeded bounded wait')
        u.PostMessageW(hwnd,0x111,1003,0);require(host.wait(10)==0,'Host did not quit')
        return dict(nested_host_engine_sender_jobs=True,documents=1,logoff_query_seconds=round(elapsed,3),clean_idle_lock_cleared=True)
    finally:
        if host.poll() is None:host.terminate();host.wait(5)
try:
    for name,fn in [('pending_shutdown',pending_stop),('startup_control_guards',guards),('cleanup_failure_blocks_new_job',locked_cleanup),('real_host_engine_fake_sender',host_engine)]:run(name,fn)
except Exception as exc:
    results.append(dict(name='blocking_failure',result='FAIL',error=str(exc)));print(str(exc),flush=True)
report=dict(result='PASS' if all(r['result']=='PASS' for r in results) else 'FAIL',tests=results,usb_access=False,system_registration_changed=False,
            source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),test_bridge_sha256=hashlib.sha256(ns['TEST'].read_bytes()).hexdigest(),host_sha256=hashlib.sha256((ROOT/'build/background/x64/SCX4200-Printer.exe').read_bytes()).hexdigest())
(OUT/'integration-results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(result=report['result'],tests=len(results))))
raise SystemExit(0 if report['result']=='PASS' else 1)
