# General release readiness — maintainer checklist

General Preview 0.12.1, 15 October 2026. No GitHub repository or release has been created. See [VALIDATION.md](VALIDATION.md) for evidence and its limits.

This update adds automatic housekeeping across restarts and a recognisable stock Windows printer tray icon. The engine, sender, renderer and document-format handling remain the accepted 0.12.0 versions. Existing limits remain A4, monochrome, 300 dpi, one copy and single-sided printing. There is no fixed document page-count or upload-size policy.

## Completed baseline acceptance

- Streaming sender regression, including a 25-page bundle larger than 50 MiB, short writes, malformed input, cancellation and no replay.
- Ten engine test groups, including 257 pages, bounded measured engine memory, gzip/chunked upload beyond 32 MiB, repeated jobs and failure/cancellation boundaries.
- Four host integration groups, framework disk/overflow guards, fifteen retention cases and actual isolated readonly cleanup tests.
- Twenty-one mocked app setup groups, seventeen queue setup groups and thirty-six tray control groups.
- Supplied 0.11.1 diagnostics correlated successful ARM64 jobs before/after reboot.
- User confirmed a correct three-page print on 0.12.0; its diagnostics showed no errors or retries.
- The 0.12.0 clean one-command source build passed for both architectures with architecture, import and code/data section correspondence; whole-file bit reproducibility was not claimed.

## Completed 0.12.1 checks

- Updated host fixture-helper suite: eighteen cases passed.
- Windows PowerShell 5.1 regressions: thirty-seven control groups and twenty-one app setup groups passed.
- Final helper filesystem suite: twenty-four Windows PowerShell 5.1 groups passed.
- Focused recovery suite: seven Windows PowerShell 5.1 checks passed, including sharing failures, interrupted cleanup, orphan/corrupt journals and unrelated host-log preservation.
- Final production-host/actual-helper integration: two cases passed using a fake engine. Exactly two of twelve eligible clean sessions were pruned before engine start; Quit was clean; missing receipt prevented cleanup and engine start.
- Clean one-command 0.12.1 source build passed for both architectures. All ten runtime binaries matched the tested/staged builds in architecture, imports and code/data sections; only `.buildid` sections differed. Whole-file bit reproducibility is not claimed.

## Release checks and remaining decisions

| Gate | Required action |
| --- | --- |
| Housekeeping validation | Twenty-four filesystem groups and seven focused recovery cases passed with the final helper. Preserve these results in the final package audit; do not substitute tests of an earlier helper. |
| Host and integration | Complete: fixture-helper lifecycle, final production-host/actual-helper integration, setup/control regressions and both-architecture builds passed without USB. |
| Final artifact audit | Passed: 52 independent checks, no findings. Runtime/source ZIPs and checksums are prepared; source, notices, privacy exclusions and unchanged print components are verified. See VALIDATION.md for archive hashes. |
| Fresh queue setup/removal evidence | Mocked tests passed; actual Windows creation/removal remains unverified and must be disclosed. Obtain real acceptance before claiming it physically tested. Keep the current user's working queue. |
| Publication | Present final binary/source artifacts and public text to the owner and obtain explicit publication approval. Set real repository/releases links only after authorization. |

The update route is finish printing, resolve any recovery, choose Quit, uninstall the old app and install the new package, retaining data and the existing queue. Stop printing alone leaves the tray app running and does not permit uninstall. There is no in-place updater. Explicit REMOVE-PRINTER uses the extracted package receipt only for a queue the package created.

Housekeeping keeps ten recent eligible clean sessions across starts and twenty successful Cancel/Diagnostics reports. Failed/uncertain/unknown state, all recovery reports, recovery backups and saved diagnostic ZIPs remain. This does not impose a total storage cap. Unknown layout and links preserve the containing session. No full data-root recursive deletion is permitted.

Security reporting uses GitHub private reporting only if enabled; otherwise readers can request a private channel without technical exploit details. Do not invent an email or claim the private-report button exists before configuring it.

There is no requirement to wait weeks for routine-use feedback or repeat a physical print series for this housekeeping/icon update. Keep old verified packages unchanged.
