"""Local PAPPL integration checks. Does not start servers or configure queues.

Use a fixture from generate-raster.c and the *current* server capture directory.
This is HTTP/IPP and pixel-path validation, not Windows Print dialog acceptance.
SPDX-License-Identifier: Apache-2.0
"""
import argparse
import hashlib
import gzip
import http.client
import json
from pathlib import Path
import struct
import sys
import time
from urllib.parse import urlsplit


def attribute(tag, name, value):
    name = name.encode("utf-8")
    if isinstance(value, str):
        value = value.encode("utf-8")
    elif isinstance(value, int):
        value = struct.pack(">i", value)
    return bytes([tag]) + struct.pack(">H", len(name)) + name + struct.pack(">H", len(value)) + value


def parse_ipp(data, request_id):
    if len(data) < 9:
        raise ValueError("Truncated IPP response")
    version_major, version_minor, status, response_id = struct.unpack(">BBHI", data[:8])
    if response_id != request_id:
        raise ValueError("IPP request ID mismatch")
    result = {"version": f"{version_major}.{version_minor}", "status": status, "attributes": {}}
    i, name = 8, None
    while i < len(data):
        tag = data[i]
        i += 1
        if tag == 3:
            return result
        if tag <= 15:
            name = None
            continue
        if i + 2 > len(data):
            raise ValueError("Truncated name length")
        length = struct.unpack_from(">H", data, i)[0]
        i += 2
        if i + length + 2 > len(data):
            raise ValueError("Truncated attribute name")
        if length:
            name = data[i:i + length].decode("utf-8", errors="replace")
        i += length
        length = struct.unpack_from(">H", data, i)[0]
        i += 2
        if i + length > len(data) or name is None:
            raise ValueError("Invalid attribute value")
        raw = data[i:i + length]
        i += length
        if tag in (0x21, 0x23) and length == 4:
            value = struct.unpack(">i", raw)[0]
        elif tag == 0x22 and length == 1:
            value = bool(raw[0])
        elif tag in (0x41, 0x42, 0x44, 0x45, 0x47, 0x48, 0x49):
            value = raw.decode("utf-8", errors="replace")
        else:
            value = {"tag": tag, "hex": raw.hex()}
        result["attributes"].setdefault(name, []).append(value)
    raise ValueError("Missing end-of-attributes")


class Endpoint:
    def __init__(self, url):
        self.url = urlsplit(url)
        if self.url.scheme != "http" or self.url.hostname != "127.0.0.1" or self.url.port != 8631:
            raise ValueError("Tests are restricted to http://127.0.0.1:8631")
        self.uri = "ipp://127.0.0.1:8631" + self.url.path
        self.request_id = 0

    def request(self, operation, extra=b"", document=b"", chunked=False):
        self.request_id += 1
        body = struct.pack(">BBHI", 2, 0, operation, self.request_id) + b"\x01"
        body += attribute(0x47, "attributes-charset", "utf-8")
        body += attribute(0x48, "attributes-natural-language", "en")
        body += attribute(0x45, "printer-uri", self.uri)
        body += extra + b"\x03" + document
        connection = http.client.HTTPConnection("127.0.0.1", 8631, timeout=30)
        try:
            wire = (body[i:i+1024] for i in range(0,len(body),1024)) if chunked else body
            connection.request("POST", self.url.path, wire, {"Content-Type": "application/ipp"}, encode_chunked=chunked)
            response = connection.getresponse()
            payload = response.read(2 * 1024 * 1024 + 1)
            if response.status != 200 or len(payload) > 2 * 1024 * 1024:
                raise ValueError(f"Unexpected HTTP response {response.status}/size {len(payload)}")
            return parse_ipp(payload, self.request_id)
        finally:
            connection.close()

    def print_job(self, name, mime, content):
        extra = attribute(0x42, "requesting-user-name", "SCX-local-test")
        extra += attribute(0x42, "job-name", name)
        extra += attribute(0x49, "document-format", mime)
        return self.request(2, extra, content)

    def terminal_job(self, response):
        ids = response["attributes"].get("job-id", [])
        if not ids:
            return response, None
        for _ in range(40):
            response = self.request(9, attribute(0x21, "job-id", ids[0]))
            states = response["attributes"].get("job-state", [])
            if states and states[0] >= 7:
                return response, states[0]
            time.sleep(0.1)
        raise ValueError("Job did not reach a terminal state within four seconds")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8631/ipp/print")
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--test-truncated-next-header", action="store_true",
                        help="Also test the separately tracked partial-next-header boundary")
    args = parser.parse_args()
    endpoint = Endpoint(args.url)
    report = {"scope": "local HTTP/IPP and decoded pixels; no Windows queue test", "checks": []}

    def check(name, function):
        try:
            detail = function()
            report["checks"].append({"name": name, "passed": True, "detail": detail})
        except Exception as exc:
            report["checks"].append({"name": name, "passed": False, "error": str(exc)})

    fixture = args.fixture.read_bytes()
    if len(fixture) <= 1800 or fixture[:4] != b"RaS2":
        parser.error("Expected a complete PWG fixture from generate-raster.c")
    # PWG page header has 4x64-byte strings then 4-byte big-endian fields.
    width, height = struct.unpack_from(">II", fixture, 4 + 372)
    if (width, height) != (21000 * 300 // 2540, 29700 * 300 // 2540):
        parser.error(f"Unexpected fixture geometry {width}x{height}")
    expected = b"".join(bytes(((x // 31 + y // 29) * 37) & 255 for x in range(width)) for y in range(height))
    expected_hash = hashlib.sha256(expected).hexdigest()

    def discovery():
        response = endpoint.request(11, attribute(0x44, "requested-attributes", "all"))
        if response["status"] >= 0x0400:
            raise ValueError(f"Get-Printer-Attributes failed: {response}")
        attrs = response["attributes"]
        if "image/pwg-raster" not in attrs.get("document-format-supported", []):
            raise ValueError("PWG raster is not advertised")
        if "gzip" not in attrs.get("compression-supported", []):
            raise ValueError("Windows gzip transport is not advertised")
        keys = ("printer-uri-supported", "document-format-supported", "printer-resolution-supported",
                "pwg-raster-document-type-supported", "media-supported", "sides-supported", "compression-supported")
        return {key: attrs.get(key) for key in keys}

    def print_pattern(compressed=False, chunked=False):
        if compressed:
            response = endpoint.request(5, attribute(0x42, "job-name", "Windows-style gzip regression"))
            if response["status"] >= 0x0400:
                raise ValueError(f"Create-Job failed: {response}")
            job_id = response["attributes"]["job-id"][0]
            extra = attribute(0x21, "job-id", job_id) + attribute(0x22, "last-document", b"\x01")
            extra += attribute(0x49, "document-format", "image/pwg-raster") + attribute(0x44, "compression", "gzip")
            sent = endpoint.request(6, extra, gzip.compress(fixture, mtime=0), chunked=chunked)
            if sent["status"] >= 0x0400:
                raise ValueError(f"Send-Document failed: {sent}")
        else:
            response = endpoint.print_job("SCX deterministic local fixture", "image/pwg-raster", fixture)
        if response["status"] >= 0x0400:
            raise ValueError(f"Print-Job failed: {response}")
        job_id = response["attributes"]["job-id"][0]
        final, state = endpoint.terminal_job(response)
        if state != 9:
            raise ValueError(f"Expected completed capture job, got {state}: {final}")
        base = args.capture_dir / f"job-{job_id:06d}-page-01"
        rows = base.with_suffix(".rows").read_bytes()
        metadata = json.loads(base.with_suffix(".json").read_text(encoding="utf-8"))
        if rows != expected:
            raise ValueError("Captured pixels differ from independent expected pattern")
        if metadata["sha256"] != expected_hash or metadata["captured_bytes"] != len(expected):
            raise ValueError("Metadata byte count/hash differs from independently computed value")
        if (metadata["width"], metadata["height"], metadata["resolution"], metadata["bits_per_pixel"], metadata["color_space"]) != (width, height, [300, 300], 8, 18):
            raise ValueError("Captured page geometry/layout differs from fixture")
        if metadata["physical_printing"] is not False:
            raise ValueError("Metadata incorrectly implies physical printing")
        return {"job_id": job_id, "job_state": state, "decoded_bytes": len(rows), "sha256": expected_hash}

    def rejected(name, mime, content, require_ipp_error=False):
        before = set((args.capture_dir / "spool").rglob("*"))
        response = endpoint.print_job(name, mime, content)
        final, state = endpoint.terminal_job(response)
        after = set((args.capture_dir / "spool").rglob("*"))
        new_files = [str(path) for path in after - before if path.is_file()]
        if new_files:
            raise ValueError(f"Unexpected new spool files: {new_files}")
        if require_ipp_error and response["status"] < 0x0400:
            raise ValueError(f"Expected IPP rejection, got {response}")
        if response["status"] < 0x0400 and state not in (7, 8):
            raise ValueError(f"Malformed input was not canceled/aborted: {final}")
        return {"ipp_status": response["status"], "job_state": state, "new_spool_files": new_files}

    check("get_printer_attributes", discovery)
    check("complete_pattern_and_exact_pixels", print_pattern)
    check("create_job_gzip_send_document_exact_pixels", lambda: print_pattern(compressed=True))
    check("chunked_gzip_send_document_exact_pixels", lambda: print_pattern(compressed=True, chunked=True))
    check("reject_pdf_without_spool", lambda: rejected("Unsupported PDF", "application/pdf", b"%PDF-1.4\n%%EOF\n", True))
    check("reject_bad_raster_magic", lambda: rejected("Malformed raster", "image/pwg-raster", b"not a PWG file"))
    check("reject_truncated_raster_header", lambda: rejected("Short raster header", "image/pwg-raster", fixture[:100]))
    check("reject_truncated_raster_pixels", lambda: rejected("Short raster pixels", "image/pwg-raster", fixture[:max(1801, len(fixture) // 2)]))
    if args.test_truncated_next_header:
        check("reject_truncated_next_header", lambda: rejected("Short next page header", "image/pwg-raster", fixture + fixture[4:100]))
    oversized = bytearray(fixture)
    struct.pack_into(">I", oversized, 4 + 372, 0x7fffffff)
    check("reject_oversized_width", lambda: rejected("Oversized width", "image/pwg-raster", bytes(oversized)))
    report["passed"] = all(item["passed"] for item in report["checks"])
    with args.report.open("x", encoding="utf-8") as output:
        json.dump(report, output, indent=2)
        output.write("\n")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
