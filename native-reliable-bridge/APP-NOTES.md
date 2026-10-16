# Reliable native bridge integration

The 0.7.0 native app preserves the 0.6.0 raster, multipage bundle, sender report, cancellation, page allowance, and durable session lock contracts. It invokes the independent sender with an additional `--progress` absolute filename in its fresh per-job directory.

Progress is advisory. The sender publishes compact JSON containing `job_sha256` (the verified bundle digest) and `stage`. The bridge reads a bounded 2 KiB snapshot using `FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE`, allowing the sender to atomically replace its file. Missing or incomplete snapshots are ignored. Completion still requires every existing sender report check; progress never authorizes a resend.

`WAITING_PAPER` displays a refill-and-wait message and sets the documented PAPPL `PAPPL_PREASON_MEDIA_EMPTY` reason. `WAITING_PRINTER` displays a generic readiness message. `SENDING` clears media-empty. A validated successful report also clears it if a brief sending transition was missed between polls. Status-byte interpretation belongs to the sender and is not duplicated here.

The parent process deadline is 60 seconds per page plus 300 seconds of sender wait allowance and 20 seconds of shutdown overhead. Cancellation retains inherited cancellation events until shutdown and preserves existing child job-object guards. Failed or uncertain delivery blocks the session and leaves the durable lock in place.

`build-bridge.ps1 -TestSender` produces a separate `build/reliable-tests/{architecture}` binary. This compile-only variant uses `SCX4200-Test-Sender.exe` for validation and transfer, and accepts a `test-stop.request` marker for headless graceful shutdown tests. Production binaries contain neither the marker hook nor a runtime sender override.

No successful USB-write result claims that paper physically printed. Target-machine paper-out recovery still requires a physical test.
