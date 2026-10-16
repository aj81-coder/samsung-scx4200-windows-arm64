# General Preview 0.12.1

This community preview adds automatic housekeeping across app restarts and a
recognisable printer icon beside the Windows clock. The print engine, USB
sender, renderer and CUPS DLL remain byte-for-byte unchanged from 0.12.0, which
printed a complete three-page document on the target Windows 11 ARM64 laptop.

Housekeeping runs before each engine start. It retains ten recent eligible
clean sessions and twenty recent successful Cancel/Diagnostics control reports.
It removes older verified clean sessions and their proven associated host logs.
Active, interrupted, uncertain, malformed, linked, readonly and unknown data is
preserved. Interrupted cleanup uses a bounded, validated journal to resume
without treating an incomplete print job as disposable history. Saved diagnostic
ZIPs, recovery backups and recovery reports are not automatically removed.
These preservation rules mean there is no hard cap on total data-folder size.

The app remains responsive while maintenance runs. The engine starts only when
the helper completes and current startup/control locks permit it. Saved
diagnostics include the latest housekeeping summary.

The document page-count and upload-size policy caps removed in 0.12.0 stay
removed. Practical disk, processing-time, supported-page and protocol bounds
remain. Supported output is A4 monochrome 300 dpi, simplex, one copy. Scanning,
duplex, 600 dpi and network sharing are outside this preview's scope.

## Upgrade

Finish printing and complete any needed recovery. Choose **Quit**, not only
Stop printing, from the old tray app. Run UNINSTALL.cmd from the old package,
keep the existing printer queue, then extract this package onto the laptop's
internal drive and run INSTALL.cmd as your normal user. Read START-HERE.txt.
No additional physical print test series is required for this maintenance
update; ordinary-use feedback remains useful.

## Evidence and distribution

See [VALIDATION.md](VALIDATION.md) for measured tests, build correspondence and evidence limits.
The new host/helper have device-free Windows testing; ARM64 cross-compilation
does not establish that the updated host has run on the target laptop. Fresh
printer creation/removal remains physically unverified and is disclosed.

The package is unsigned. The complete matching source and component notices
accompany it. Original Apache-2.0 code, the separate GPL renderer and third-party
components retain their respective licence terms. No public upload is performed
by preparing these files.
