# SPDX-License-Identifier: Apache-2.0
param([ValidateSet('x64','arm64')][string]$Architecture='x64',[switch]$TestSender,[string]$RendererRoot='build/render-print')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache/zig-local'
$deps=Join-Path $root ('build/async/dep/'+$Architecture)
$out=Join-Path $root ('build/async/'+$Architecture)
if($TestSender){$out=Join-Path $root ('build/async-tests/'+$Architecture)}
New-Item -ItemType Directory -Force $out | Out-Null
$target=if($Architecture -eq 'arm64'){'aarch64-windows-gnu'}else{'x86_64-windows-gnu'}
$defines=@();if($TestSender){$defines=@('-DRELIABLE_TEST_SENDER')}
& $zig cc @defines -target $target -std=c11 -O1 -Wall -Wextra -Werror -I (Join-Path $root 'build/cups-2.4.11') -I (Join-Path $root 'build/pappl-1.4.10') (Join-Path $PSScriptRoot 'bridge.c') (Join-Path $deps 'pappl.lib') (Join-Path $deps 'cups-import.lib') -lws2_32 -ladvapi32 -lbcrypt -o (Join-Path $out 'SCX4200-Reliable-Bridge.exe')
if($LASTEXITCODE -ne 0){throw 'Bridge build failed'}
Copy-Item (Join-Path $deps 'cups.dll') $out -Force
Copy-Item (Join-Path $root ($RendererRoot+'/'+$Architecture+'/SCX4200-Render.exe')) $out -Force
if(!$TestSender){Copy-Item (Join-Path $root ('build/reliable-bridge/scx4200-reliable-sender-'+$Architecture+'.exe')) (Join-Path $out 'SCX4200-Bridge-Sender.exe') -Force}
Get-FileHash (Join-Path $out 'SCX4200-Reliable-Bridge.exe')


