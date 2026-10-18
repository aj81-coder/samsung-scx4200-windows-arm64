# Samsung SCX-4200 printing on Windows 11 ARM64

The Samsung SCX-4200's legacy Windows driver does not support Windows 11 on ARM64. This independent community project provides a solution for USB printing from ordinary applications on Windows 11 ARM64 / Snapdragon laptops. It began as a personal solution and is shared here for wider benefit.

Install the app once, then select the printer in your application's normal Print dialog. The app runs in the background and starts when you sign in. Everyday printing needs no command window, WSL, second computer or internet service.

**Version 0.12.1 is a community preview.** It is unsigned and is not an official Samsung, HP or Microsoft product. Basic printing functions have been tested and the app is now in regular household use.

## Developed with AI

This began as a personal solution and is shared for wider benefit. It was developed using OpenAI's ChatGPT and Codex (often called “vibe coding”). AI made substantial design, implementation, debugging and test-planning decisions, wrote the project code, and generated the notes and documentation. The human owner set the goal, supplied feedback, made project and publication decisions, and carried out physical printer tests with another household user.

This is not a claim of an independent human expert code audit. Existing upstream projects and their authors remain credited under their own licences. See [development transparency](https://github.com/aj81-coder/samsung-scx4200-windows-arm64/blob/main/AI-PROVENANCE.md) for the distinction between AI work, automated checks and human observations.

## What it does

- Prints text, pictures and multipage documents to a USB-connected SCX-4200.
- Uses Windows' built-in Microsoft IPP Class Driver and a native ARM64 background app to convert and send the pages to the printer.
- Offers printer status, cancellation, recovery and diagnostics through a printer icon beside the Windows clock.
- Continues a waiting job after you refill an empty paper tray, unless the app has already reported a stopped or uncertain transfer.
- Cleans up successful temporary print data and limits eligible successful session history across restarts. Failed or uncertain data, recovery backups and exported diagnostic ZIPs are preserved.

Supported output is **A4, monochrome, 300 dpi, single-sided, one copy**. There is no artificial document page-count or upload-size limit; available disk space, processing time and format bounds still apply. Scanner functionality has not been addressed; future investigation is being considered without a promised delivery date. Duplex, 600 dpi, network printer sharing and printing before Windows sign-in are outside this preview. Support for other printer models is not established.

## Download the right file

Use the **Assets** list below:

| File | Purpose |
| --- | --- |
| **SCX4200-General-Preview-0.12.1-arm64.zip** | The ready-to-install app for Windows 11 ARM64. Start here. |
| SCX4200-General-Preview-0.12.1-source.zip | Complete matching release source and pinned upstream source archives, for developers. |
| SCX4200-General-Preview-0.12.1-SHA256SUMS.txt | SHA-256 checksums for the two ZIPs. |

GitHub's automatic **Source code** downloads are repository snapshots, not the ready-to-install app. The separately attached source ZIP is the exact matching release-source bundle.

## First installation

You need a Windows 11 ARM64 computer, the Samsung SCX-4200 connected by USB, A4 paper and space on the laptop's internal drive.

1. Download the **arm64.zip** above. Right-click it and choose **Extract All** into a new folder on the laptop's internal drive. Run from the extracted folder, not inside the ZIP or from a USB stick.
2. Turn on the printer, connect USB and load A4 paper. Close any older SCX-4200 bridge before installation.
3. Double-click **INSTALL.cmd** as your usual Windows user. Wait for **Installed**. Setup uses a supported existing printer queue or attempts to create **Samsung SCX-4200**.
4. Only if setup reports permission denied creating the printer: right-click **ADD-PRINTER.cmd**, choose **Run as administrator**, then run **INSTALL.cmd** again as your usual user.
5. Find the printer icon beside the clock; check the hidden-icons arrow if needed. Open a short document, choose **Print**, select **Samsung SCX-4200** (or the retained **SCX-4200 Capture Test** queue), A4, one copy and single-sided. Click **Print once**, then check the paper.
6. Keep the extracted package folder for its instructions and any setup receipt needed for optional printer-queue removal. Afterwards the app starts automatically when you sign in. If you deliberately quit it, open **Samsung SCX-4200** from Start.

The [complete user guide](https://github.com/aj81-coder/samsung-scx4200-windows-arm64/blob/main/USER-GUIDE.md) covers installation, tray controls, troubleshooting, updating and removal. It is also included in the download as **USER-GUIDE.txt**. The frozen download's short START-HERE file begins with upgrade instructions; new users should use its **FIRST INSTALLATION** section or the steps above. Downloaded archive documentation reflects the earlier candidate preparation; this release page and repository documentation contain the current status, AI disclosure and use feedback. The tested software and matching source archives have been kept unchanged.

## If a job is interrupted

Keep the laptop awake while printing. If paper runs out, refill the tray and let the existing job continue; do not submit another copy. If the app reports a stopped or uncertain job, use the user guide's recovery instructions. Cancellation cannot erase data already buffered inside the printer. Do not delete session locks or spool folders to force a restart.

For help, follow [SUPPORT.md](https://github.com/aj81-coder/samsung-scx4200-windows-arm64/blob/main/SUPPORT.md). Review diagnostics before sharing: failed-job data can contain document content.

## What has been tested

The printing path has physical evidence on a Samsung Galaxy Book4 Edge running Windows 11 ARM64, including correct multipage output and recovery checks. Version 0.12.0 printed a complete three-page document; this package keeps its print engine, renderer, USB sender and CUPS DLL byte-for-byte unchanged.

On 18 October 2026 the owner reported installing and testing 0.12.1 on the Samsung laptop; another household user printed a document normally without the owner's assistance. The app is now in regular household use. This is human-reported evidence, with no new diagnostics attached to that report. The background host and housekeeping helper also have automated Windows tests and ARM64 builds. Fresh printer-queue creation/removal is implemented but remains physically unverified. Existing-queue printing does not establish those fresh-install results or compatibility with every ARM64 laptop and application. See [validation and evidence limits](https://github.com/aj81-coder/samsung-scx4200-windows-arm64/blob/main/VALIDATION.md).

## Updating an earlier preview

Finish printing and complete recovery if needed. Choose **Quit** from the old tray app, wait for it to close, then run **UNINSTALL.cmd** from the old extracted package. Keep the existing printer queue. Extract this version to a new folder on the internal drive and run **INSTALL.cmd** as your usual user. Never run an old bridge alongside the installed app.

For existing users, 0.12.1 adds the printer-shaped tray icon and automatic housekeeping across app restarts. Eligible successful history retains ten clean sessions and twenty successful Cancel/Diagnostics reports. Preserved failure and recovery data means total storage has no unconditional size cap.

## Source, reuse and contributions

The source, build instructions and component notices are included. Original project code is Apache-2.0; the separate SpliX-derived renderer and existing GPL files retain their GPL terms, and third-party components retain their licences. Read the [licence boundaries](https://github.com/aj81-coder/samsung-scx4200-windows-arm64/blob/main/LICENSING.md) before reuse.

Developers interested in other older USB printers can read [adapting the approach](https://github.com/aj81-coder/samsung-scx4200-windows-arm64/blob/main/ADAPTING-OTHER-PRINTERS.md). This is a printer-specific implementation, not a universal legacy-printer driver.
