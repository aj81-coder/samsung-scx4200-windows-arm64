# SPDX-License-Identifier: Apache-2.0
param([string]$Zig=(Join-Path $PSScriptRoot '..\.tools\zig-x86_64-windows-0.15.2\zig.exe'))
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache\zig-local'
if((& $Zig version) -ne '0.15.2'){throw 'Use pinned Zig 0.15.2'}
foreach($arch in @(@('aarch64','arm64'),@('x86_64','x64'))){
    $output=Join-Path $root ('build\general\'+$arch[1])
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $exe=Join-Path $output 'SCX4200-Bridge-Sender.exe'
    & $Zig cc -target ($arch[0]+'-windows-gnu') -std=c11 -O2 -Wall -Wextra -Werror -municode (Join-Path $PSScriptRoot 'sender.c') -lsetupapi -lbcrypt -o $exe
    if($LASTEXITCODE -ne 0){throw 'Sender compilation failed'}
    Copy-Item -LiteralPath $exe -Destination (Join-Path $output 'SCX4200-Sender.exe') -Force
    Get-FileHash -LiteralPath $exe
}
