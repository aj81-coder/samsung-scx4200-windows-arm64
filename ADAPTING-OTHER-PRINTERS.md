# Adapting a legacy USB printer to Windows 11 ARM64

This project demonstrates one approach using a Samsung SCX-4200. It does not
provide a universal driver or establish compatibility with other printers.
The SCX-4200-specific package should not be presented as support for another
model without new evidence.

## The compatibility problem

Windows applications and printer drivers have different compatibility
requirements. Microsoft explains that peripherals need a built-in compatible
driver or an ARM64 driver from the hardware developer in its
[Windows Arm-based PC FAQ](https://support.microsoft.com/en-au/windows/experience/platform-variants/windows-arm-based-pcs-faq).
Before developing a bridge, check the manufacturer's guidance and Windows'
normal Add printer path. This project is useful where a supported ordinary
installation route is unavailable for the particular legacy device.

## The pattern used here

The Windows Microsoft IPP Class Driver produces page data for a local IPP
endpoint. The native bridge accepts a complete job to disk, validates and
renders each page, then passes a fully validated document to a separate USB
sender. A per-user host provides startup, status, cancellation and recovery.

This separates the Windows-facing queue from the legacy printer language. It
also makes it possible to test raster handling and failure behavior without
sending data to a physical printer.

## What may be reused

| Component | Existing location | Adaptation boundary |
| --- | --- | --- |
| Tray app and lifecycle | native-general/host.c | Per-user startup, controls, stop/logoff behavior; update names and ownership deliberately. |
| IPP/raster pipeline | native-general/bridge.c and build-framework.ps1 | Disk spooling, page iteration and resource guards; validate the formats and geometry required by the target. |
| Model renderer | native-render-print/ | SpliX-derived SCX-4200 output; another printer may need different commands or a completely different renderer. |
| USB sender | native-general/sender.c | Device identity, service/interface requirements, status protocol and byte delivery are model-specific. |
| Installation and recovery | native-general/setup.ps1, queue-setup.ps1, controls.ps1 | Reversible ownership, queue identity and explicit recovery; retain safeguards rather than bypassing refusals. |
| Housekeeping | native-general/housekeeping.ps1 | Recognizes this project's exact successful-session schemas. A renamed fork needs deliberate schema/provenance changes. |

## Establish a new model deliberately

1. Record the exact printer model, USB identity and available documented or
   open-source protocol implementation. Confirm the applicable source licences.
2. Generate and independently inspect output offline. Check page geometry,
   framing, checksums and every decoded pixel before physical output.
3. Implement identity/status handling for that printer. Do not merely widen the
   SCX-4200 sender's accepted device IDs.
4. Test malformed input, cancellation, disconnects and uncertain writes using
   fake transport. Preserve the rule that uncertain output is not automatically
   replayed.
5. Use a controlled physical test with a harmless page, then ordinary queue
   printing and relevant recovery checks. Record actual sheets separately from
   successful USB acknowledgements.
6. Publish the exact model, limitations, tested hardware and matching source.
   Keep unsuccessful or untested models clearly separate from compatibility
   claims.

See [BUILDING.md](BUILDING.md), [VALIDATION.md](VALIDATION.md) and
[LICENSING.md](LICENSING.md). Original Apache-2.0 code does not relicense the GPL
renderer or verification tools. A useful contribution is a documented adapter
with independent tests and clear evidence; a device-ID substitution is not a
complete driver port.
