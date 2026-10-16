# SPDX-License-Identifier: Apache-2.0
"""Unchanged bridge, revised renderer, production explicit mock transport."""
from pathlib import Path
import hashlib,json,shutil,sys
source=Path(__file__).with_name('test-async.py')
ns={'__file__':str(source),'__name__':'focused_test_helpers'}
exec(compile(source.read_text(encoding='utf-8-sig').split('\ntry:\n    for name,fn')[0],str(source),'exec'),ns)
root=ns['ROOT'];fixture=Path(sys.argv[2]).resolve() if len(sys.argv)>2 else root/'build/margin-fix/tests-final-20261014'
pgm=(fixture/'edges-3507.pgm').read_bytes();rows=pgm.split(b'\n',3)[3]
body=bytearray();y=0
while y<3507:
    row=rows[y*2480:(y+1)*2480];end=y+1
    while end<min(y+256,3507) and rows[end*2480:(end+1)*2480]==row:end+=1
    body.append(end-y-1);x=0
    while x<2480:
        endx=x+1
        while endx<min(x+128,2480) and row[endx]==row[x]:endx+=1
        body.extend((endx-x-1,row[x]));x=endx
    y=end
s=None;report=dict(result='FAIL',usb_access=False)
try:
    s=ns['Session']('unchanged_bridge_fitted_page',mock=True)
    shutil.copy2(root/'build/margin-fix/x64/SCX4200-Render.exe',s.folder/'SCX4200-Render.exe')
    jid=ns['jobid'](s.create());response,elapsed=s.send(jid,ns['HEADER']+body,True)
    ns['require'](response['status']<0x400 and s.terminal(jid)==9,'Bridge rejected fitted document')
    run=next(s.folder.glob('bridge-*'));job=run/'job-000001'
    ns['require']((job/'page-01.qpdl').read_bytes()==(fixture/'edges-3507.qpdl').read_bytes(),'Bridge output differs from independently verified fixture')
    metadata=json.loads((job/'page-01.qpdl.json').read_text());ns['require'](metadata['fit_applied'],'Missing fitted-page report')
    result=json.loads((job/'bridge-result.json').read_text());ns['require'](result['result']=='MOCK_COMPLETED_NO_USB','Unexpected real transport')
    # Production --mock-transport does not implement the test-only stop file.
    # The owned process is closed in finally; this check covers rendering and
    # job completion, not the already-tested graceful console-stop behavior.
    report.update(result='PASS',send_document_seconds=elapsed,metadata=metadata,unchanged_bridge_sha256=hashlib.sha256((s.folder/'SCX4200-Reliable-Bridge-Test.exe').read_bytes()).hexdigest(),scope='Production explicit mock transport job completion; owned process terminated after verification')
except Exception as exc:report['error']=str(exc)
finally:
    if s:s.close()
(ns['DEST']/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report));sys.exit(0 if report['result']=='PASS' else 1)
