# SPDX-License-Identifier: Apache-2.0
"""Genuine native sender launch via the bridge's handle-list/job-object pattern.
Cancellation is signaled before creation. No device enumeration or writes.
"""
import hashlib,json,pathlib,struct,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parent.parent
out=root/'build/reliable-bridge'
page=(root/'reference-job/test-page.qpdl').read_bytes()
bundle=b'SCXJOB06'+struct.pack('>I',2)+(struct.pack('>I',len(page))+hashlib.sha256(page).digest()+page)*2
sha=hashlib.sha256(bundle).hexdigest()
with tempfile.TemporaryDirectory(dir=out,prefix='handoff-') as folder:
    folder=pathlib.Path(folder);job=folder/'document.scxjob';report=folder/'sender-report.json';job.write_bytes(bundle)
    child=out/'scx4200-reliable-sender-x64.exe'
    result=subprocess.run([str(out/'test-sender-handoff.exe'),str(child.resolve()),str(job.resolve()),sha,str(report.resolve()),str((folder/"progress.json").resolve())],capture_output=True,text=True,timeout=40)
    if result.returncode:raise RuntimeError(result.stdout+result.stderr)
    launch=json.loads(result.stdout);data=json.loads(report.read_text())
    expected={'result':'CANCELLED_NO_DATA_SENT','job_sha256':sha,'job_bytes':len(page)*2,'bundle_bytes':len(bundle),'document_pages':2,'job_hash_verified':True,'bridge_permit_consumed':True,'matching_devices':0,'exclusive_read_write_open':False}
    for key,value in expected.items():
        if data.get(key)!=value:raise RuntimeError(f'{key}: {data.get(key)} != {value}')
    if data['transfer']['attempted'] or data['transfer']['acknowledged_bytes'] or data['transfer']['pages_data_completed']:raise RuntimeError('Unexpected transfer')
    evidence={'result':'PASS','launch':launch,'sender_report':data,'x64_sha256':hashlib.sha256(child.read_bytes()).hexdigest(),'physical_usb_writes':False,'checks':['two-pages-fully-validated','explicit-inherited-event-handles','suspended-child-owned-by-job','one-use-permit-consumed','prelaunch-cancel-before-enumeration','bundle-and-USB-counts-matched']}
    (out/'sender-handoff-validation.json').write_text(json.dumps(evidence,indent=2))
    print(json.dumps(evidence,indent=2))
