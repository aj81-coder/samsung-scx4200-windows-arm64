# SPDX-License-Identifier: Apache-2.0
"""Device-free executable validation, including correctly checksummed bad packets."""
from pathlib import Path
import hashlib, json, struct, subprocess
ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT/'build/render-print/scx4200-render-print-x64.exe'
OUT = ROOT/'build/render-print/sender-validation'
OUT.mkdir(exist_ok=True)
base = (ROOT/'reference-job/test-page.qpdl').read_bytes()
start = base.index(b'@PJL ENTER LANGUAGE = QPDL\n')+len(b'@PJL ENTER LANGUAGE = QPDL\n')
prefix, footer = base[:start+17], base[-13:]
def band_job(payload, band=0):
    payload += b'\0'*(-len(payload)%4)
    record = struct.pack('>BBHHBI',12,band,2480,64,14,len(payload)+4)
    return prefix+record+payload+struct.pack('>I',sum(payload))+footer
white_row = bytes.fromhex('fecdff')  # 65537 - 0xfecd = 308
white = white_row*64
literal_row = bytes.fromhex('8133')+b'\xff'*308
short_row = bytes.fromhex('40ff')*4+bytes.fromhex('51ff') # 4*65 + 48
cases = {
    'baseline_0d':(base,0),
    'white_0e_long':(band_job(white),0),
    'white_0e_literal':(band_job(literal_row*64),0),
    'white_0e_short':(band_job(short_row*64),0),
    'row_overflow':(band_job(bytes.fromhex('feccff')+white_row*63),3),
    'missing_row':(band_job(white_row*63),3),
    'extra_row':(band_job(white_row*65),3),
    'bad_control':(band_job(b'\x20'+white[1:]),3),
    'noncanonical_long':(band_job(bytes.fromhex('ffc0ff')+white_row*63),3),
    'bad_padding':(band_job(white+b'\1'),3),
    'too_much_padding':(band_job(white+b'\0'*4),3),
    'right_edge_ink':(band_job(bytes.fromhex('fecd00')+white_row*63),3),
    'bottom_edge_ink':(band_job(white_row*63+bytes.fromhex('80ff')+b'\0'*256+bytes.fromhex('4dff'),53),3),
    'literal_overflow':(band_job(bytes.fromhex('8134')+b'\xff'*309+white_row*63),3),
    'truncated_literal':(band_job(bytes.fromhex('8133')+b'\xff'*10),3),
}
results=[]
subprocess.run([str(EXE),'--self-test'],check=True)
for name,(data,expected) in cases.items():
    path=OUT/(name+'.qpdl');path.write_bytes(data)
    run=subprocess.run([str(EXE),'--job',str(path),'--sha256',hashlib.sha256(data).hexdigest(),'--validate-only','--no-pause'],capture_output=True,text=True)
    if run.returncode!=expected:raise RuntimeError((name,run.returncode,run.stdout,run.stderr))
    results.append({'case':name,'exit_code':run.returncode,'result':'PASS'})
(OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results))
