# Background preview 0.11.1 target observation — 15 October 2026

The user reports that the corrected version installed and printed a one-page
document. After restarting the computer, another document was printed. Both
were single-page webpage documents containing JPEGs. This follows the requested
install/ordinary-print/idle-restart/ordinary-print handoff on the Samsung laptop.

Accepted evidence: installation succeeded and the reported before/after-restart
printing workflow worked. The subsequently supplied diagnostics archive was
independently checked: SHA256
a75a06403fd51d7d76e9479750ee22b01a5ebc3886717c152e6750ee186dbce6,
18 files, two native ARM64 non-mock sessions, each with one completed page.
Their senders acknowledged 123,109 and 138,601 bytes respectively, with no
uncertain delivery or automatic retry. Both host logs identify ARM64 background
operation without an arming prompt or bridge-stopped message. One session has
a clean shutdown and the other ends at JOB_COMPLETED. The unchanged executable
still reports its internal 0.11.0-background-dev version in the 0.11.1 package.
The user supplies physical-output and restart confirmation; a USB completion
report alone does not establish physical output or independently prove reboot.

The supplied release ZIP is SCX4200-Background-Preview-0.11.1-arm64.zip,
SHA256 5674f1a622ca8639c931b7e7e729955c691671d2554b4c07053ea95f3992d518.
Its frozen build validation describes target status before this later user
observation. Do not rewrite the released archive or claim a captured hash check.

No further test printing is needed merely to collect a Save diagnostics ZIP.
Ordinary-use feedback remains useful compatibility evidence. These two
single-page prints do not establish background multipage output, the new tray
cancellation/recovery controls, actual uninstall, fresh printer-queue setup,
mid-job sleep or wider hardware compatibility. Previous foreground multipage
and transport evidence remains separately recorded.

The existing scope remains monochrome A4 300dpi, simplex, one copy, up to ten
pages per document. No cumulative twenty-page session allowance. No public
repository or release has been created.
