# Reliability sender 0.7.0

Baseline 0.6.0 remains unchanged. This sender preserves the SCXJOB06 envelope,
strict per-page QPDL validation, single-use inherited permit, cancellation event,
exact Samsung USBPRINT device selection and exclusive document handle.

The CLI adds `--progress ABSOLUTE_FILE` for real delivery. The file must not
already exist. The sender publishes durable complete JSON snapshots using a
new temporary file and atomic replacement. JSON contains the bundle
`job_sha256`, `stage`, `acknowledged_bytes`, `pages_data_completed`,
`document_pages`, `status_byte` (number or null), `elapsed_ms`,
`paper_wait_ms` and `status_polls`. Stages are SENDING, WAITING_PAPER,
WAITING_PRINTER, COMPLETE and FAILED. These are advisory; the final report
remains authoritative. COMPLETE means Windows accepted all payload bytes,
not that the physical page has been observed.

USB printer-class status uses only bits 3, 4 and 5: paper empty 0x20,
selected 0x10, no error 0x08. Other bits are ignored; both observed target
values 24 and 25 are ready. Paper-empty status takes priority. A not-ready
or unavailable status becomes generic WAITING_PRINTER. The semantics follow
Table 3 of the [USB Printer Class specification](https://www.usb.org/sites/default/files/usbprint11a021811.pdf).
No vendor status, reset or set request is issued.

Before each chunk, the sender polls read-only GET_LPT_STATUS. If not ready,
it waits without issuing a print write. During a pending write, it polls
status approximately each second and preserves the SAME WriteFile request,
OVERLAPPED, event and buffer. Refilling paper can allow that request to finish;
it is never cancelled and resubmitted merely because the old 15-second
deadline expired. A ready status with a still-pending request is shown as
WAITING_PRINTER because the device cannot explain that delay accurately.

Each pending write is bounded to five minutes. The entire document is bounded
to sixty seconds per page plus five minutes, with small cancellation/IO
cleanup overhead. Queries have a one-second completion bound and a further
one-second cancellation bound. Cancellation, disconnect, hard timeout or
error stops delivery without replay. Confirmed short writes advance only by
the acknowledged count. An uncancelled driver request retains its heap state
and device handle until process exit; no additional status requests accumulate.
Paper-wait timing counts observed wait intervals, not time inside the printer.

The report adds `printer_wait.status_polls`, `printer_wait.paper_wait_ms`
and `printer_wait.write_requests_replayed` (always zero). The original
transfer fields and delivery-uncertainty semantics remain intact.

`--self-test` performs no USB writes. It retains all baseline framing,
target, permit, partial-write and page-boundary checks. A real private named
pipe keeps one overlapped write pending beyond an accelerated old deadline
of 250 ms, resumes after 600 ms, and verifies the exact 16 KiB stream.
Separate real pipe tests cover cancellation, hard timeout and disconnect.
Injected status tests cover reserved bits, paper-empty-to-ready progression
and cancellation while waiting. ARM64 is cross-compiled; native tests run
on x64. Actual in-flight refill recovery still needs hardware validation.

`sender-tests.py` passes 29 device-free admission checks: the original 27
bundle, hash, permit, pre-launch cancellation and report-preservation checks,
plus hash-bound durable progress and existing-progress preservation. Every
authorized native invocation in this suite carries a pre-signaled cancellation
event; no device enumeration or printer writes occur. Its hash-bound evidence
is `build/reliable-bridge/sender-validation.json`. The bridge's genuine inherited
handle launch is separately covered by `test-sender-handoff.py`.
