# Direct cancellation control add-on

`cancel-current-job.ps1` is a Windows PowerShell 5.1 tool for a running
0.7.0 SCX4200-Reliable-Bridge in the same extracted folder. It does not alter
the bridge binaries, Windows queues, or printer USB connection.

It requires one matching bridge executable path and an exclusive loopback
8631 listener owned by that PID. It obtains noncompleted jobs using IPP
Get-Jobs and preserves each job group when parsing. Only exactly one
processing job is eligible. It rechecks the PID, process start time, path,
and listener before sending Cancel-Job for that one discovered ID. Empty,
ambiguous, malformed, changed-process, or failed responses send no cancel.
HTTP redirects and proxies are disabled. Requests/read waits are bounded at
five seconds; responses are capped at 64 KiB. JSON reports contain job IDs,
states and control outcomes, without document titles or USB identifiers.

CancelAccepted means the bridge accepted the request. It does not assert
that firmware-buffered data was recalled or that USB delivery was complete.
The current bridge intentionally blocks the session after cancellation or
uncertain delivery. Follow the parent project's reset procedure before a
fresh print attempt. NoBridgeProcess means this folder's bridge is closed;
a printer's PC Print Pending message can still describe buffered device data.

Verification:
- `test-cancel-current-job.ps1`: parser and mocked controller cases; no I/O.
- `test-cancel-integration.py`: starts an isolated x64 test-only bridge with
  a fake waiting sender (compiled without USB transport), then invokes the
  unmodified production PowerShell tool including process/listener guards.
  No real printer or Windows queue is accessed. Uses the bundled Python only
  on the development machine; the target cancellation tool needs no Python.

The baseline 0.7.0 binaries and existing packages remain unchanged.
