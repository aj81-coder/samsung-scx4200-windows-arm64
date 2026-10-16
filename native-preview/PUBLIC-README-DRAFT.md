# Samsung SCX-4200 on Windows ARM64 — foreground preview

This project provides a local IPP-to-USB bridge for an SCX-4200 connected to
a Windows ARM64 laptop. Windows' Microsoft IPP Class Driver sends page rasters
to a native foreground application, a separate SpliX-derived renderer encodes
them, and a native USBPRINT sender communicates with the printer. Normal
printing does not require WSL, another computer, or an internet service.

This is a draft for a future public repository. No public release has been
published. The current preview is based on testing with one Snapdragon laptop
and one SCX-4200, and is not a general compatibility claim.

## Current scope

- Monochrome A4 at300dpi, one-sided, one copy.
- Up to10pages per document and20pages per foreground session.
- Explicit cancellation and deliberate recovery; interrupted jobs are not
  automatically replayed.
- Previously refused top/left margin content fits slightly smaller. Pages
  that already fit retain their original output.

Scanning,600dpi, duplex, multiple copies, background service operation, and
sleep during a print job remain outside the verified scope. Use the bridge's
explicit cancel command; graphical Windows queue cancellation is unverified.

## Using a preview

Read START-HERE.txt in the package. Keep the bridge window open to print.
Existing test users retain their installed queue. New first-install/removal
scripts are experimental and require a separate acceptance check before they
are promoted as a general installation route. They do not adopt existing
queues for later removal.

Print ordinary documents for feedback. When reporting a problem, include the
application/document type, expected versus actual output, the error message,
and whether paper ran out or USB was disconnected. Default result collections
exclude page captures, but logs can contain document names or paths. Review
reports before sharing them. Never attach private captured documents to a
public issue without deliberately reviewing their contents.

## Source and component boundaries

The PAPPL/CUPS bridge and the SpliX-derived GPL2 renderer are separate
executables communicating through files. Licence and notice files are included
for each distributed dependency. The renderer's corresponding source, pinned
upstream archives, and build instructions accompany preview packages.

REBUILDING.txt records the component versions, build layout and test tools.
Private target captures and machine-specific evidence are not public fixtures.
Optional comparisons that require those artifacts report SKIP when absent;
generated synthetic tests can run independently. An isolated source rebuild
now succeeds for x64/ARM64 with the corrected build recipe and PowerShell7.
All code/data sections match the tested binaries; build metadata differs, so
byte-for-byte reproducibility is not claimed. Original code has Apache-2.0
declarations; the renderer and existing GPL verification files retain GPL2.
Read LICENSING.md, PROVENANCE.md and COMPONENT-LICENCES-DRAFT.md for the
component boundaries. The revised source candidate includes runtime notices.
Internal audit/one-off packaging tools are omitted from this source candidate;
the one-command source rebuild and synthetic test tools are included.

## Before publication

Complete fresh install/remove acceptance, verify source and binary provenance,
review attribution/licence files and supported behavior, and prepare a concrete
release for the project owner's approval. Do not publish private evidence or
historical machine-specific recovery scripts as general tools.
