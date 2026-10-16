# Background printer preview

This is the next usability milestone after the verified foreground engine.
The new native GUI host starts the bridge without stdin, uses a persistent
per-user data directory, exposes tray controls, and is registered at sign-in
by the one-time per-user setup. The existing Windows printer is preserved.
Read START-HERE.txt for user operation and the consolidated target check.

0.11.1 corrects the first target installation refusal: that laptop exposes
only FormTrayTable, without a queue URL. Setup now preserves the exact existing
queue name, Microsoft IPP Class Driver and recorded port when the URL is absent,
and records endpoint_verified=false. It still rejects any reported conflicting
URL and requires an empty queue. The expected bridge URI in the receipt is
configuration, not evidence that Windows exposed the queue's URI. No runtime
binary, queue, control or transport implementation changed for this correction.

The foreground source/binaries remain a regression baseline. `bridge.c` is
an explicit background fork, retaining the complete-spool/independent-renderer/
inherited-permit USB boundary. No automatic replay or dirty-lock restart is
introduced. The engine and GUI use a shared startup/control mutex. A host-owned
job object stops the engine tree if the host dies; the engine separately owns
its renderer/sender processes. Windows 11 nested job behavior was exercised
with the real engine and compile-time fake sender.

The per-document limits remain 10 pages, 90 MiB decoded pixels and the existing
compressed spool / bundle admission bounds. Lifetime page counters no longer
gate operation. A process-lifetime cancellation event replaces the retained
per-document handle array; it is reset only before a sequential sender and
stop/cancellation are then rechecked. Successful-only allowlisted capture
cleanup and a 10-job metadata ring bound ongoing runs. Failed/unknown files
remain; a 512 MiB retained-data guard, 512 MiB free-space reserve and bounded
directory traversal refuse new work rather than silently erase evidence.
Old run logs and recovery archives need a future owned-history retention policy.

The separate PAPPL background library has three pinned changes: override
client-requested terminal retention, make admitted old readonly spool files
removable, and create new spool files with writable CRT mode so rejected
uploads can also be deleted. Windows ACLs remain the access boundary. The
framework loop has a one-second timer so idle shutdown does not wait on its
30-second listener poll. Pending/active work or uncertainty retains the lock.

## Build from the supplied source

Use the source package's REBUILDING.txt prerequisites (Windows x64,
PowerShell 7, pinned Zig 0.15.2; Python/Pillow/NumPy for tests). Then:

    ./native-background/rebuild.ps1 -Architecture both

This first builds the pinned foreground dependencies/renderer/sender using
the audited source recipe, then the isolated background framework, engine
and GUI. No queue, startup registration or printer is changed by the build.
Outputs are under build/background/ARCH. `prepare-engine.py` was a one-time
development derivation and is not a build input or included release source tool.

Tests are deliberately device-free: `test-engine.py` and `test-integration.py`
require a bridge compiled with `build-engine.ps1 -TestSender` and the fake
sender tools from `native-async-bridge/build-test-tools.ps1 -RendererRoot
build/margin-fix`. Never replace that boundary with a production USB sender.
`test-host.py` tests the production host with its own harmless child. Run tray
tests sequentially because the host intentionally permits one instance.
Setup and control suites mock all printer/startup/UI actions. The final target
check is installation, ordinary printing, idle restart/sign-in and printing
again; no claim of ARM64 execution follows from local cross-compilation.

Original source in this directory is Apache-2.0. The separate renderer and
existing GPL verification code retain their terms; see LICENSING.md,
PROVENANCE.md, component mapping and LICENSES in the accompanying source.
