# SPDX-License-Identifier: Apache-2.0
"""Independent fitted-page reference and decoding checks. No USB access."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,subprocess,sys
import numpy as np
from PIL import Image
root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser()
parser.add_argument('output_directory')
parser.add_argument('--legacy-renderer',type=Path,default=root/'build/async/x64/SCX4200-Render.exe')
parser.add_argument('--approved-sample-dir',type=Path,default=root/'evidence/private/usb-recovery-0.8.4-target/extracted/bridge-20261014-095758-568-17996/job-000001')
args=parser.parse_args()
out=Path(args.output_directory).resolve();out.mkdir(parents=True,exist_ok=False)
renderer=root/'build/margin-fix/x64/SCX4200-Render.exe'
legacy=args.legacy_renderer
spec=importlib.util.spec_from_file_location('verify',root/'native-render-print/verify-render.py')
verify=importlib.util.module_from_spec(spec);spec.loader.exec_module(verify)
results=[]
def reference(pixels):
    # Separable exact rational area integration, retaining precision between
    # axes. The native implementation integrates each 2D destination cell.
    h,w=pixels.shape;dw=w-96;dh=h*dw//w
    if dh>h-126:dh=h-126;dw=w*dh//h
    ox=(w-dw)//2;oy=(h-dh)//2
    source=pixels.astype(np.int64);horizontal=np.zeros((h,dw),dtype=np.int64)
    for x in range(dw):
        a,b=x*w,(x+1)*w
        for sx in range(a//dw,(b+dw-1)//dw):
            horizontal[:,x]+=source[:,sx]*(min(b,(sx+1)*dw)-max(a,sx*dw))
    fitted=np.full((h,w),255,dtype=np.uint8)
    for y in range(dh):
        a,b=y*h,(y+1)*h;row=np.zeros(dw,dtype=np.int64)
        for sy in range(a//dh,(b+dh-1)//dh):row+=horizontal[sy]*(min(b,(sy+1)*dh)-max(a,sy*dh))
        fitted[y+oy,ox:ox+dw]=(row+w*h//2)//(w*h)
    return fitted,dict(fitted_width=dw,fitted_height=dh,offset_x=ox,offset_y=oy)
def pgm(path,pixels):
    path.write_bytes(f'P5\n2480 {pixels.shape[0]}\n255\n'.encode()+pixels.tobytes())
def run(src,dst,*extra):return subprocess.run([str(renderer),str(src),str(dst),*extra],capture_output=True,text=True,timeout=60)
for h in (3507,3509):
    p=np.full((h,2480),255,dtype=np.uint8)
    p[:12,:]=0;p[-12:,:]=0;p[:,:12]=0;p[:,-12:]=0
    p[80:180,0:2048]=np.tile(np.arange(256,dtype=np.uint8),8)
    p[500:1600,700]=0;p[500,700:1700]=0
    src=out/f'edges-{h}.pgm';dst=out/f'edges-{h}.qpdl';pgm(src,p)
    rendered=run(src,dst);assert rendered.returncode==0,rendered.stderr
    expected,geometry=reference(p);expected_path=out/f'expected-{h}.pgm';pgm(expected_path,expected)
    checked=verify.verify(expected_path,dst,out/f'edges-{h}.png')
    metadata=json.loads(Path(str(dst)+'.json').read_text())
    assert metadata['fit_applied'] and all(metadata[k]==v for k,v in geometry.items())
    assert expected[:63,:].min()==255 and expected[:,:48].min()==255
    assert expected[-63:,:].min()==255 and expected[:,-48:].min()==255
    # All four thick border landmarks still contain ink after resampling.
    ox,oy=geometry['offset_x'],geometry['offset_y'];dw,dh=geometry['fitted_width'],geometry['fitted_height']
    for edge in (expected[oy:oy+10,ox:ox+dw],expected[oy+dh-10:oy+dh,ox:ox+dw],expected[oy:oy+dh,ox:ox+10],expected[oy:oy+dh,ox+dw-10:ox+dw]):assert edge.min()==0
    strict=run(src,out/f'strict-{h}.qpdl','--strict-margins');assert strict.returncode==5
    results.append(dict(name=f'fitted-edges-{h}',result='PASS',metadata=metadata,independent_pixels=checked))
    safe=np.full((h,2480),255,dtype=np.uint8);safe[300:1100,300:1100]=0
    pgm(out/f'safe-{h}.pgm',safe)
    new=out/f'safe-{h}.qpdl';old=out/f'legacy-{h}.qpdl'
    assert run(out/f'safe-{h}.pgm',new).returncode==0
    if legacy.is_file():
        assert subprocess.run([str(legacy),str(out/f'safe-{h}.pgm'),str(old)],capture_output=True,timeout=60).returncode==0
        assert new.read_bytes()==old.read_bytes()
    assert not json.loads(Path(str(new)+'.json').read_text())['fit_applied']
    results.append(dict(name=f'already-safe-unchanged-{h}',result='PASS' if legacy.is_file() else 'SKIP',reason=None if legacy.is_file() else 'Optional original renderer is not provided; safe-page fit flag still checked'))
sample=args.approved_sample_dir
for n in (1,2):
    src=sample/f'page-{n:02d}.pgm';dst=out/f'approved-{n}.qpdl'
    if not src.is_file():
        results.append(dict(name=f'physical-sample-{n}-unchanged',result='SKIP',reason='Optional private target fixture is intentionally excluded from public source'))
        continue
    assert run(src,dst).returncode==0
    assert dst.read_bytes()==(sample/f'page-{n:02d}.qpdl').read_bytes()
    results.append(dict(name=f'physical-sample-{n}-unchanged',result='PASS'))
existing=out/'preserved.qpdl';existing.write_bytes(b'Preserve original output')
assert run(out/'edges-3507.pgm',existing).returncode==8 and existing.read_bytes()==b'Preserve original output'
conflict=out/'metadata-conflict.qpdl';Path(str(conflict)+'.json').write_bytes(b'Preserve original metadata')
assert run(out/'edges-3507.pgm',conflict).returncode==8 and not conflict.exists()
assert Path(str(conflict)+'.json').read_bytes()==b'Preserve original metadata'
results.append(dict(name='exclusive-output-and-metadata-preserved',result='PASS'))
bad=out/'truncated.pgm';bad.write_bytes((out/'edges-3507.pgm').read_bytes()[:-1])
assert run(bad,out/'truncated.qpdl').returncode==4 and not (out/'truncated.qpdl').exists()
results.append(dict(name='truncated-input-refused',result='PASS'))
valid=(out/'safe-3507.pgm').read_bytes()
for name,payload in [('magic',valid.replace(b'P5',b'P2',1)),('width',valid.replace(b'2480',b'2479',1)),
                     ('height',valid.replace(b'3507',b'3508',1)),('maxval',valid.replace(b'255',b'256',1)),
                     ('trailing',valid+b'x'),('long-token',b'P5\n'+b'2'*64+b' 3507\n255\n'),('comment',b'P5\n#unterminated')]:
    src=out/f'bad-{name}.pgm';dst=out/f'bad-{name}.qpdl';src.write_bytes(payload)
    assert run(src,dst).returncode!=0 and not dst.exists(),name
results.append(dict(name='malformed-pgm-refusals',result='PASS',cases=7))
validator=root/'build/render-print/scx4200-render-print-x64.exe'
validated=[]
for dst in sorted(out.glob('*.qpdl')):
    if dst.name in ('preserved.qpdl',) or dst.name.startswith('legacy-'):continue
    digest=hashlib.sha256(dst.read_bytes()).hexdigest()
    proc=subprocess.run([str(validator),'--job',str(dst),'--sha256',digest,'--validate-only','--no-pause'],capture_output=True,text=True,timeout=60)
    assert proc.returncode==0,(dst.name,proc.stdout,proc.stderr)
    validated.append(dst.name)
results.append(dict(name='native-offline-sender-validation',result='PASS',files=validated))
report=dict(result='PASS',tests=results,renderer_sha256=hashlib.sha256(renderer.read_bytes()).hexdigest(),test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),usb_access=False)
(out/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(result='PASS',tests=len(results),renderer_sha256=report['renderer_sha256'])))
