# Validation record — General Preview 0.12.1

15 October 2026. This is a sanitized record: no private document content, printer identifiers, user account paths or captured print files are included. It distinguishes physical output from device-free tests and compilation.

## What has printed on the target

The user installed background preview 0.11.1 on a Samsung Galaxy Book4 Edge running Windows 11 ARM64 with a Samsung SCX-4200. A single-page web/JPEG document printed correctly, then another printed after restarting the laptop without manually starting the bridge. Its diagnostics corroborated the two jobs.

The user then installed General Preview 0.12.0 and reported that a three-page document printed correctly. The supplied diagnostics corroborated the three successful pages without errors or retries. This accepts the changed streaming document path on that target. Version 0.12.1 keeps the same engine, USB sender and renderer; it adds housekeeping and a printer tray icon. These changes do not require repeating the earlier physical print series. Fresh Windows queue creation/removal remains physically unverified.

Earlier development versions separately established multipage printing, repeated jobs, paper-refill continuation, explicit cancellation and deliberate recovery after interrupted transfers. Those historical checks inform the design; they do not replace a relevant target check after transport changes.

On 18 October 2026 the owner reported installing and testing version 0.12.1 on the target Samsung laptop. Another household user also printed a document normally without the owner's assistance. Basic printing is now in regular household use. This is human-reported installation and paper-output evidence; no new diagnostic ZIP, page count or fresh queue-creation/removal evidence was supplied with that report. It accepts observation of the updated host in ordinary use, not exhaustive housekeeping-path or compatibility testing.

## Device-free automated checks

All baseline 0.12.0 checks below passed on the Windows development host. No USB printer was accessed. Sender delivery tests use a harmless capture callback or private pipe; engine tests use a compile-time fake sender or explicit mock transport. Installer/control tests mock Windows queue, registration and user-interface operations.

| Area | Measured coverage |
| --- | --- |
| Streaming sender | Validated and streamed a 25-page, 52,436,937-byte bundle. Exact captured-output hash matched despite deliberately short writes. Rejected invalid hashes, truncation, count mismatch and malformed QPDL with correctly recalculated hashes. Exercised source writer denial, cancellation, failure without replay and inherited private-pipe pending-write handling. |
| General engine | Ten test groups passed, including 25-page and 257-page jobs, repeated jobs, cancellation during receive/conversion, asynchronous cancellation, uncertain-transfer refusal and malformed/truncated input. |
| Long-document resources | The 257-page case represented 2,235,221,520 decoded pixel bytes while measured peak engine working set was 10,625,024 bytes. At most one decoded PGM page was present; converted PGM pages were removed. This measurement describes that synthetic case, not every application or renderer process's peak memory. |
| Upload beyond the former limit | A 43,864,019-byte dense PWG document passed through gzip and chunked HTTP. This crosses the old 32 MiB decompressed-upload limit. |
| Host integration | Four lifecycle/integration groups passed with the unchanged native tray host, real IPP engine and fake USB child. |
| Framework policy | Actual generated upload-policy fragments admit 64 MiB in fixed 4 KiB chunks and reject low disk space, cancellation, disk-query failure and signed overflow. Complete-upload/commit/stalled-read guards remain. Fifteen retention/state cases and actual owned versus unrelated readonly-file cleanup checks passed. |
| App setup | Twenty-one mocked groups passed. These are not proof of physical ARM64 installation or real Windows printer registration. |
| Queue setup | Seventeen mocked groups passed, including exact ownership and refusal boundaries. Real new-user queue creation/removal remains pending. |
| Tray controls | Thirty-six device-free groups passed, including friendly and legacy queue receipt handling. |

## Version 0.12.1 checks

The updated host fixture-helper suite passed eighteen cases. Windows PowerShell 5.1 reruns passed thirty-seven control groups and twenty-one app setup groups. These check the new version at their stated scope, without actual USB or installed printer registration.

The final housekeeping helper passed twenty-four Windows PowerShell 5.1 filesystem groups. Seven focused Windows PowerShell 5.1 recovery checks also passed, including native job/session-directory sharing failures, interrupted payload deletion, orphan journals, corrupt proof and preservation of unrelated host logs. These are synthetic filesystem tests, without actual USB or user print history.

The final production-host/actual-housekeeping-helper integration suite passed two cases with a fake engine: exactly two of twelve eligible clean sessions were pruned before engine start, Quit completed cleanly, and a missing installation receipt allowed neither cleanup nor engine start. The clean source build passed for both architectures. Final package assembly and independent distribution audit also passed: 52 checks with no findings, covering ZIP integrity, manifests, exact matching release source, all five ARM64 binaries, unchanged accepted print components, upstream pins/notices, privacy exclusions and complete instructions. The four older baseline host integration groups above remain old-host regression evidence; they do not test the updated host.

The frozen ARM64 package SHA256 is `114f26d7275428bd8f4dd5aa601ab926592977ae2c83821739925009548725d9`; its matching source ZIP SHA256 is `20a0209bc3ea1362c797d3aa29b0c22e537c9a174d7e5e083f7e9c809d161777`. Repository documentation may receive later edits; the matching release source archive retains its own complete inventory. The release is available at https://github.com/aj81-coder/samsung-scx4200-windows-arm64/releases/tag/v0.12.1.

The required housekeeping coverage includes retaining ten eligible clean sessions across starts, exact successful-session/host-log mapping, failed/uncertain/active/unknown state preservation, nonempty spool directories, malformed metadata, links, readonly files, access failures and successful-report retention. All recovery reports, saved diagnostic ZIPs and recovery backups must remain intact. Resumable cleanup journals are preserved if their contents or recorded files are unknown or changed; resume must stay within the original verified clean-session scope. Tests use synthetic data, never a user's installed print history.

Cleanup admission is deliberately bounded: at most 256 eligible residual files, at most 4 MiB per residual file and at most 16 MiB aggregate residual data per candidate session. A session outside those cleanup bounds is preserved. These are housekeeping limits, not document or printing limits; they do not cause a large document to be refused. The final helper computes SHA-256 directly through .NET rather than relying on PowerShell module autoloading in the host environment.

## Evidence boundaries

The 0.12.0 clean one-command source build passed for both x64 and ARM64. Independent inspection found all ten runtime binaries matched the tested build's architecture, imports and code/data sections. Every binary differed in `.buildid`; whole-file bit reproducibility is not claimed. The 0.12.1 clean one-command build likewise passed with exit code zero for both architectures. All ten runtime binaries matched the tested/staged builds in architecture, imports and code/data sections; only `.buildid` sections differed. Final distribution integrity remains a separate package audit.

Fresh printer creation/removal remains an explicitly unverified path for this first community preview. Do not delete an existing user's working queue merely to manufacture a test. No weeks-long routine-use feedback period or new physical printing series is required for the housekeeping/icon update.

A successful test is evidence for its scenario. There is no claim of universal document compatibility, all Windows ARM64 hardware, physical completion based on a USB acknowledgement, scanning, duplex, 600 dpi, multi-copy printing or safe sleep during active output. No fixed page-count policy means no artificial ten-page gate; resource limits, format representation and finite disk space still apply. Housekeeping bounds eligible clean history, not total disk use when failures, unknown content or user-saved exports are preserved.

Public artifacts should carry final source and binary hashes. Build success, ARM64 cross-compilation, runtime behavior and byte-for-byte reproducibility are separate claims. See the release page for publication status. The 18 October user report is separate from the archived automated checks.
