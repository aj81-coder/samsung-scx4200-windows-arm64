# SPDX-License-Identifier: Apache-2.0
"""Device-free regression for durable asynchronous IPP acceptance (0.8).

Only the compile-time test bridge runs. Its hardcoded sender has no USB APIs.
The real renderer and independent pixel decoder verify accepted document content.
"""
from pathlib import Path
import gzip, hashlib, http.client, importlib.util, json, shutil, socket, struct, subprocess, sys, threading, time
ROOT=Path(__file__).resolve().parent.parent

def module(name,file):
    spec=importlib.util.spec_from_file_location(name,file)
    obj=importlib.util.module_from_spec(spec);spec.loader.exec_module(obj);return obj
ipp=module('ipp_client',ROOT/'native-ipp-capture/test-capture.py')
verify=module('independent_pixels',ROOT/'native-render-print/verify-render.py')
DEST=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else ROOT/'build/async/tests'
DEST.mkdir(parents=True,exist_ok=False)
BIN=ROOT/'build/async/x64'
TEST=ROOT/'build/async-tests/x64/SCX4200-Reliable-Bridge.exe'
TOOLS=ROOT/'build/async/test-tools'
HEADER=(ROOT/'native-reliable-bridge/test-header.bin').read_bytes()
W,H=2480,3507
results=[]

def require(ok,message):
    if not ok:raise ValueError(message)

def fixture(kind):
    rows=[]
    for y in range(H):
        row=bytearray([255])*W
        if kind==1 and 300<=y<1100:row[250:1100]=bytes([0])*850
        if kind==2 and 1700<=y<2700:row[1250:2250]=bytes([110])*1000
        rows.append(bytes(row))
    body=bytearray();y=0
    while y<H:
        end=y+1
        while end<min(y+256,H) and rows[end]==rows[y]:end+=1
        body.append(end-y-1);row=rows[y];i=0
        while i<len(row):
            j=i+1
            while j<min(i+128,len(row)) and row[j]==row[i]:j+=1
            body.extend((j-i-1,row[i]));i=j
        y=end
    return HEADER+body,b'P5\n2480 3507\n255\n'+b''.join(rows)
FIRST,PGM1=fixture(1);SECOND,PGM2=fixture(2);TWO=FIRST+SECOND[4:]

def until(predicate,message,seconds=20):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        value=predicate()
        if value:return value
        time.sleep(.05)
    raise ValueError(message)

class Session:
    def __init__(self,name,renderer=None,mock=False):
        self.folder=DEST/name;self.folder.mkdir();self.proc=None;self.mock=mock
        for name in ('cups.dll','SCX4200-Render.exe','SCX4200-Bridge-Sender.exe'):
            shutil.copy2(BIN/name,self.folder/name)
        shutil.copy2(BIN/'SCX4200-Reliable-Bridge.exe' if mock else TEST,self.folder/'SCX4200-Reliable-Bridge-Test.exe')
        shutil.copy2(TOOLS/'SCX4200-Test-Sender.exe',self.folder/'SCX4200-Test-Sender.exe')
        if renderer:
            shutil.copy2(self.folder/'SCX4200-Render.exe',self.folder/'real-renderer.exe')
            shutil.copy2(TOOLS/'renderer-stub.exe',self.folder/'SCX4200-Render.exe')
            (self.folder/'test-mode.txt').write_text(renderer)
        self.start();self.ep=ipp.Endpoint('http://127.0.0.1:8631/ipp/print')
    def start(self,listener=True):
        command=[str(self.folder/'SCX4200-Reliable-Bridge-Test.exe')]+(['--mock-transport'] if self.mock else [])
        self.proc=subprocess.Popen(command,cwd=self.folder,stdin=subprocess.PIPE,stdout=(self.folder/'stdout.log').open('ab'),stderr=(self.folder/'stderr.log').open('ab'),creationflags=subprocess.CREATE_NO_WINDOW)
        if not self.mock:self.proc.stdin.write(b'ARM\n');self.proc.stdin.flush()
        if listener:
            def ready():
                require(self.proc.poll() is None,'Server exited early')
                try:
                    with socket.create_connection(('127.0.0.1',8631),.1):return True
                except OSError:return False
            until(ready,'No test listener')
    def create(self):return self.ep.request(5,ipp.attribute(0x42,'job-name','Asynchronous device-free test'))
    def send(self,job,doc=TWO,compressed=False,encoded=None):
        extra=ipp.attribute(0x21,'job-id',job)+ipp.attribute(0x22,'last-document',b'\x01')+ipp.attribute(0x49,'document-format','image/pwg-raster')
        if compressed:extra+=ipp.attribute(0x44,'compression','gzip')
        start=time.monotonic()
        response=self.ep.request(6,extra,encoded if encoded is not None else gzip.compress(doc,mtime=0) if compressed else doc,chunked=compressed)
        return response,time.monotonic()-start
    def state(self,job):return self.ep.request(9,ipp.attribute(0x21,'job-id',job))['attributes'].get('job-state',[0])[0]
    def terminal(self,job):return until(lambda: (s if (s:=self.state(job))>=7 else None),'No terminal job',40)
    def calls(self):
        p=self.folder/'stub-calls.txt'
        return p.read_text().splitlines() if p.exists() else []
    def stop(self,failed=False):
        (self.folder/'test-stop.request').write_text('stop test server')
        code=self.proc.wait(75)
        require(code==(1 if failed else 0),'Incorrect shutdown status: '+str(code))
        require((self.folder/'SESSION-ACTIVE.lock').exists()==failed,'Incorrect lock retention')
    def close(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:self.proc.wait(5)
            except subprocess.TimeoutExpired:self.proc.kill();self.proc.wait(5)

def pixels(s,expected):
    run=next(s.folder.glob('bridge-*'));job=next(run.glob('job-*'))
    data=(job/'document.scxjob').read_bytes();require(data[:8]==b'SCXJOB06','Bundle magic')
    require(struct.unpack_from('>I',data,8)[0]==len(expected),'Bundle page count')
    checks=[];pos=12
    for i,pgm in enumerate(expected,1):
        n=struct.unpack_from('>I',data,pos)[0];digest=data[pos+4:pos+36];pos+=36
        qpdl=data[pos:pos+n];pos+=n
        require(hashlib.sha256(qpdl).digest()==digest,'Bundle page digest')
        pgmpath=job/f'page-{i:02d}.pgm';qpath=job/f'page-{i:02d}.qpdl'
        require(pgmpath.read_bytes()==pgm and qpath.read_bytes()==qpdl,'Capture/order changed')
        checks.append(verify.verify(pgmpath,qpath,job/f'page-{i:02d}-decoded.png'))
    require(pos==len(data),'Trailing bundle bytes')
    return checks

def waiting(s):until(lambda:(s.folder/'stub-waiting.txt').exists(),'Sender not waiting')
def jobid(response):
    require(response['status']<0x400,'Create-Job rejected')
    return response['attributes']['job-id'][0]

def test_wait_cancel():
    s=Session('send_response_before_waiting_sender_and_cancel')
    try:
        jid=jobid(s.create());response,elapsed=s.send(jid,compressed=True)
        require(response['status']<0x400,'Send-Document rejected')
        waiting(s);require(s.state(jid)==5,'Not processing while sender waits')
        require(not (s.folder/'stub-release.txt').exists(),'Sender released before response')
        require(s.calls()==['call'],'Sender call count before cancellation')
        # A second job may be refused immediately or aborted before any sender.
        duplicate=s.create()
        if duplicate['status']<0x400:
            other=jobid(duplicate);s.send(other,FIRST)
        cancel=s.ep.request(8,ipp.attribute(0x21,'job-id',jid))
        require(cancel['status']<0x400,'Cancel-Job rejected')
        state=s.terminal(jid);require(state==7,'Cancel did not become canceled')
        time.sleep(.5);require(s.calls()==['call'],'Cancellation replayed or admitted queued sender')
        s.stop(failed=True)
        (s.folder/'test-stop.request').unlink();s.start(listener=False)
        require(s.proc.wait(5)==1,'Stale lock allowed automatic restart')
        return dict(send_document_seconds=elapsed,state=state,sender_calls=1,stale_lock_refused=True)
    finally:s.close()

def test_repeat():
    s=Session('gzip_chunked_valid_two_pages_and_repeat')
    try:
        details=[]
        for doc in (TWO,SECOND):
            (s.folder/'stub-waiting.txt').unlink(missing_ok=True)
            (s.folder/'stub-release.txt').unlink(missing_ok=True)
            jid=jobid(s.create());response,elapsed=s.send(jid,doc,True)
            require(response['status']<0x400,'Send rejected')
            waiting(s);require(s.state(jid)==5,'Accepted document finished before sender release')
            (s.folder/'stub-release.txt').write_text('release')
            require(s.terminal(jid)==9,'Normal job failed')
            details.append(dict(job_id=jid,send_document_seconds=elapsed))
        require(s.calls()==['call','call'],'Repeated job call count')
        details[0]['pixels']=pixels(s,[PGM1,PGM2]);s.stop()
        return dict(jobs=details,sender_calls=2)
    finally:s.close()

def test_cancel_receive():
    s=Session('cancel_during_chunked_receive');wire=None
    try:
        jid=jobid(s.create());rid=9001
        header=struct.pack('>BBHI',2,0,6,rid)+b'\x01'
        for tag,name,value in [(0x47,'attributes-charset','utf-8'),(0x48,'attributes-natural-language','en'),(0x45,'printer-uri','ipp://127.0.0.1:8631/ipp/print'),(0x21,'job-id',jid),(0x22,'last-document',b'\x01'),(0x49,'document-format','image/pwg-raster')]:
            header+=ipp.attribute(tag,name,value)
        payload=header+b'\x03'+TWO
        wire=socket.create_connection(('127.0.0.1',8631),5);wire.settimeout(15)
        wire.sendall(b'POST /ipp/print HTTP/1.1\r\nHost: 127.0.0.1:8631\r\nContent-Type: application/ipp\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n')
        def chunk(data):wire.sendall(('%x\r\n'%len(data)).encode()+data+b'\r\n')
        cut=len(header)+600;chunk(payload[:cut]);time.sleep(.2)
        start=time.monotonic();cancel=s.ep.request(8,ipp.attribute(0x21,'job-id',jid));elapsed=time.monotonic()-start
        require(cancel['status']<0x400,'Receiving job cancellation refused')
        connection_closed=False
        try:
            chunk(payload[cut:]);wire.sendall(b'0\r\n\r\n')
            response=http.client.HTTPResponse(wire);response.begin();response.read()
        except (ConnectionResetError, BrokenPipeError):
            # The server may reject and close without draining a canceled body.
            connection_closed=True
        require(s.terminal(jid)==7,'Receiving cancellation did not terminate canceled')
        require(not s.calls(),'Receiving canceled document reached sender')
        return dict(cancel_response_seconds=elapsed,sender_calls=0,receive_connection_closed=connection_closed)
    finally:
        if wire:wire.close()
        s.close()

def production_smoke():
    details=[]
    for valid in (True,False):
        s=Session('production_mock_'+('valid' if valid else 'truncated'),mock=True)
        try:
            jid=jobid(s.create());response,elapsed=s.send(jid,TWO if valid else FIRST+SECOND[4:100],True)
            state=s.terminal(jid);require(state==9 if valid else state in (7,8),'Production mock state')
            calls=list(s.folder.glob('bridge-*/job-*/mock-transport.json'))
            require(len(calls)==(1 if valid else 0),'Production mock admission boundary')
            detail=dict(valid=valid,state=state,mock_calls=len(calls))
            if valid:detail['pixels']=pixels(s,[PGM1,PGM2])
            details.append(detail)
        finally:s.close()
    return details

def dense_raster():
    # Literal PackBits packets avoid a tiny white-page fixture hiding byte-callback cost.
    doc=bytearray(HEADER)
    for y in range(H):
        row=bytes([255])*48+bytes((x+y)%256 for x in range(W-48)) if y>=63 else bytes([255])*W
        doc.append(0)
        for i in range(0,W,128):
            packet=row[i:i+128];doc.append(257-len(packet) if len(packet)>1 else 0);doc.extend(packet)
    s=Session('dense_raster_bounded_callback',mock=True)
    try:
        jid=jobid(s.create());start=time.monotonic();response,elapsed=s.send(jid,bytes(doc))
        require(response['status']<0x400,'Dense input rejected');require(s.terminal(jid)==9,'Dense input failed')
        total=time.monotonic()-start;require(total<30,'Dense page processing exceeds 30 seconds')
        return dict(encoded_bytes=len(doc),send_document_seconds=elapsed,total_seconds=total)
    finally:s.close()

def uncertain_failure():
    s=Session('uncertain_partial_acknowledgment_preserved')
    try:
        (s.folder/'sender-test-mode.txt').write_text('uncertain')
        jid=jobid(s.create());s.send(jid);waiting(s)
        (s.folder/'stub-release.txt').write_text('release')
        require(s.terminal(jid)==8,'Uncertain sender did not abort')
        run=next(s.folder.glob('bridge-*'));job=next(run.glob('job-*'))
        sender=json.loads((job/'sender-report.json').read_text())
        reports=[json.loads(p.read_text()) for p in job.glob('*.json') if p.name!='sender-report.json']
        summary=next(r for r in reports if r.get('result')=='SEND_FAILED_OR_UNCERTAIN_NO_RETRY')
        require(summary['acknowledged_bytes_known'] and summary['acknowledged_bytes']==sender['transfer']['acknowledged_bytes']>0,'Partial acknowledgments lost')
        require(summary['delivery_uncertain'] and not summary['automatic_retry'],'Uncertain/retry summary incorrect')
        require(s.calls()==['call'],'Uncertain job replayed');s.stop(failed=True)
        return dict(acknowledged_bytes=summary['acknowledged_bytes'],delivery_uncertain=True)
    finally:s.close()

def reject_copies_and_format():
    details=[]
    for kind in ('copies','format'):
        s=Session('reject_'+kind)
        try:
            extra=ipp.attribute(0x49,'document-format','application/pdf' if kind=='format' else 'image/pwg-raster')
            if kind=='copies':extra+=b'\x02'+ipp.attribute(0x21,'copies',2)
            # No body is needed for MIME admission; sending a rejected body can
            # intentionally reset its connection before HTTP client reads reply.
            response=s.ep.request(2,extra,b'' if kind=='format' else FIRST)
            state=s.terminal(response['attributes']['job-id'][0]) if response['attributes'].get('job-id') else None
            require(response['status']>=0x400 or state in (7,8),'Unsupported request completed')
            require(not s.calls(),'Unsupported request reached sender')
            details.append(dict(kind=kind,status=response['status'],state=state))
        finally:s.close()
    return details

def invalid(name,doc,compressed=False,renderer=None,cancel_conversion=False,encoded=None):
    s=Session(name,renderer)
    try:
        jid=jobid(s.create());response,elapsed=s.send(jid,doc,compressed,encoded)
        if cancel_conversion:
            until(lambda:(s.folder/'second-renderer-started.txt').exists(),'Renderer delay not reached')
            require(s.ep.request(8,ipp.attribute(0x21,'job-id',jid))['status']<0x400,'Conversion cancellation rejected')
        state=s.terminal(jid)
        require(state in (7,8),'Invalid/canceled document completed')
        require(not s.calls(),'Invalid document invoked sender')
        return dict(state=state,send_status=response['status'],send_document_seconds=elapsed,sender_calls=0)
    finally:s.close()

try:
    for name,fn in [('async_response_and_cancel',test_wait_cancel),('repeated_jobs_and_pixels',test_repeat),('cancel_during_receive',test_cancel_receive),('production_binary_mock_smoke',production_smoke),('dense_raster_sanity',dense_raster),('uncertain_acknowledgment',uncertain_failure),('copies_and_format',reject_copies_and_format)]:
        detail=fn();results.append(dict(name=name,result='PASS',detail=detail));print(name+': PASS',flush=True)
    bad=bytearray(SECOND);struct.pack_into('>I',bad,4+372,999999)
    cases=[('truncated_second_raster',FIRST+SECOND[4:len(SECOND)//2],False,None,False),('truncated_next_header',FIRST+SECOND[4:100],False,None,False),('one_byte_next_header',FIRST+SECOND[4:5],False,None,False),('oversize_geometry',FIRST+bad[4:],False,None,False),('gzip_decoded_32MiB_bound',bytes(33*1024*1024),True,None,False),('second_renderer_failure',TWO,False,'fail',False),('cancel_during_conversion',TWO,False,'delay',True)]
    for name,doc,compressed,renderer,cancel in cases:
        detail=invalid(name,doc,compressed,renderer,cancel);results.append(dict(name=name,result='PASS',detail=detail));print(name+': PASS',flush=True)
    wire=gzip.compress(TWO,mtime=0);badcrc=bytearray(wire);badcrc[-8]^=1
    for name,encoded in [('gzip_missing_trailer',wire[:-8]),('gzip_bad_crc',bytes(badcrc))]:
        detail=invalid(name,TWO,True,encoded=encoded);results.append(dict(name=name,result='PASS',detail=detail));print(name+': PASS',flush=True)
except Exception as exc:
    results.append(dict(name='blocking_failure',result='FAIL',error=str(exc)))
report=dict(result='PASS' if all(r['result']=='PASS' for r in results) else 'FAIL',tests=results,usb_access=False)
report['test_bridge_sha256']=hashlib.sha256(TEST.read_bytes()).hexdigest()
report['test_sender_sha256']=hashlib.sha256((TOOLS/'SCX4200-Test-Sender.exe').read_bytes()).hexdigest()
report['test_source_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
report['binaries']={name:hashlib.sha256((BIN/name).read_bytes()).hexdigest() for name in ('SCX4200-Reliable-Bridge.exe','cups.dll','SCX4200-Render.exe','SCX4200-Bridge-Sender.exe')}
(DEST/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(result=report['result'],tests=len(results))))
sys.exit(0 if report['result']=='PASS' else 1)
