# SPDX-License-Identifier: Apache-2.0
"""Device-free tests of document admission and cancellation; never prints."""
import ctypes, hashlib, json, pathlib, struct, subprocess, tempfile
from ctypes import wintypes
root = pathlib.Path(__file__).resolve().parent.parent
outdir = root / 'build/reliable-bridge'
exe = outdir / 'scx4200-reliable-sender-x64.exe'
page = (root / 'reference-job/test-page.qpdl').read_bytes()
k = ctypes.WinDLL('kernel32', use_last_error=True)
k.CreateEventW.argtypes=[wintypes.LPVOID,wintypes.BOOL,wintypes.BOOL,wintypes.LPCWSTR]
k.CreateEventW.restype=wintypes.HANDLE
for name in ('CloseHandle','SetEvent','ResetEvent'):
    getattr(k,name).argtypes=[wintypes.HANDLE]
k.SetHandleInformation.argtypes=[wintypes.HANDLE,wintypes.DWORD,wintypes.DWORD]
k.WaitForSingleObject.argtypes=[wintypes.HANDLE,wintypes.DWORD]
k.WaitForSingleObject.restype=wintypes.DWORD
checks=[]
def record(name, condition):
    if not condition: raise RuntimeError(name)
    checks.append(name)
def bundle(pages):
    return b'SCXJOB06'+struct.pack('>I',len(pages))+b''.join(struct.pack('>I',len(p))+hashlib.sha256(p).digest()+p for p in pages)
record('self-test', subprocess.run([str(exe),'--self-test'],capture_output=True,timeout=30).returncode==0)
with tempfile.TemporaryDirectory(dir=outdir,prefix='sender-test-') as tmp:
    tmp=pathlib.Path(tmp)
    permit=k.CreateEventW(None,True,True,None)
    cancel=k.CreateEventW(None,True,True,None)
    if not permit or not cancel: raise ctypes.WinError(ctypes.get_last_error())
    try:
        invocation=0
        latest_progress=None
        def invoke(data,args=(),override_sha=None):
            global invocation,latest_progress
            invocation+=1
            args=list(args)
            if '--validate-only' not in args and '--progress' not in args:
                latest_progress=tmp/f'progress-{invocation}.json'
                args+=['--progress',str(latest_progress)]
            job=tmp/'document.scxjob';job.write_bytes(data)
            return subprocess.run([str(exe),'--jobbundle',str(job),'--sha256',override_sha or hashlib.sha256(data).hexdigest(),*args],capture_output=True,text=True,close_fds=False,timeout=30)
        for count in (1,2,10):
            r=invoke(bundle([page]*count),['--validate-only'])
            record(f'valid-{count}-page-document',r.returncode==0 and f'{count} pages' in r.stdout and f'{len(page)*count} USB bytes' in r.stdout)
        report=tmp/'report.json'
        valid=bundle([page,page])
        args=['--report',str(report),'--permit-handle',str(permit),'--cancel-handle',str(cancel)]
        record('missing-permit-rejected',invoke(valid,['--report',str(report)]).returncode==64 and not report.exists())
        record('noninherited-events-rejected',invoke(valid,args).returncode==64 and not report.exists())
        if not k.SetHandleInformation(permit,1,1) or not k.SetHandleInformation(cancel,1,1):raise ctypes.WinError(ctypes.get_last_error())
        invalid={
            'magic':b'X'+valid[1:],
            'zero-pages':bundle([]),
            'eleven-pages':bundle([page]*11),
            'truncated-first-descriptor':valid[:25],
            'truncated-last-page':valid[:-1],
            'trailing-data':valid+b'X',
            'zero-page-length':valid[:12]+bytes(4)+valid[16:],
            'oversize-page-length':valid[:12]+struct.pack('>I',4194305)+valid[16:],
            'first-page-hash':valid[:16]+bytes(32)+valid[48:],
            'second-page-hash':valid[:48+len(page)+4]+bytes(32)+valid[48+len(page)+36:],
            'invalid-second-page-valid-hashes':bundle([page,b'X'+page[1:]]),
            'missing-second-page':valid[:48+len(page)],
            'extra-second-page':bundle([page])+(struct.pack('>I',len(page))+hashlib.sha256(page).digest()+page),
            'max-page-length-no-payload':b'SCXJOB06'+struct.pack('>II',1,4194304)+bytes(32),
            'bundle-memory-limit':b'SCXJOB06'+bytes(40*1024*1024+4096-7),
        }
        for name,data in invalid.items():
            k.SetEvent(permit)
            r=invoke(data,args)
            record(name+'-rejected-before-permit-and-device',r.returncode==3 and 'No device accessed' in r.stderr and not report.exists() and k.WaitForSingleObject(permit,0)==0)
        record('overall-hash-rejected',invoke(valid,args,'0'*64).returncode==3 and not report.exists() and k.WaitForSingleObject(permit,0)==0)
        r=invoke(valid,args)
        data=json.loads(report.read_text())
        record('cancelled-before-device',r.returncode==4 and data['result']=='CANCELLED_NO_DATA_SENT' and data['matching_devices']==0 and not data['transfer']['attempted'])
        record('document-report-fields',data['document_pages']==2 and data['bundle_bytes']==len(valid) and data['job_bytes']==len(page)*2 and data['job_sha256']==hashlib.sha256(valid).hexdigest() and data['transfer']['pages_data_completed']==0)
        progress=json.loads(latest_progress.read_text())
        record('durable-progress-bound-to-document',progress['job_sha256']==data['job_sha256'] and progress['stage']=='FAILED' and progress['acknowledged_bytes']==0 and progress['pages_data_completed']==0 and progress['document_pages']==2)
        record('permit-consumed',k.WaitForSingleObject(permit,0)==258)
        record('consumed-permit-rejected',invoke(valid,args).returncode==64)
        k.SetEvent(permit);before=report.read_bytes()
        record('existing-report-preserved',invoke(valid,args).returncode==1 and report.read_bytes()==before)
        k.SetEvent(permit)
        occupied=tmp/'occupied-progress.json';occupied.write_bytes(b'preserve existing progress')
        no_report=tmp/'existing-progress-must-not-create-report.json'
        occupied_args=['--report',str(no_report),'--permit-handle',str(permit),'--cancel-handle',str(cancel),'--progress',str(occupied)]
        record('existing-progress-preserved-before-device',invoke(valid,occupied_args).returncode==1 and occupied.read_bytes()==b'preserve existing progress' and not no_report.exists())
    finally:
        k.CloseHandle(permit);k.CloseHandle(cancel)
result={'result':'PASS','checks':checks,'x64_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'arm64_sha256':hashlib.sha256((outdir/'scx4200-reliable-sender-arm64.exe').read_bytes()).hexdigest(),'physical_usb_writes':False}
(outdir/'sender-validation.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
