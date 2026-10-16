# SPDX-License-Identifier: Apache-2.0
# Device-free test executables only. Never copy these into the user package.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache/zig-local'
$out=Join-Path $root 'build/reliable/test-tools'
$handoff=Join-Path $root 'build/reliable-bridge'
New-Item -ItemType Directory -Force $out,$handoff | Out-Null
& $zig cc -target x86_64-windows-gnu -std=c11 -O1 -Wall -Wextra -Werror -municode (Join-Path $PSScriptRoot 'test-sender-stub.c') -lbcrypt -o (Join-Path $out 'SCX4200-Test-Sender.exe')
if($LASTEXITCODE -ne 0){throw 'Sender stub build failed'}
& $zig cc -target x86_64-windows-gnu -std=c11 -O1 -Wall -Wextra -Werror -municode (Join-Path $PSScriptRoot 'test-renderer-stub.c') -o (Join-Path $out 'renderer-stub.exe')
if($LASTEXITCODE -ne 0){throw 'Renderer stub build failed'}
& $zig cc -target x86_64-windows-gnu -std=c11 -O1 -Wall -Wextra -Werror -municode (Join-Path $PSScriptRoot 'test-sender-handoff.c') -o (Join-Path $handoff 'test-sender-handoff.exe')
if($LASTEXITCODE -ne 0){throw 'Sender admission harness build failed'}
& (Join-Path $PSScriptRoot 'build-bridge.ps1') -Architecture x64 -TestSender
