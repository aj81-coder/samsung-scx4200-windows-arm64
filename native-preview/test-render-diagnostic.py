# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import datetime,hashlib,json,shutil,subprocess
root=Path(__file__).resolve().parent.parent
out=root/'build/preview'/('render-diagnostic-tests-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
out.mkdir(parents=True)
shutil.copy2(root/'native-preview/diagnose-rendering.ps1',out)
shutil.copy2(root/'build/async/x64/SCX4200-Render.exe',out)
originals={}
for i,position in [(1,0),(2,300*2480+300)]:
    job=out/f'bridge-20261014-00000{i}'/'job-000001';job.mkdir(parents=True)
    pixels=bytearray(b'\xff')*(2480*3507);pixels[position]=0
    pgm=job/'page-01.pgm';pgm.write_bytes(b'P5\n2480 3507\n255\n'+pixels)
    (job/'bridge-result.json').write_text('{"result":"RENDER_FAILED_NO_USB"}')
    originals[str(pgm)]=hashlib.sha256(pgm.read_bytes()).hexdigest()
lock=out/'SESSION-ACTIVE.lock';lock.write_text('Keep exact original lock')
proc=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(out/'diagnose-rendering.ps1')],capture_output=True,text=True,timeout=150)
(out/'test-output.txt').write_text(proc.stdout+proc.stderr)
assert proc.returncode==1,proc.stderr
report=json.loads(next(out.glob('control-render-diagnostic-*.json')).read_text(encoding='utf-8-sig'))
assert len(report['pages'])==2
assert report['pages'][0]['exit_code']==5 and 'hardware top/left margins' in report['pages'][0]['renderer_message']
assert report['pages'][1]['exit_code']==0 and report['pages'][1]['output_created']
for path,digest in originals.items():assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==digest
assert lock.read_text()=='Keep exact original lock'
assert not any('pixel' in k for page in report['pages'] for k in page)
validation=dict(result='PASS',cases=['margin-refusal-exit-and-message','successful-conversion','original-pages-and-lock-unchanged'],
                helper_sha256=hashlib.sha256((out/'diagnose-rendering.ps1').read_bytes()).hexdigest(),usb_access=False)
(out/'results.json').write_text(json.dumps(validation,indent=2)+'\n')
print(str(out));print(json.dumps(validation))
