# SPDX-License-Identifier: Apache-2.0
"""Independent loopback IPP and multipage bundle tests. Transport is mock only.

The pixel verifier is test-only GPL code; it is never linked into the bridge.
"""
from pathlib import Path
import gzip, hashlib, importlib.util, json, shutil, socket, struct, subprocess, sys, threading, time
ROOT=Path(__file__).resolve().parent.parent
def module(name,file):
    spec=importlib.util.spec_from_file_location(name,file)
    obj=importlib.util.module_from_spec(spec);spec.loader.exec_module(obj);return obj
ipp=module('ipp_client',ROOT/'native-ipp-capture/test-capture.py')
verify=module('independent_pixels',ROOT/'native-render-print/verify-render.py')
DEST=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else ROOT/'build/reliable/tests'
DEST.mkdir(parents=True,exist_ok=False)
BIN=ROOT/'build/reliable/x64'
FILES=['SCX4200-Reliable-Bridge.exe','cups.dll','SCX4200-Render.exe','SCX4200-Bridge-Sender.exe']
HASHES={name:hashlib.sha256((BIN/name).read_bytes()).hexdigest() for name in FILES}
HEADER=(Path(__file__).parent/'test-header.bin').read_bytes()
if len(HEADER)!=1800:raise ValueError('Synthetic PWG fixture header must be 1800 bytes')
W,H=2480,3507
def require(ok,message):
    if not ok:raise ValueError(message)
def encode_row(row):
    encoded=bytearray();i=0
    while i<len(row):
        end=i+1
        while end<min(i+128,len(row)) and row[end]==row[i]:end+=1
        encoded.extend((end-i-1,row[i]));i=end
    return encoded
def fixture(kind):
    rows=[]
    for y in range(H):
        row=bytearray([255])*W
        if kind==1 and 300<=y<1100:row[250:1100]=bytes([0])*850
        if kind==2 and 1700<=y<2700:row[1250:2250]=bytes([110])*1000
        if kind==3 and y==0:row[0]=0
        rows.append(bytes(row))
    body=bytearray();y=0
    while y<H:
        end=y+1
        while end<min(y+256,H) and rows[end]==rows[y]:end+=1
        body.append(end-y-1);body.extend(encode_row(rows[y]));y=end
    return HEADER+body,b'P5\n2480 3507\n255\n'+b''.join(rows)
FIRST,PGM1=fixture(1);SECOND,PGM2=fixture(2);MARGIN,_=fixture(3)
TWO=FIRST+SECOND[4:]
def terminal(endpoint,response):
    ids=response['attributes'].get('job-id',[])
    if not ids:return None
    for _ in range(500):
        state=endpoint.request(9,ipp.attribute(0x21,'job-id',ids[0]))['attributes'].get('job-state',[0])[0]
        if state>=7:return state
        time.sleep(.1)
    raise ValueError('Job did not terminate')
def bundles(job,expected):
    data=(job/'document.scxjob').read_bytes();require(data[:8]==b'SCXJOB06','Bundle magic')
    count=struct.unpack_from('>I',data,8)[0];require(count==len(expected),'Bundle page count')
    pos=12;pages=[]
    for i,pgm in enumerate(expected,1):
        n=struct.unpack_from('>I',data,pos)[0];digest=data[pos+4:pos+36];pos+=36
        qpdl=data[pos:pos+n];pos+=n
        require(hashlib.sha256(qpdl).digest()==digest,'Bundle page digest')
        pgmpath=job/f'page-{i:02d}.pgm';qpdlpath=job/f'page-{i:02d}.qpdl'
        require(pgmpath.read_bytes()==pgm,'Captured source content or page order changed')
        require(qpdlpath.read_bytes()==qpdl,'Bundle payload differs from rendered file')
        pages.append(verify.verify(pgmpath,qpdlpath,job/f'page-{i:02d}-decoded.png'))
    require(pos==len(data),'Trailing bundle bytes')
    return dict(bundle_sha256=hashlib.sha256(data).hexdigest(),pages=pages)
results=[]

def handoff(name, mode='wait', cancel=False, restart=False):
    """Real parent child-process handoff; child compiled without any USB code."""
    folder=DEST/name;folder.mkdir()
    for filename in FILES:shutil.copy2(BIN/filename,folder/filename)
    test_binary=ROOT/'build/reliable-tests/x64/SCX4200-Reliable-Bridge.exe'
    shutil.copy2(test_binary,folder/'SCX4200-Reliable-Bridge-Test.exe')
    shutil.copy2(ROOT/'build/reliable/test-tools/SCX4200-Test-Sender.exe',folder/'SCX4200-Test-Sender.exe')
    (folder/'sender-test-mode.txt').write_text(mode)
    def start():
        return subprocess.Popen([str(folder/'SCX4200-Reliable-Bridge-Test.exe')],cwd=folder,stdin=subprocess.PIPE,stdout=(folder/'handoff-stdout.log').open('ab'),stderr=(folder/'handoff-stderr.log').open('ab'),creationflags=subprocess.CREATE_NO_WINDOW)
    proc=start()
    proc.stdin.write(b'ARM\n');proc.stdin.flush()
    try:
        for _ in range(100):
            require(proc.poll() is None,'Handoff parent exited early')
            try:
                with socket.create_connection(('127.0.0.1',8631),.1):break
            except OSError:time.sleep(.1)
        else:raise ValueError('No handoff listener')
        ep=ipp.Endpoint('http://127.0.0.1:8631/ipp/print')
        job=ep.request(5,ipp.attribute(0x42,'job-name','Paper recovery simulation'));jobid=job['attributes']['job-id'][0]
        errors=[]
        def send():
            try:
                other=ipp.Endpoint('http://127.0.0.1:8631/ipp/print')
                other.request(6,ipp.attribute(0x21,'job-id',jobid)+ipp.attribute(0x22,'last-document',b'\x01')+ipp.attribute(0x49,'document-format','image/pwg-raster'),TWO)
            except Exception as exc:errors.append(str(exc))
        thread=threading.Thread(target=send);thread.start()
        for _ in range(400):
            if (folder/'stub-waiting.txt').exists():break
            time.sleep(.05)
        else:raise ValueError('Sender did not reach paper wait')
        time.sleep(.4)
        waiting=ep.request(9,ipp.attribute(0x21,'job-id',jobid))
        require(waiting['attributes'].get('job-state')==[5],'Job completed before sender release')
        text=(folder/'handoff-stdout.log').read_text(errors='replace')+(folder/'handoff-stderr.log').read_text(errors='replace')
        require('Load paper in the printer; this job will continue when ready.' in text,'Paper-wait instruction missing')
        if cancel:require(ep.request(8,ipp.attribute(0x21,'job-id',jobid))['status']<0x400,'Paper wait cancellation refused')
        else:(folder/'stub-release.txt').write_text('release device-free child')
        thread.join(15);require(not thread.is_alive() and not errors,'Handoff send request failed')
        state=terminal(ep,job);success=mode=='wait' and not cancel
        require(state==9 if success else state in (7,8),'Unexpected handoff terminal state')
        require((folder/'stub-calls.txt').read_text().splitlines()==['call'],'Unexpected child call count')
        run=next(folder.glob('bridge-*'));report=json.loads(next(run.glob('job-*/sender-report.json')).read_text())
        detail=dict(state=state,sender_report=report,test_binary_sha256=hashlib.sha256(test_binary.read_bytes()).hexdigest())
        if success:detail['pixels']=bundles(next(run.glob('job-*')),[PGM1,PGM2])
        else:
            denied=ep.request(5,ipp.attribute(0x42,'job-name','Must remain blocked'))
            if denied['status']<0x400:
                nextid=denied['attributes']['job-id'][0]
                ep.request(6,ipp.attribute(0x21,'job-id',nextid)+ipp.attribute(0x22,'last-document',b'\x01')+ipp.attribute(0x49,'document-format','image/pwg-raster'),FIRST)
                require(terminal(ep,denied) in (7,8),'Failure permitted later job')
            require((folder/'stub-calls.txt').read_text().splitlines()==['call'],'Failure replayed child')
            (folder/'test-stop.request').write_text('stop blocked session')
            require(proc.wait(75)==1,'Blocked session incorrectly clean')
            require((folder/'SESSION-ACTIVE.lock').exists(),'Failure removed durable lock')
            (folder/'test-stop.request').unlink()
            proc=start();proc.stdin.write(b'ARM\n');proc.stdin.flush()
            require(proc.wait(5)==1,'Failed session silently restarted')
            detail['failed_restart_blocked']=True
        if restart:
            (folder/'test-stop.request').write_text('clean stop')
            require(proc.wait(75)==0,'Clean shutdown failed')
            require(not (folder/'SESSION-ACTIVE.lock').exists(),'Clean shutdown retained lock')
            (folder/'test-stop.request').unlink()
            proc=start();proc.stdin.write(b'ARM\n');proc.stdin.flush()
            time.sleep(1);require(proc.poll() is None,'Clean restart failed')
            (folder/'test-stop.request').write_text('stop second session');require(proc.wait(75)==0,'Second clean shutdown failed')
            detail['clean_restart']=True
        results.append(dict(name=name,result='PASS',detail=detail));print(name+': PASS',flush=True)
    finally:
        if proc.poll() is None:proc.terminate();proc.wait(5)
def scenario(name,content=TWO,success=False,repeated=False,gzip_wire=False,stub=None,mock_fail=False,cancel=False,copies=False,session_limit=False):
    folder=DEST/name;folder.mkdir()
    for filename in FILES:
        shutil.copy2(BIN/filename,folder/filename)
        require(hashlib.sha256((folder/filename).read_bytes()).hexdigest()==HASHES[filename],'Binary changed during suite: '+filename)
    if stub:
        shutil.copy2(folder/'SCX4200-Render.exe',folder/'real-renderer.exe')
        shutil.copy2(ROOT/'build/reliable/test-tools/renderer-stub.exe',folder/'SCX4200-Render.exe')
        (folder/'test-mode.txt').write_text(stub)
    with (folder/'stdout.log').open('wb') as out,(folder/'stderr.log').open('wb') as err:
        proc=subprocess.Popen([str(folder/'SCX4200-Reliable-Bridge.exe'),'--mock-transport=fail' if mock_fail else '--mock-transport'],cwd=folder,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            for _ in range(100):
                require(proc.poll() is None,'Server exited: '+(folder/'stderr.log').read_text(errors='replace'))
                try:
                    with socket.create_connection(('127.0.0.1',8631),.1):break
                except OSError:time.sleep(.1)
            else:raise ValueError('No loopback listener')
            net=subprocess.check_output(['netstat','-ano','-p','TCP'],text=True)
            listeners=[line.split() for line in net.splitlines() if 'LISTENING' in line and line.split()[-1]==str(proc.pid)]
            require(len(listeners)==1 and listeners[0][1]=='127.0.0.1:8631','Unexpected network listener')
            ep=ipp.Endpoint('http://127.0.0.1:8631/ipp/print')
            require(ep.request(11,ipp.attribute(0x44,'requested-attributes','all'))['status']<0x400,'Discovery')
            def send(doc,compressed=False):
                response=ep.request(5,ipp.attribute(0x42,'job-name','Multipage integration'))
                if response['status']>=0x400:return response
                extra=ipp.attribute(0x21,'job-id',response['attributes']['job-id'][0])+ipp.attribute(0x22,'last-document',b'\x01')+ipp.attribute(0x49,'document-format','image/pwg-raster')
                if compressed:extra+=ipp.attribute(0x44,'compression','gzip')
                submitted=ep.request(6,extra,gzip.compress(doc,mtime=0) if compressed else doc,chunked=compressed)
                require(submitted['status']<0x400,'Send-Document rejected')
                return response
            if cancel:
                response=ep.request(5,ipp.attribute(0x42,'job-name','Cancel later page'))
                jobid=response['attributes']['job-id'][0];errors=[]
                def worker():
                    try:
                        other=ipp.Endpoint('http://127.0.0.1:8631/ipp/print')
                        other.request(6,ipp.attribute(0x21,'job-id',jobid)+ipp.attribute(0x22,'last-document',b'\x01')+ipp.attribute(0x49,'document-format','image/pwg-raster'),content)
                    except Exception as exc:errors.append(str(exc))
                thread=threading.Thread(target=worker);thread.start()
                for _ in range(300):
                    if (folder/'second-renderer-started.txt').exists():break
                    time.sleep(.05)
                else:raise ValueError('Second-page renderer not reached')
                require(ep.request(8,ipp.attribute(0x21,'job-id',jobid))['status']<0x400,'Cancel rejected')
                thread.join(15);require(not thread.is_alive() and not errors,'Cancel send failed')
            elif copies:
                response=ep.request(2,ipp.attribute(0x49,'document-format','image/pwg-raster')+b'\x02'+ipp.attribute(0x21,'copies',2),content)
            else:response=send(content,gzip_wire)
            state=terminal(ep,response);runs=list(folder.glob('bridge-*'));require(len(runs)==1,'Fresh run missing')
            run=runs[0];calls=list(run.glob('job-*/mock-transport.json'))
            detail=dict(state=state,status=response['status'])
            if success:
                require(state==9 and len(calls)==1,'Expected completed job with one transport call')
                job=sorted(run.glob('job-*'))[0]
                expected=[PGM1,PGM2] if content==TWO else [PGM1]*10
                detail['pixel_validation']=bundles(job,expected)
                if repeated:
                    second=send(SECOND);require(terminal(ep,second)==9,'Repeated job failed')
                    require(len(list(run.glob('job-*/mock-transport.json')))==2,'Repeated job missing transport')
                    detail['second_job_pixels']=bundles(sorted(run.glob('job-*'))[1],[PGM2])
                if session_limit:
                    require(terminal(ep,send(content))==9,'Second ten-page job failed')
                    require(len(list(run.glob('job-*/mock-transport.json')))==2,'Twenty page session call count')
                    denied=send(FIRST);require(terminal(ep,denied) in (7,8) or denied['status']>=0x400,'Session limit accepted')
                    require(len(list(run.glob('job-*/mock-transport.json')))==2,'Session limit sent data')
            else:
                require(state in (7,8) or response['status']>=0x400,'Invalid job completed')
                require(len(calls)==(1 if mock_fail else 0),'Unexpected transport call for invalid job')
                if mock_fail:
                    denied=send(FIRST);require(terminal(ep,denied) in (7,8) or denied['status']>=0x400,'Transport failure did not disarm')
                    require(len(list(run.glob('job-*/mock-transport.json')))==1,'Retry after uncertain transport')
            detail['transport_calls']=len(list(run.glob('job-*/mock-transport.json')))
            results.append(dict(name=name,result='PASS',detail=detail));print(name+': PASS',flush=True)
        finally:
            proc.terminate()
            try:proc.wait(5)
            except subprocess.TimeoutExpired:proc.kill();proc.wait(5)
try:
    if '--handoff-only' not in sys.argv:
        scenario('gzip_distinct_two_pages_and_repeated_job',success=True,repeated=True,gzip_wire=True)
        scenario('truncated_second_page_no_transport',content=FIRST+SECOND[4:len(SECOND)//2])
        scenario('truncated_second_header_no_transport',content=FIRST+SECOND[4:100])
        bad=bytearray(SECOND);struct.pack_into('>I',bad,4+372,2479)
        scenario('wrong_second_geometry_no_transport',content=FIRST+bad[4:])
        scenario('second_page_margin_no_transport',content=FIRST+MARGIN[4:])
        scenario('second_renderer_failure_no_transport',stub='fail')
        scenario('second_invalid_qpdl_no_transport',stub='invalid')
        scenario('cancel_second_renderer_no_transport',stub='delay',cancel=True)
        scenario('transport_failure_disarms_next_job',mock_fail=True)
        scenario('eleven_pages_no_transport',content=FIRST+FIRST[4:]*10)
        scenario('twenty_page_session_limit',content=FIRST+FIRST[4:]*9,success=True,session_limit=True)
        scenario('copies_two_no_transport',copies=True)
    handoff('actual_handoff_paper_wait_resume_clean_restart',restart=True)
    handoff('cancel_paper_wait_blocks_next_job',cancel=True)
    handoff('missing_device_blocks_next_job',mode='missing')
    handoff('partial_uncertain_blocks_next_job',mode='uncertain')
except Exception as exc:
    results.append(dict(name='blocking_failure',result='FAIL',error=str(exc)))
report=dict(result='PASS' if all(r['result']=='PASS' for r in results) else 'FAIL',tests=results,usb_access=False)
report['test_sources_sha256']={name:hashlib.sha256((Path(__file__).parent/name).read_bytes()).hexdigest() for name in ['test-bridge.py','test-sender-stub.c','bridge.c','sender.c']}
report['sender_stub_sha256']=hashlib.sha256((ROOT/'build/reliable/test-tools/SCX4200-Test-Sender.exe').read_bytes()).hexdigest()
for filename in FILES:
    report[filename+'_sha256']=HASHES[filename]
(DEST/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(result=report['result'],tests=len(results))))
sys.exit(0 if report['result']=='PASS' else 1)
