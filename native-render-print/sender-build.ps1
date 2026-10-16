# SPDX-License-Identifier: Apache-2.0
param([string]$Zig = (Join-Path $PSScriptRoot '..\.tools\zig-x86_64-windows-0.15.2\zig.exe'))
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache\zig-local'
$output=Join-Path $root 'build\render-print'
New-Item -ItemType Directory -Path $output -Force | Out-Null
if((& $Zig version) -ne '0.15.2'){throw 'Use pinned Zig 0.15.2'}
foreach($arch in @(@('aarch64','arm64'),@('x86_64','x64'))){
    $exe=Join-Path $output ('scx4200-render-print-'+$arch[1]+'.exe')
    & $Zig cc -target ($arch[0]+'-windows-gnu') -std=c11 -O2 -Wall -Wextra -Werror -municode (Join-Path $PSScriptRoot 'sender.c') -lsetupapi -lbcrypt -o $exe
    if($LASTEXITCODE -ne 0){throw 'Sender compilation failed'}
    Get-FileHash -LiteralPath $exe
}
