# Current project source provenance

The owner approved Apache2.0 for genuinely original project code on14October2026.
The licence text is LICENSE-APACHE-2.0.txt. This map separates that grant from
existing GPL declarations and third-party source; it is not a new licence for
the whole mixed-component package.

| Current source | Evidence and treatment |
|---|---|
| `native-async-bridge/bridge.c` | Local Windows/PAPPL application lineage, with existing Apache2.0 declaration. No copied SpliX implementation identified in this file. |
| `native-reliable-bridge/sender.c` | Local transport/bundle/permit/cancellation implementation; the earlier sender README identifies it as original project code. Apache2.0 for that local source. |
| `native-print-test/usb_read_helpers.h` | Its implementation body occurs verbatim in the project's original `native-usb-probe/probe.c`. Probe validation records no copied macOS/SpliX code; documented Windows APIs/constants are reference material. Apache2.0 for the local implementation. |
| `native-render-print/job_validator.h` | Local scalar packet admission validator. It shares protocol formulas and checks with locally written GPL-labelled Python tests; it may share a local translation lineage. No copied third-party decoder was identified. Owner-approved Apache2.0 is applied to this local C implementation, without changing the GPL Python files or claiming it was proven written from scratch. |
| Original control/build/test scripts without an existing licence declaration | Local project orchestration, checks and generators, covered by the owner's Apache2.0 choice. Existing declarations take precedence. Generated modifications to Apache2 CUPS/PAPPL source retain their upstream headers/notices. |
| `native-render-print/render.cpp` and `reference-job/generate.cpp` | SpliX-based adapters, directly compiled with upstream SpliX sources. Existing GPL-2.0-only declarations preserved. |
| `native-render-print/verify-render.py`, `reference-job/fixture.py`, and other GPL-labelled verification files | Existing GPL-2.0-only declarations preserved, including explicit local derivative relationships. No blanket Apache replacement. |
| Pinned CUPS/PAPPL/zlib/SpliX and compiler runtimes | Third-party source and notices remain unchanged. Full component texts are retained with the source candidate. |

The provenance review compared47SpliX `src`, `include` and `COPYING` files
against the pinned archive with no differences. Upstream supplies0x0D encoders;
its decoder tools cover0x11/0x13, not the local validator's0x0D/0x0E. Matching
inverse packet formulas alone do not establish source copying.

There is no Git authoring history in the original workspace. The map records
the evidence available rather than asserting a conclusively reconstructed
authoring event for every local function. Any later evidence of third-party
material must be reflected in its component terms before distribution.

The comment-only declaration audit is kept privately in the project build
records. Frozen test archives, upstream source and working binaries are not
modified. No repository or release has been published.

## General previews 0.12.0 and 0.12.1

The original native-general bridge, streaming sender adaptations, controls,
setup and build/test orchestration retain the local Apache-2.0 application
lineage and per-file declarations. General framework patch generation modifies
pinned Apache-licensed PAPPL source while preserving upstream notices. The
separate SpliX-derived renderer and existing GPL-labelled verification files
retain their existing terms. General document handling does not relicense the
renderer or third-party dependencies. See VALIDATION.md for the public,
sanitized test record; private diagnostic files are not part of source release.

The 0.12.1 original housekeeping and printer-icon host changes retain Apache-2.0. The icon uses a stock Windows printer resource; no third-party icon image is bundled. These changes do not modify the separate renderer or its licence.
