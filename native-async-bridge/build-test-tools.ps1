# SPDX-License-Identifier: Apache-2.0
# Device-free executables. Production bridge cannot select this sender.
param([string]$RendererRoot='build/render-print')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$baseline=Join-Path $root 'native-reliable-bridge'
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache/zig-local'
$out=Join-Path $root 'build/async/test-tools'
New-Item -ItemType Directory -Force $out | Out-Null
& $zig cc -target x86_64-windows-gnu -std=c11 -O1 -Wall -Wextra -Werror -municode (Join-Path $baseline 'test-sender-stub.c') -lbcrypt -o (Join-Path $out 'SCX4200-Test-Sender.exe')
if($LASTEXITCODE -ne 0){throw 'Sender stub failed'}
& $zig cc -target x86_64-windows-gnu -std=c11 -O1 -Wall -Wextra -Werror -municode (Join-Path $baseline 'test-renderer-stub.c') -o (Join-Path $out 'renderer-stub.exe')
if($LASTEXITCODE -ne 0){throw 'Renderer stub failed'}
& (Join-Path $PSScriptRoot 'build-bridge.ps1') -Architecture x64 -TestSender -RendererRoot $RendererRoot
