# Capture 0.3.1 development validation

Update: target 0.3.0 confirmed native execution and Windows queue creation but exposed missing gzip support and a queue-removal comment mismatch. See FAILURE-ANALYSIS-0.3.0.md. Version 0.3.1 enables zlib1.3.1 in CUPS and passes ten local tests, adding Windows-style Create-Job/gzip Send-Document and chunked gzip exact-pixel checks. Queue scripts pass mocked identity, idempotency, failure and targeted recovery tests; real repaired removal/printing await the target. The original eight checks below still pass. Debug logging and console page messages are enabled.

Native x64 and ARM64 builds completed with Zig 0.15.2. CUPS2.4.11 is a DLL (required for its Windows initialization); PAPPL1.4.10 is statically linked. PE machines are x64 0x8664 and ARM64 0xaa64. Imported runtime DLLs are Windows components plus the included cups.dll. Exact hashes and results are in packaged validation.json.

Eight independent Python HTTP/IPP tests pass on x64: discovery; completed A4 300dpi sGray capture with all 8,697,360 decoded bytes compared against an independently calculated pattern; unsupported PDF rejection without spooling; bad raster magic; truncated first header; truncated pixels; truncated subsequent header; oversized width. Listener inspection confirms exactly one IPv4 listener on 127.0.0.1:8631. Test server processes are stopped afterward.

The generated PAPPL adaptations reject nonraster input before the spool loop, cap original raster dimensions/pages, preserve callback failures, and use a 32 MiB raster read/drain budget. The CUPS adaptation bounds page-row allocation before its update helper and distinguishes partial reads from clean EOF. These narrow patches apply only to this experimental capture build. Eight-bit grayscale at 300dpi is deliberately required. The application also caps decoded output at 128 MiB per run and 10 pages per job.

Local Add-Printer returned access denied. It did not establish Windows queue compatibility. Target instructions request administrator access solely for adding/removing the named test queue. The scripts have been syntax checked; successful queue creation/removal requires the target trial. No device driver, firewall or background-service changes are part of the package.

Not yet verified for the 0.3.1 repair: native ARM64 execution; successful Windows application page capture; URF content path; cancellation, disk-full, sleep/restart/reconnect, sustained workloads; exact input-budget boundary; full hostile-input hardening. Nonraster request draining remains framework behaviour. CUPS legacy callback/string-pool idioms trap under Zig ReleaseSafe instrumentation; conventional ReleaseFast builds are used and sanitizer testing is not claimed. This is a local, foreground, non-sensitive sample test, not a public production release.

The source package includes unchanged upstream archives, generated-adaptation scripts, application/tests/build scripts and licensing notices. This package contains no SpliX or USB transport. Existing successful physical print baseline remains separate.

