# Build the matching source

**General Preview 0.12.1 candidate.** The wrapper builds the pinned dependencies and baseline background components, then the general framework, streaming sender, updated printer-icon host and disk-backed engine. The 0.12.0 baseline passed a clean build for both architectures with architecture, import and code/data section correspondence. The 0.12.1 clean one-command build also passed for both architectures. All ten runtime binaries matched the tested/staged builds in architecture, imports and code/data sections; their only section differences were `.buildid`. Whole-file bit reproducibility is not claimed. A binary release must ship the matching source archive.

## Prerequisites

- Windows x64 development host and PowerShell 7.
- [Official Zig 0.15.2 Windows x64 archive](https://ziglang.org/download/0.15.2/zig-x86_64-windows-0.15.2.zip) extracted to `.tools/zig-x86_64-windows-0.15.2` under the source tree. The audited archive SHA-256 is `3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c`. Verify the hash before using the compiler.
- The matching source package with pinned CUPS, PAPPL, zlib and SpliX archives. Its `native-preview/REBUILDING-0.10.1.txt` records their hashes and the underlying component recipe.
- Python, Pillow and NumPy for the relevant development tests. They are not required on a laptop simply using the printer.

From a fresh extracted source tree in PowerShell 7:

```powershell
./native-general/rebuild.ps1 -Architecture both
```

General outputs are under `build/general/ARCH`; dependency and historical background outputs remain separate. `-Architecture arm64` or `x64` selects the engine/framework target. The sender recipe currently compiles both architectures even when the wrapper selects one. Compilation does not create a Windows printer or send a job. The wrapper uses the established background recipe for pinned dependencies, then calls `native-general/build-host.ps1` before building the general engine. The updated host is built under `build/general-host-preview/ARCH` and copied into `build/general/ARCH`; general framework and streaming sender outputs remain separate from historical background outputs.

For a deliberate repeat using already extracted upstream sources, add `-UseExistingSources`. Use a fresh extraction for clean-source verification. Do not run this build wrapper on the target merely to install or print; use INSTALL.cmd from the ARM64 binary package.

Do not use an old cached output as evidence that the fresh source builds. Verify archive pins before extraction and retain build reports. Code/section correspondence and byte-for-byte whole-file reproducibility are distinct claims; build identifiers, paths and metadata can change hashes.

## Device-free verification

The engine/integration tests require a deliberately compiled test engine and fake sender. Host tests use a harmless test child. Setup and controls tests mock registration, queue and UI operations. Run tray lifecycle tests sequentially because only one app instance is allowed.

Never replace a missing fake sender with production USB. Tests must fail closed. Independent renderer pixel and packet validation, malformed input, cancellation, disk limits and uncertain-transfer protection remain necessary when the general engine changes document handling.

After building both production architectures, prepare and run the device-free suites from PowerShell 7 at the source root:

```powershell
./native-async-bridge/build-test-tools.ps1 -RendererRoot build/margin-fix
./native-general/build-test-tools.ps1
./native-general/build-engine.ps1 -Architecture x64 -TestSender
python ./native-general/test-stream-sender.py
python ./native-general/test-engine.py
python ./native-general/test-integration.py
python ./native-general/test-host.py
python ./native-general/test-housekeeping-host.py
./native-general/test-framework.ps1
./native-general/test-setup.ps1
./native-general/test-queue-setup.ps1
./native-general/test-controls.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./native-general/test-housekeeping.ps1
```

`test-integration.py` is a baseline regression of the old host with the unchanged engine and fake sender; it does not establish the new host lifecycle. `test-host.py` exercises the updated host against a fixture helper, while `test-housekeeping-host.py` uses the actual housekeeping wrapper with isolated data and a fake engine.

The first command supplies inherited harmless sender/renderer fixtures; the general test-tools command builds the new fake sender and sender-stream harness. The `-TestSender` engine has a compile-time fake-child boundary. Keep these tests sequential: they intentionally share loopback port 8631 and lifecycle identities. Do not run them while another project bridge is active. Some local sandbox environments require permission for compiler caches and loopback connections; this is not a reason to bypass the test sender.

The housekeeping suite uses synthetic folders and mocked state to check cross-restart clean-session retention, preservation of failed or uncertain sessions, corrupt metadata, links, readonly files, unknown files and control-report history. It must not touch an installed app data folder. Cleanup admission bounds are 256 residual files per eligible session, 4 MiB per residual file and 16 MiB aggregate residual data. Larger residual sessions are preserved; these bounds do not reject printing. The wrapper uses direct .NET SHA-256 so tests must also cover the restricted helper environment rather than depending on module autoloading.

Measured results are in [VALIDATION.md](VALIDATION.md). ARM64 binaries built on x64 have not been executed merely by cross-compilation; target acceptance remains separate. Framework tests execute actual extracted fragments with mocked free-space values and real isolated file cleanup. No command above authorizes actual USB printing or real queue/startup registration.
