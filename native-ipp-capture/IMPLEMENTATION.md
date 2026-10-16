# Native IPP capture milestone

Status, 12 October 2026: native capture implemented and built for x64/ARM64. Eight local x64 HTTP/IPP and pixel/error checks pass. Target handoff: `dist/SCX4200-IPP-Capture-0.3.0-arm64.zip`. Windows queue acceptance and ARM64 execution remain pending. The initial planning notes below are retained as design context; see VALIDATION.md for current evidence.

## Destination and component boundary

Windows Print dialog -> Microsoft IPP queue -> local native IPP application -> standalone raster-to-QPDL renderer -> native USB sender -> SCX-4200.

Keep the already physically verified fixed-page sender as an unchanged regression baseline. The next handoff stops at saving a Windows-generated document: it must not open USB devices or send printer data.

PAPPL is the preferred HTTP/IPP framework. Do not implement a replacement production IPP stack just to avoid its dependency build. Run the initial capture application in the foreground; service installation, automatic startup and recovery come later.

The inspected PAPPL source is Apache-2.0. The pinned SpliX source explicitly says GPL version 2, without an 'or later' grant. Do not directly combine their code in one distributable executable. Investigate a separately usable GPL renderer taking standard raster files and producing QPDL files, with no PAPPL linkage. Process separation alone is not a blanket licensing conclusion; assess the actual interface and distribution before public release.

## Dependency findings

PAPPL v1.4.10 was downloaded and inspected as a compatibility baseline, not as the latest release. Its Windows project is `vcnet/libpappl1.vcxproj`, with x64 MSVC v142 configurations only. A Zig/MinGW ARM64 build requires explicit source/configuration adaptation; upstream Windows support is not evidence of ARM64 build success.

Its Windows package list references libcups2 2.4.11.1, LibreSSL 3.7.3.0, libjpeg-turbo 2.0.4.3, libpng 1.6.30 and zlib 1.2.11. These are historical upstream build references, not approved final dependency versions. Record and review the actual selected sources separately.

The framework contains Windows socket, threading, time and status adaptations. JPEG/PNG paths have configuration guards; their exclusion is a build experiment, not yet verified. Keep PWG raster support. Inspect CUPS and TLS requirements before promising a TLS-free build. No libusb backend is needed for this capture milestone or for the proven USBPRINT transport.

The next source download (CUPS 2.4.11 for matching-build investigation) was not executed: automatic approval review failed with HTTP 429 / exceeded retry limit. Do not count that source as acquired or its build as attempted.

## Work units and acceptance checks

| Unit | Required evidence | State |
|---|---|---|
| Framework audit | Inspect actual Windows project, config, source licence and dependency pins | Complete |
| Dependency port | Reproducible source build on x64 and ARM64, exact hashes and licences recorded | Pending; CUPS download interrupted |
| Capture application | Explicit loopback listener; named capture printer; retained document and metadata | Pending |
| Local verification | Real IPP requests and raster fixtures; malformed/truncated input; cancellation; disk/size failures | Pending |
| Windows queue handoff | Reversible dedicated queue setup/removal and native ARM64 ZIP | Pending |
| Target acceptance | Normal application sends a document; captured format, dimensions, resolution and page count established | Pending |
| Live renderer integration | Encode captured pages at runtime, compare decoded pixels, then controlled physical print | Later milestone |

## Capture requirements

- Bind explicitly to loopback, initially on port 8631. Confirm the bound addresses; no wildcard listener, discovery, firewall rule or remote access is needed.
- Advertise only formats and options actually accepted. Start with monochrome A4 and 300dpi. Inspect Windows' negotiated document format rather than assuming it.
- Use framework HTTP/IPP parsing, job identifiers, cancellation and error responses. Retain received raster bytes before any transformation where the API permits it; establish whether the framework transforms a format before calling the chosen callback.
- Use a fresh capture directory per run and generated filenames. Do not use document titles as filesystem paths. Preserve existing captures.
- Set explicit per-document and total-spool bounds before accepting jobs. Test limit handling and cleanup; a check only after receipt is insufficient.
- Record architecture, application version, MIME type, received byte count, hash and job outcome. Content stays local. Do not include document contents in the diagnostic JSON.
- Label the queue 'SCX-4200 Capture Test'. A completed capture job means file receipt, never proof of physical output. Provide clear on-screen wording.
- Do not install a service or change the default printer. Queue scripts must refuse to replace an existing unrelated queue and remove only the queue they created.
- Final handoff instructions must be tested, with checksums and source included. Do not ask the user to run an unbuilt prototype.

## Sources

- https://github.com/michaelrsweet/pappl/tree/v1.4.10/vcnet
- https://github.com/michaelrsweet/pappl/blob/v1.4.10/LICENSE
- https://www.pwg.org/ipp/ippguide.html
- https://www.apache.org/licenses/GPL-compatibility.html
- Local pinned SpliX `src/qpdl.cpp` copyright header and `COPYING`.
