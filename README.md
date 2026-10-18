# Samsung SCX-4200 on Windows 11 ARM64 (Snapdragon)

The Samsung SCX-4200's legacy Windows driver does not support **Windows 11 on ARM64**. This project provides a solution for **printing** to the USB-connected printer from ordinary Windows applications on ARM64 / Snapdragon laptops.

**Install once, then print normally.** A small native app runs in the background and starts when you sign in. Windows uses its built-in Microsoft IPP Class Driver; the app converts jobs into the printer's language and sends them over USB. Everyday printing needs no console window, WSL, second computer or internet service.

**Community preview 0.12.1:** basic printing functions have been tested, and the app is now in regular household use on a Samsung Galaxy Book4 Edge. On 18 October 2026 the owner reported installing and testing this version, and another household user printed a document normally without the owner's assistance. See [validation](VALIDATION.md) for the evidence and its limits.

## Download and install

**[Download the Windows ARM64 app ZIP](https://github.com/aj81-coder/samsung-scx4200-windows-arm64/releases/download/v0.12.1/SCX4200-General-Preview-0.12.1-arm64.zip)** · [Release page and checksums](https://github.com/aj81-coder/samsung-scx4200-windows-arm64/releases/tag/v0.12.1)

1. Extract the ZIP into a folder on the laptop's internal drive.
2. Turn on the SCX-4200, connect USB and load A4 paper.
3. Double-click **INSTALL.cmd** as your usual Windows user and wait for **Installed**. Follow the [installation guide](USER-GUIDE.md) if Windows needs administrator permission to create the printer.
4. In your normal application's Print dialog, select **Samsung SCX-4200** (or an existing **SCX-4200 Capture Test** queue), A4, one copy and single-sided printing. Print once.

The app then starts when you sign in. Its printer icon beside the clock provides status, cancellation and recovery controls. Keep the extracted package folder for its instructions and any queue-removal receipt.

- [Complete installation and printing guide](USER-GUIDE.md)
- [Short installation and upgrade instructions](START-HERE.txt)
- [Troubleshooting and reporting a problem](SUPPORT.md)
- [Release notes](RELEASE-NOTES.md) and [what has actually been tested](VALIDATION.md)

Supported output is **A4, monochrome, 300 dpi, single-sided, one copy**. There is no artificial document page-count or upload-size cap; disk space, processing time and format bounds still apply. Keep the laptop awake while printing. Fresh queue creation/removal is implemented but remains physically unverified; existing working queues are preserved.

**Scanner functionality has not been addressed.** It is being considered for future investigation, with no promised delivery date. Duplex, 600 dpi and network printer sharing are outside this preview.

This is an unsigned, independent community project, not an official Samsung, HP, Microsoft or OpenAI product. Review the instructions before installation and diagnostics before sharing them.

## Developed with AI

This began as a personal solution and is shared for wider benefit. It was developed using OpenAI's ChatGPT and Codex (often called “vibe coding”). AI made substantial design, implementation, debugging and test-planning decisions, wrote the project code, and generated the notes and documentation. The human owner set the goal, supplied feedback, made project and publication decisions, and carried out physical printer tests with another household user.

This is not a claim of an independent human expert code audit. Existing upstream projects and their authors remain credited under their own licences. See [development transparency](AI-PROVENANCE.md) for the distinction between AI work, automated checks and human observations.

## Will this help with another old printer on Windows ARM?

The architecture may help developers working on other legacy USB printers.
The downloadable printer-specific implementation is currently for the SCX-4200;
compatibility with other models is not established.

The reusable pattern is:

**Windows application -> built-in IPP driver -> local native bridge ->
model-specific renderer and USB transport -> printer**

See [adapting the approach for another printer](ADAPTING-OTHER-PRINTERS.md) for
which components can be reused and which need model-specific implementation and
testing. Changing a USB device ID alone does not establish compatibility.

## Common questions

**Is this a Samsung SCX-4200 ARM64 driver?**
It solves that printing problem using Windows' built-in IPP driver plus a native
bridge. It does not install an old x64 Samsung driver or patch Windows.

**Does it work on Snapdragon laptops or a Surface?**
The target is Windows 11 ARM64. The physically tested computer is the Galaxy
Book4 Edge. Other ARM64 laptops, including Surface models, are not automatically
claimed tested merely because they use the same architecture.

**Can it print from a browser, Word or a PDF viewer?**
The queue is intended for normal Windows application printing. Web/JPEG and
multipage output have target evidence; compatibility with every application and
document is not claimed. Please report reproducible problems with a harmless
sample, not a confidential document.

## Source and contributions

[Build instructions](BUILDING.md), [contribution guidance](CONTRIBUTING.md) and
[security reporting](SECURITY.md) are included. Exact matching release source is
distributed in the release's source ZIP, with its own checksum inventory. This
repository can receive later documentation and development changes.

Original project code is Apache-2.0. The separate SpliX-derived renderer and
existing GPL verification files retain their GPL terms; third-party components
retain their notices. Read the [licence boundaries](LICENSING.md) before reusing
components. This is not an Apache-only bundle.
