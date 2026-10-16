# Reliability milestone 0.7.0

The target0.6.0 two-page PDF printed correctly twice. Its earlier paper-out run acknowledged81,920 of169,750bytes, then timed out during the sixth write. The first page printed correctly and the printer produced an incomplete-section error. That evidence establishes an interrupted transfer, not invalid raster generation: both page QPDL payloads independently reproduce their source pixels.

## Changes and limits

The sender now retains the same pending overlapped WriteFile request while waiting. It polls completion/cancellation and read-only status without resubmitting that request. A pending write is capped at300seconds; the entire document is capped at60seconds per page plus300seconds. The bridge allows an additional20seconds for child shutdown. Confirmed short writes advance only by their confirmed byte count. Failed/ambiguous operations still stop and never automatically retry.

USB printer status bits are interpreted using only mask0x38: bit5 paper-empty, bit4 selected, bit3 not-error. Reserved bits are ignored (the target has returned24 and25 while operational). The USB specification explicitly permits printers that cannot determine status to return benign values. Thus WAITING_PAPER is useful when reported; otherwise pending delivery displays WAITING_PRINTER and asks the user to check readiness. See the [USB-IF printer class specification, table3](https://www.usb.org/sites/default/files/usbprint11a021811.pdf) and [Microsoft USBPRINT status IOCTL](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/usbprint/ni-usbprint-ioctl_usbprint_get_lpt_status).

Progress snapshots are flushed and atomically replaced. The parent reads bounded snapshots with deletion sharing and checks their bundle hash. Progress controls messages and the IPP media-empty indication; it never establishes successful delivery or authorizes replay. Success still requires the full final sender report, exact byte/page/hash/permit validation, and durable job/session records. Actual paper requires observation.

A stopped failed/interrupted session retains its lock. The recovery script refuses active processes/listeners or queued test jobs, archives old evidence, requires deliberate printer clearance and RESET, then renames the old lock reversibly. It never cancels queued jobs, removes a queue, resets USB, resumes an old transfer or deletes captured content. Printer power cycling for a fresh test abandons incomplete memory; Samsung's [user manual, page9.4](https://fccid.io/A3LSCX4200/User-Manual/Users-Manual-1-610977.pdf) says a job interrupted by power loss must be submitted anew.

## Acceptance evidence

| Area | Local evidence | Target evidence |
|---|---|---|
| Ordinary multipage/repeated printing | Existing regression and full pixel decoding pass | 0.6.0 two complete two-page jobs printed correctly |
| Same pending write resumes without replay | Real private pipe retains one pending request beyond an accelerated old deadline and receives exact bytes | User confirmed0.7second job continued after empty tray refill without resubmission; both jobs fully acknowledged with0replayed requests |
| Cancellation/disconnect/hard deadline | Private-pipe and admission tests stop with no replay | Target unplug/cancellation remains later |
| Paper state/UI | Injected status masks; actual child progress-to-IPP/message/refill/resume simulation | Refill/resume proved; reports recorded0explicit paper-empty wait milliseconds, so device-specific paper-empty detection remains unproved |
| Idle stop/restart | Actual framework/test-child shutdown clears lock and restarts | Target CLEAN_SHUTDOWN and absent lock proved; subsequent restart remains to be observed |
| Failed-session restart prevention | Actual child missing-device/partial-uncertain/cancel cases retain lock and refuse restart | 0.6paper-out guard observed on target |
| Deliberate recovery | Isolated recovery tests preserve evidence and reject active/racing/canceled reset | New helper not yet exercised on target |

The framework can take around30seconds to exit when idle; instructions allow up to a minute. No background installer, automatic reconnect/replay, broader release-hardening or public publication is included in this milestone. Keep previous successful binaries as baselines.
