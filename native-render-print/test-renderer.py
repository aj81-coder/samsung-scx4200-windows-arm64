"""Exercise file rendering and independent decoding; never opens USB devices.
SPDX-License-Identifier: GPL-2.0-only
Usage: python test-renderer.py [output-directory]
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import subprocess
import sys
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('verify_render', Path(__file__).with_name('verify-render.py'))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
RENDER = ROOT / 'build/render-print/x64/SCX4200-Render.exe'
SENDER = ROOT / 'build/render-print/scx4200-render-print-x64.exe'


def run(args):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=60)


def pgm(image, header=None):
    return (header or f'P5\n2480 {image.height}\n255\n'.encode()) + image.tobytes()


def main():
    destination = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'build/render-print/renderer-tests'
    destination.mkdir(parents=True, exist_ok=True)
    results = []
    blank = Image.new('L', (2480, 3507), 255)
    gradient = blank.copy()
    # Include all gray values repeatedly in a margin-safe region.
    gradient.paste(Image.frombytes('L', (2048, 512), bytes(range(256)) * 4096), (100, 100))
    shapes = Image.new('L', (2480, 3509), 255)
    draw = ImageDraw.Draw(shapes)
    draw.rectangle((48, 63, 2479, 3508), outline=0, width=1)
    draw.ellipse((400, 400, 1400, 1400), fill=80)
    draw.line((52, 3505, 2476, 67), fill=0, width=5)
    dense = blank.copy()
    dense.paste(Image.frombytes('L', (2048, 512), b'\x00\xff' * (2048 * 512 // 2)), (100, 100))
    for name, source in [('blank', blank), ('gray_gradient', gradient), ('boundary_shapes', shapes), ('dense_pattern', dense)]:
        directory = destination / name
        directory.mkdir(exist_ok=True)
        src, job = directory / 'input.pgm', directory / 'output.qpdl'
        src.write_bytes(pgm(source))
        # Each output directory is expected to be fresh. Never delete a pre-existing output.
        rendered = run([RENDER, src, job])
        verify.require(rendered.returncode == 0, f'{name}: renderer failed: {rendered.stderr}')
        checked = verify.verify(src, job, directory / 'preview.png')
        validated = run([SENDER, '--job', job, '--sha256', checked['qpdl_sha256'], '--validate-only', '--no-pause'])
        verify.require(validated.returncode == 0, f'{name}: sender rejected: {validated.stdout} {validated.stderr}')
        (directory / 'validation.json').write_text(json.dumps(checked, indent=2) + '\n', encoding='utf-8')
        results.append({'name': name, 'result': 'PASS', 'checks': ['native render', 'independent all-pixel comparison', 'native sender offline validation'],
                        'compression_band_counts': checked['compression_band_counts'], 'bytes': checked['qpdl_bytes']})
        print(name + ': PASS', flush=True)

    valid = pgm(blank)
    margins = blank.copy()
    margins.putpixel((47, 100), 0)
    top = blank.copy()
    top.putpixel((100, 62), 0)
    invalid = [('bad_magic', valid.replace(b'P5', b'P2', 1)),
               ('bad_width', valid.replace(b'2480', b'2479', 1)),
               ('bad_height', valid.replace(b'3507', b'3508', 1)),
               ('bad_maxval', valid.replace(b'255', b'256', 1)),
               ('truncated_pixels', valid[:-1]), ('trailing_payload', valid + b'x'),
               ('left_margin_ink', pgm(margins)), ('top_margin_ink', pgm(top)),
               ('oversized_token', b'P5\n' + b'2' * 64 + b' 3507\n255\n'),
               ('unterminated_comment', b'P5\n#missing newline')]
    for name, payload in invalid:
        directory = destination / name
        directory.mkdir(exist_ok=True)
        src, job = directory / 'input.pgm', directory / 'output.qpdl'
        src.write_bytes(payload)
        rendered = run([RENDER, src, job])
        verify.require(rendered.returncode != 0 and not job.exists(), f'{name}: invalid input accepted or output created')
        results.append({'name': name, 'result': 'PASS', 'exit_code': rendered.returncode, 'rejection': rendered.stderr.strip()})
        print(name + ': PASS', flush=True)
    existing = destination / 'preserved.qpdl'
    sentinel = b'Existing output must remain unchanged.'
    existing.write_bytes(sentinel)
    rendered = run([RENDER, destination / 'blank/input.pgm', existing])
    verify.require(rendered.returncode != 0 and existing.read_bytes() == sentinel, 'Existing output overwritten')
    results.append({'name': 'existing_output_preserved', 'result': 'PASS', 'exit_code': rendered.returncode})
    report = {'result': 'PASS', 'tests': results, 'test_count': len(results),
              'renderer_sha256': hashlib.sha256(RENDER.read_bytes()).hexdigest(),
              'sender_sha256': hashlib.sha256(SENDER.read_bytes()).hexdigest(), 'usb_access': False}
    (destination / 'results.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'result': report['result'], 'test_count': report['test_count']}))


if __name__ == '__main__':
    main()
