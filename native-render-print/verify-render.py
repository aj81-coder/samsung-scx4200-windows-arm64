"""Independently decode the restricted SCX-4200 renderer's QPDL output.

SPDX-License-Identifier: GPL-2.0-only
Derived from reference-job/fixture.py. Requires Pillow; never accesses a printer.
Usage: verify-render.py input.pgm output.qpdl report.json preview.png
"""
from pathlib import Path
import hashlib
import json
import struct
import sys
from PIL import Image, __version__ as pillow_version

W, H, MX, MY, BH, WRAP = 2480, 3509, 48, 63, 64, 2464
BAYER = ((0, 8, 2, 10), (12, 4, 14, 6), (3, 11, 1, 9), (15, 7, 13, 5))
PJL = (b'\x1b%-12345X@PJL SET USERNAME="SCX4200 test"\n'
       b'@PJL SET JOBNAME="SCX4200 native USB test"\n'
       b'@PJL SET JAMRECOVERY=OFF\n@PJL SET DUPLEX=OFF\n'
       b'@PJL SET PAPERTYPE=NORMAL\n@PJL SET ALTITUDE=LOW\n'
       b'@PJL SET DENSITY=3\n@PJL SET RET=NORMAL\n'
       b'@PJL ENTER LANGUAGE = QPDL\n')
FOOTER = b'\x01\x00\x01\x09\x1b%-12345X'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_bounded(path, maximum):
    with Path(path).open('rb') as stream:
        data = stream.read(maximum + 1)
    require(len(data) <= maximum, f'File exceeds {maximum} byte limit: {path}')
    return data


def read_pgm(data):
    """Parse P5 without mistaking initial raster whitespace for header bytes."""
    pos = 0
    whitespace = b' \t\r\n\v\f'

    def token():
        nonlocal pos
        while pos < len(data):
            if data[pos] in whitespace:
                pos += 1
            elif data[pos] == 35:
                end = data.find(b'\n', pos)
                require(end >= 0, 'Unterminated PGM header comment')
                pos = end + 1
            else:
                break
        begin = pos
        while pos < len(data) and data[pos] not in whitespace + b'#':
            pos += 1
        require(0 < pos - begin <= 16, 'Missing or oversized PGM header token')
        return data[begin:pos]

    require(token() == b'P5', 'Only binary grayscale P5 PGM is supported')
    dimensions = [token(), token(), token()]
    require(all(t.isdigit() for t in dimensions), 'PGM dimensions/maxval must be decimal integers')
    width, height, maximum = map(int, dimensions)
    require(width == W and height in (3507, H) and maximum == 255,
            'Expected 2480x3507 or 2480x3509 grayscale PGM with maxval 255')
    require(pos < len(data) and data[pos] in whitespace, 'Missing PGM raster delimiter')
    # Windows writers may use CRLF; otherwise consume exactly one delimiter.
    if data[pos:pos + 2] == b'\r\n':
        pos += 2
    else:
        pos += 1
    require(len(data) - pos == width * height, 'PGM raster length mismatch or trailing data')
    return height, memoryview(data)[pos:]


def threshold(height, pixels):
    result = bytearray(W * H)
    black = 0
    for y in range(height):
        limits = tuple(value * 16 + 8 for value in BAYER[y % 4])
        offset = y * W
        for x in range(W):
            if pixels[offset + x] < limits[x % 4]:
                require(x >= MX and y >= MY,
                        f'Black source pixel in cropped hardware margin at ({x}, {y})')
                result[offset + x] = 255
                black += 1
    return result, black


def decode_0e(data, number, decoded):
    """Expand row-local literal/run packets; 0xFF is white in this format."""
    q = 0
    counts = {'literal': 0, 'short_run': 0, 'long_run': 0}
    row_bytes = WRAP // 8
    for y in range(BH):
        row = bytearray()
        while len(row) < row_bytes:
            require(q < len(data), 'Truncated 0x0E row')
            control = data[q]
            q += 1
            if 0x40 <= control <= 0x7f:
                count = 129 - control
                require(q < len(data), 'Truncated 0x0E short run')
                chunk = bytes([data[q]]) * count
                q += 1
                counts['short_run'] += 1
            elif control in (0xfe, 0xff):
                require(q + 2 <= len(data), 'Truncated 0x0E long run')
                count = 65537 - ((control << 8) | data[q])
                require(66 <= count <= row_bytes, 'Invalid 0x0E long run length')
                chunk = bytes([data[q + 1]]) * count
                q += 2
                counts['long_run'] += 1
            elif control in (0x80, 0x81):
                require(q < len(data), 'Truncated 0x0E literal header')
                count = ((control & 0x7f) << 8 | data[q]) + 1
                q += 1
                require(count <= row_bytes and q + count <= len(data), 'Invalid or truncated 0x0E literal')
                chunk = data[q:q + count]
                q += count
                counts['literal'] += 1
            else:
                raise ValueError(f'Invalid 0x0E packet control 0x{control:02x}')
            require(len(row) + len(chunk) <= row_bytes, '0x0E packet crosses row boundary')
            row.extend(chunk)
        sy = MY + number * BH + y
        for xb, value in enumerate(row):
            for bit in range(8):
                if not (value & (0x80 >> bit)):
                    sx = MX + xb * 8 + bit
                    require(sy < H and sx < W, '0x0E black pixel exceeds page bounds')
                    decoded[sy * W + sx] = 255
    require(len(data) - q <= 3 and not any(data[q:]), 'Invalid 0x0E alignment padding')
    return counts


def decode(job):
    require(job.startswith(PJL), 'PJL envelope differs from approved fixed job envelope')
    header = bytes([0, 3, 0, 1, 2]) + struct.pack('>HH', W, H) + bytes([1, 0, 1, 0, 2, 1, 1, 3])
    p = len(PJL)
    require(job[p:p + 17] == header, 'Unexpected page geometry, resolution, copies or options')
    p += 17
    decoded = bytearray(W * H)
    previous = -1
    bands = 0
    packets = {2: 0, 4: 0, 6: 0}
    algorithms = {'0x0D': 0, '0x0E': 0}
    fallback_packets = {'literal': 0, 'short_run': 0, 'long_run': 0}
    while p < len(job) and job[p] == 0x0c:
        require(p + 11 <= len(job), 'Truncated band header')
        _, number, width, height, algorithm, length = struct.unpack('>BBHHBI', job[p:p + 11])
        p += 11
        require(previous < number < 54, 'Bands must be ordered, unique and within page')
        require(width == W and height == BH and algorithm in (13, 14), 'Unsupported band geometry or compression')
        previous = number
        bands += 1
        require(length >= 8 and p + length <= len(job), 'Truncated or empty band payload')
        data = job[p:p + length - 4]
        require(len(data) % 4 == 0, 'Band payload must be four-byte aligned')
        require(sum(data) == int.from_bytes(job[p + length - 4:p + length], 'big'), 'Band checksum mismatch')
        p += length
        algorithms[f'0x{algorithm:02X}'] += 1
        if algorithm == 14:
            counts = decode_0e(data, number, decoded)
            for kind, count in counts.items():
                fallback_packets[kind] += count
            continue
        q = x = y = 0
        while q < len(data):
            a = data[q]
            if a < 0x80:
                require(q + 2 <= len(data), 'Truncated two-byte packet')
                dy, run = a >> 6, a & 63
                dx = int.from_bytes(data[q + 1:q + 2], 'big', signed=True)
                q += 2
                packets[2] += 1
                if run == 0:
                    require(dx == dy == 0 and not any(data[q:]), 'Invalid zero-run packet or padding')
                    break
                x += dx
                y += dy
            elif a < 0xc0:
                require(q + 4 <= len(data), 'Truncated four-byte packet')
                dx = ((a & 63) << 8) | data[q + 1]
                if dx & 8192:
                    dx -= 16384
                require(data[q + 2] & 0xc0 == 0x80, 'Invalid four-byte packet marker')
                dy = (data[q + 2] >> 4) & 3
                run = ((data[q + 2] & 15) << 8) | data[q + 3]
                x += dx
                y += dy
                q += 4
                packets[4] += 1
            else:
                require(a == 0xc0 and q + 6 <= len(data), 'Invalid or truncated six-byte packet')
                require(data[q + 4] & 0xc0 == 0xc0, 'Invalid six-byte packet marker')
                delta = int.from_bytes(data[q + 1:q + 4], 'big')
                y, x = divmod(y * WRAP + x + delta, WRAP)
                run = ((data[q + 4] & 63) << 8) | data[q + 5]
                q += 6
                packets[6] += 1
            require(0 < run and 0 <= x < x + run <= WRAP and 0 <= y < BH,
                    'Decoded run exceeds band bounds')
            sy, sx = MY + number * BH + y, MX + x
            require(sy < H and sx + run <= W, 'Decoded run exceeds page bounds')
            begin = sy * W + sx
            decoded[begin:begin + run] = b'\xff' * run
    require(job[p:] == FOOTER, 'Expected exact single-page, single-copy job footer')
    return decoded, bands, packets, algorithms, fallback_packets


def verify(input_path, job_path, preview_path):
    pgm = read_bounded(input_path, W * H + 65536)
    height, pixels = read_pgm(pgm)
    expected, black = threshold(height, pixels)
    job = read_bounded(job_path, 16 * 1024 * 1024)
    actual, bands, packets, algorithms, fallback_packets = decode(job)
    if actual != expected:
        index = next(i for i, (a, b) in enumerate(zip(actual, expected)) if a != b)
        raise ValueError(f'Decoded pixel differs from thresholded input at ({index % W}, {index // W})')
    Image.frombytes('L', (W, H), bytes(255 - v for v in actual)).save(preview_path, dpi=(300, 300))
    return {'result': 'PASS', 'source_sha256': hashlib.sha256(pgm).hexdigest(),
            'qpdl_sha256': hashlib.sha256(job).hexdigest(), 'qpdl_bytes': len(job),
            'source_width': W, 'source_height': height, 'output_width': W, 'output_height': H,
            'white_rows_padded': H - height, 'pages': 1, 'copies': 1, 'dpi': 300,
            'bands': bands, 'band_height': BH,
            'compression': [kind for kind, count in algorithms.items() if count],
            'compression_band_counts': algorithms, 'packet_counts': packets,
            'fallback_packet_counts': fallback_packets,
            'black_pixels': black, 'pillow_version': pillow_version,
            'checks': ['exact approved PJL envelope', 'exact page header and one-page footer',
                       'ordered unique bands', 'every band checksum', 'bounds-checked packet decoding',
                       'every decoded pixel equals ordered-dither input', 'cropped source margins are white'],
            'physical_printer_test': 'NOT PERFORMED BY THIS TOOL'}


def main(args):
    if len(args) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        report = verify(args[0], args[1], args[3])
    except (OSError, ValueError) as error:
        report = {'result': 'FAIL', 'error': str(error)}
    Path(args[2]).write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))
    return 0 if report['result'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
