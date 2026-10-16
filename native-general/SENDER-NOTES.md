# Streaming sender

The production entry point retains one `CreateFileW` source handle with read
sharing only. Existing writers prevent opening it; later writers and deletion
are denied until the sender exits. It hashes the entire SCXJOB06 envelope and
then checks every page's length, SHA-256 and QPDL framing before enumerating USB.
The retained handle is rewound for delivery; the pathname is never reopened.

Validation uses one 4 MiB page allocation, then frees it. Delivery uses one
16 KiB heap buffer. Page counts and byte accounting require no allocation that
grows with document length. The existing 4 MiB per-page validator bound remains;
the former ten-page and 40 MiB per-document restrictions are absent from the
production path. The unchanged SCXJOB06 format has a nonzero unsigned 32-bit page
count and unsigned 32-bit per-page lengths. Windows ARM64/x64 file sizes and byte
totals use 64-bit values. Practical limits remain disk space, processing time and
the supported page format. The page-scaled timeout cannot overflow a 64-bit tick
count for any representable page count.

The original one-use inherited permit, manual cancellation event, exclusive USB
open, identity/status checks, exact pending-write retention and no-replay failure
policy are preserved. A pending uncancellable write retains its heap buffer until
process exit. Confirmed short writes advance by exactly their reported count.

`make-stream-sender.py` records how the variant was derived from the retained
reliable sender. Some old bounded-memory helpers and ten-element test arrays
remain solely for the inherited `--self-test`; production progress uses the
streamed completion counter, including before the first USB write.

`sender-stream-tests.c` is a device-free test harness, never a shipping sender.
`test-sender-stub.c` is a separate integration-test child with no USB APIs. Its
wait/release marker protocol is compatible with the earlier reliable tests.
Neither test executable belongs in a user package.

The public [validation record](../VALIDATION.md) summarizes offline regression
evidence. It covers a 25-page,
52,436,937-byte valid document; exact captured-output hash after short writes;
wrong hashes; truncation; count mismatch; malformed QPDL with correct hashes;
source writer denial; cancellation before/between writes and during validation;
failure without replay; initial long-document progress; and the inherited real
private-pipe pending-write cancellation/resume tests. No printer was accessed.
