# Controlled runtime sender

`sender-build.ps1` builds native ARM64 and x64 executables under `build/render-print` using pinned Zig 0.15.2. The independent C sender uses the existing Windows USB read helpers and BCrypt; it does not link SpliX.

Usage: `scx4200-render-print-arm64.exe --job page.qpdl --sha256 HEX [--check-only] [--no-pause]`

`--validate-only` validates the file without enumerating or opening any device. `--self-test` exercises framing mutations/truncation, confirmation and target matching, partial writes, failed writes, zero/oversized acknowledgements, and uncertain cancellation. Neither sends data. `--no-pause` only suppresses the closing prompt; it never removes the required interactive console and exact `PRINT` confirmation.

The file is read once into a maximum 4 MiB allocation. SHA-256 and the narrow QPDL validator inspect the same memory subsequently sent. Invalid files stop before device access. The validator requires the exact existing job-scoped PJL prefix, a 300 dpi A4 2480 x 3509 one-copy page header, increasing unique bands, 0x0d or 0x0e compression, bounded packet lengths, checksums, valid decoded coordinates, and an exact one-page footer. Blank pages are valid. For 0x0e, each of 64 rows must decode to exactly 308 bytes, runs cannot cross rows, and only up to three zero padding bytes may remain. Ink outside the source page is rejected. This intentionally rejects other otherwise legal QPDL profiles.

USB behavior retains the reviewed baseline: exact MI_01 device instance, usbprint service, Samsung SCX-4200 identity, one matching device, exclusive read/write open, read-only identity/status queries, then console confirmation. Failed or ambiguous writes stop without retry. Heap bytes, pending OVERLAPPED/event and device handle remain alive until process exit if cancellation does not complete.

Validation performed: both architectures compile with warnings treated as errors; x64 self-test passes; the physically proven baseline QPDL passes. Fourteen local file checks passed, including recomputed-hash malformed jobs: extra page, truncation, DEFAULT command, wrong resolution, two copies, wrong width/algorithm/band index, bad checksum, oversized length, duplicate band, and an out-of-bounds packet with a valid checksum. Results are in `build/render-print/validator-tests/results.json`. No hardware send was performed.

The reproducible sender-verify.py suite adds 15 cases covering baseline 0x0d, each valid 0x0e control form, row overflow/underflow, extra rows, invalid control, noncanonical long run, bad/excess padding, right/bottom ink bounds and truncated literals. All pass with checksums and hashes recomputed for each malformed job.
