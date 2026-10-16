# SPDX-License-Identifier: Apache-2.0
"""Audit the supplied controlled-print ZIP without executing its contents."""
from pathlib import Path
import hashlib
import importlib.util
import io
import json
import sys
import zipfile
from PIL import Image

spec = importlib.util.spec_from_file_location('verifier', Path(__file__).with_name('verify-render.py'))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

def require(test, message):
    if not test:
        raise ValueError(message)

archive, output = Path(sys.argv[1]), Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(archive) as zipped:
    infos = zipped.infolist()
    require(len(infos) <= 32 and sum(i.file_size for i in infos) < 32*1024*1024, 'Unexpected archive size')
    require(len({i.filename for i in infos}) == len(infos), 'Duplicate archive names')
    require(zipped.testzip() is None, 'Archive integrity failed')
    def read_suffix(suffix):
        names = [i.filename for i in infos if i.filename.endswith(suffix)]
        require(len(names) == 1, f'Expected exactly one {suffix}')
        return zipped.read(names[0])
    manifest = json.loads(read_suffix('/manifest.json').decode('utf-8-sig'))
    attempt = json.loads(read_suffix('/attempt-result.json').decode('utf-8-sig'))
    reports = [i.filename for i in infos if Path(i.filename).name.startswith('print-test-') and i.filename.endswith('.json')]
    require(len(reports) == 1, 'Expected one print report')
    report = json.loads(zipped.read(reports[0]).decode('utf-8-sig'))
    files = {}
    for name, field in [('page.pgm','pgm_sha256'), ('page.qpdl','qpdl_sha256'), ('preview.bmp','preview_sha256')]:
        data = read_suffix('/'+name)
        require(hashlib.sha256(data).hexdigest() == manifest[field].lower(), f'{name} hash mismatch')
        files[name] = data
        (output/name).write_bytes(data)
    require(manifest['source_sha256'] == '532a13fbcee92b42b572320c0746711c06d3e9dd8be376e77ea2fc0705506d87', 'Unexpected source capture')
    require(report['build_architecture'] == 'ARM64' and report['version'] == '0.4.0', 'Unexpected target build')
    require(report['result'] == 'BYTES_SENT_AWAITING_PAPER_CHECK' and attempt['sender_exit_code'] == 0, 'Sender did not complete')
    require(report['job_hash_verified'] and report['job_sha256'] == manifest['qpdl_sha256'].lower(), 'Sender job mismatch')
    require(report['job_bytes'] == len(files['page.qpdl']) == 24520, 'Job length mismatch')
    require(report['matching_devices'] == 1 and report['wrong_service'] == 0 and report['exclusive_read_write_open'] and report['user_confirmed_PRINT'], 'Target/confirmation mismatch')
    require(report['identity_query']['manufacturer'] == 'Samsung' and report['identity_query']['model'] == 'SCX-4200 Series', 'Wrong printer')
    for query in ['identity_query','status_query']:
        require(report[query]['success'] and not report[query]['win32_error'] and not report[query]['timed_out'] and not report[query]['cancellation_pending'], 'Query failed')
    transfer = report['transfer']
    require(transfer['attempted'] and transfer['acknowledged_bytes'] == report['job_bytes'] and transfer['write_calls'] == 2, 'Transfer incomplete')
    require(not any(transfer[k] for k in ['win32_error','delivery_uncertain','timed_out','cancellation_pending']), 'Transfer failure or uncertainty')
    decoded = verifier.verify(output/'page.pgm', output/'page.qpdl', output/'decoded-preview.png')
    preview = Image.open(io.BytesIO(files['preview.bmp'])).convert('L')
    independent = Image.open(output/'decoded-preview.png').convert('L')
    require(preview.size == independent.size and preview.tobytes() == independent.tobytes(), 'Preview differs from decoded printer data')
    for name in ['manifest.json','attempt-result.json','render.log','PRINT-ATTEMPTED.txt']:
        (output/name).write_bytes(read_suffix('/'+name))
    (output/'sender-report.json').write_bytes(zipped.read(reports[0]))
    result = dict(result='PASS', archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                  architecture='ARM64', source_rows_sha256=manifest['source_sha256'],
                  qpdl_sha256=report['job_sha256'], acknowledged_bytes=transfer['acknowledged_bytes'],
                  write_calls=transfer['write_calls'], errors=0, uncertain_delivery=False,
                  preview_matches_decoded_pixels=True, decoded=decoded,
                  physical_output='User confirmed printed page matches preview in this chat, 13 October 2026')
    (output/'audit.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result, indent=2))
