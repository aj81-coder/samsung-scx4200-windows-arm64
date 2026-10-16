# Samsung SCX-4200 on Windows 11 ARM64 (Snapdragon)

Print to a USB-connected **Samsung SCX-4200** from ordinary Windows applications
on an ARM64 laptop. This is an independent community **driver alternative** for
people whose legacy printer setup does not work on Windows on ARM.

Windows uses its built-in Microsoft IPP Class Driver. A small native background
app receives the local job, converts its pages to the SCX-4200's printer language
and sends the result over USB. Normal printing needs no WSL, second computer or
internet service. The app starts when you sign in.

**Community preview 0.12.1 is being prepared; no public download is published
yet.** The earlier 0.12.0 print path printed a complete three-page document on a
Samsung Galaxy Book4 Edge. Version 0.12.1 keeps those printing binaries unchanged
and adds a printer tray icon and housekeeping. Its host/helper have device-free
Windows tests; observation of the updated host on the ARM64 laptop is pending.

## I want to print with my SCX-4200

The prepared ARM64 package includes an installer, matching source and full
instructions. When the reviewed release is published, use its ARM64 ZIP rather
than GitHub's automatic source-code download. A direct release link will be
added here after the repository and release exist.

- [Complete installation and printing guide](USER-GUIDE.md)
- [Short installation and upgrade instructions](START-HERE.txt)
- [Troubleshooting and reporting a problem](SUPPORT.md)
- [Release notes](RELEASE-NOTES.md) and [what has actually been tested](VALIDATION.md)

Supported output is **A4, monochrome, 300 dpi, single-sided, one copy**. There is
no artificial document page-count or upload-size cap; disk space, processing
time and format bounds still apply. Scanning, duplex, 600 dpi and network printer
sharing are outside this preview. Fresh queue creation/removal is implemented
but remains physically unverified. Existing Capture Test queues are preserved.

The package is unsigned. It is not an official Samsung, HP or Microsoft driver.
Read the guide before installation and review diagnostics before sharing them.

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
