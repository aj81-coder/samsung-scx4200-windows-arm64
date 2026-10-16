# SPDX-License-Identifier: Apache-2.0
param([ValidateSet('x64','arm64')][string]$Architecture='x64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache/zig-local'
$out=Join-Path $root ('build/ipp/'+$Architecture)
$target=if($Architecture -eq 'arm64'){'aarch64-windows-gnu'}else{'x86_64-windows-gnu'}
& $zig cc -target $target -std=c11 -O1 -Wall -Wextra -Werror -I (Join-Path $root 'build/cups-2.4.11') -I (Join-Path $root 'build/pappl-1.4.10') (Join-Path $PSScriptRoot 'capture.c') (Join-Path $out 'pappl.lib') (Join-Path $out 'cups-import.lib') -lws2_32 -ladvapi32 -lbcrypt -o (Join-Path $out 'SCX4200-IPP-Capture.exe')
if($LASTEXITCODE -ne 0){throw 'Capture build failed'}
Get-FileHash (Join-Path $out 'SCX4200-IPP-Capture.exe')
