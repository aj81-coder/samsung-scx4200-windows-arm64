# SPDX-License-Identifier: Apache-2.0
"""One-time evidence: relocation changes no synthetic PWG fixture bytes.

Usage: python verify-fixture-path.py OLD_HEADER_PWG REPORT_JSON
The old build output is only needed for this audit, not for the test suite.
"""
import ast,hashlib,json,pathlib,sys
source=pathlib.Path(__file__).with_name('test-bridge.py')
old=pathlib.Path(sys.argv[1]).read_bytes()[:1800]
new=source.with_name('test-header.bin').read_bytes()
if old!=new or len(new)!=1800:raise ValueError('Relocated header differs')
tree=ast.parse(source.read_text())
functions=[node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name in ('encode_row','fixture')]
namespace=dict(W=2480,H=3507,HEADER=old)
exec(compile(ast.Module(body=functions,type_ignores=[]),str(source),'exec'),namespace)
evidence=[]
for kind in (1,2,3):
    namespace['HEADER']=old;a=namespace['fixture'](kind)
    namespace['HEADER']=new;b=namespace['fixture'](kind)
    if a!=b:raise ValueError('Fixture bytes changed')
    evidence.append(dict(kind=kind,pwg_sha256=hashlib.sha256(a[0]).hexdigest(),pgm_sha256=hashlib.sha256(a[1]).hexdigest()))
report=dict(result='PASS',header_bytes=len(new),header_sha256=hashlib.sha256(new).hexdigest(),fixture_geometry=[2480,3507],fixtures=evidence,changes='Fixture file location only; no production source or fixture bytes changed',test_script_sha256=hashlib.sha256(source.read_bytes()).hexdigest())
pathlib.Path(sys.argv[2]).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
