# SPDX-License-Identifier: Apache-2.0
param([ValidateSet('x64','arm64')][string]$Architecture='x64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache/zig-local'
$out=Join-Path $root ('build/general-host-preview/'+$Architecture)
New-Item -ItemType Directory -Force $out | Out-Null
$target=if($Architecture -eq 'arm64'){'aarch64-windows-gnu'}else{'x86_64-windows-gnu'}
& $zig cc -target $target -std=c11 -O1 -Wall -Wextra -Werror -municode '-Wl,--subsystem,windows' (Join-Path $PSScriptRoot 'host.c') -lshell32 -luser32 -o (Join-Path $out 'SCX4200-Printer.exe')
if($LASTEXITCODE -ne 0){throw 'General preview tray host build failed'}
Get-FileHash (Join-Path $out 'SCX4200-Printer.exe')
