# SPDX-License-Identifier: Apache-2.0
"""Focused follow-up: a canceled/uncertain session must reject later work.
Uses definitions from test-async.py without running its full suite. No USB APIs.
"""
from pathlib import Path
import hashlib,json,sys,time
source=Path(__file__).with_name('test-async.py')
namespace={'__file__':str(source),'__name__':'focused_test_helpers'}
exec(compile(source.read_text(encoding='utf-8-sig').split('\ntry:\n    for name,fn')[0],str(source),'exec'),namespace)
Session=namespace['Session'];jobid=namespace['jobid'];waiting=namespace['waiting'];require=namespace['require'];FIRST=namespace['FIRST'];DEST=namespace['DEST']
results=[]
try:
    for mode in ('cancel','uncertain'):
        s=Session('after_'+mode+'_new_work_blocked')
        try:
            if mode=='uncertain':(s.folder/'sender-test-mode.txt').write_text(mode)
            jid=jobid(s.create());s.send(jid);waiting(s)
            if mode=='cancel':require(s.ep.request(8,namespace['ipp'].attribute(0x21,'job-id',jid))['status']<0x400,'Cancel refused')
            else:(s.folder/'stub-release.txt').write_text('release failed child')
            require(s.terminal(jid)==(7 if mode=='cancel' else 8),'Unexpected first terminal state')
            response=s.create();status=response['status'];secondstate=None
            if status<0x400:
                second=jobid(response);s.send(second,FIRST);secondstate=s.terminal(second)
                require(secondstate in (7,8),'New job completed after failure')
            time.sleep(.25);require(s.calls()==['call'],'Post-failure job started second sender')
            results.append(dict(mode=mode,result='PASS',next_create_status=status,next_state=secondstate,sender_calls=1))
        finally:s.close()
except Exception as exc:results.append(dict(result='FAIL',error=str(exc)))
report=dict(result='PASS' if all(x['result']=='PASS' for x in results) else 'FAIL',tests=results,usb_access=False,test_bridge_sha256=hashlib.sha256(namespace['TEST'].read_bytes()).hexdigest(),test_source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
(DEST/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report));sys.exit(0 if report['result']=='PASS' else 1)
