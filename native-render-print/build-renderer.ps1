# SPDX-License-Identifier: Apache-2.0
param([ValidateSet('x64','arm64')][string]$Architecture='x64',[string]$OutputRoot='build/render-print')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache/zig-local'
$archive=Join-Path $root 'reference-job/upstream/splix-source.zip'
if((Get-FileHash $archive).Hash -ne 'BBBA212ECD05AE704291103413DD087E8F039C78A06CC5FDF270065C00ED49C9'){throw 'Wrong SpliX source archive'}
$upstream=Join-Path $root 'reference-job/upstream/splix-7a802180c7b50802aaa16bbd2b3e326237286730'
$out=Join-Path $root ($OutputRoot+'/'+$Architecture)
New-Item -ItemType Directory -Force $out | Out-Null
$sources=@('algorithm','algo0x0d','algo0x0e','algo0x11','band','bandplane','page','compress','qpdl') | ForEach-Object { Join-Path $upstream "src/$_.cpp" }
$target=if($Architecture -eq 'arm64'){'aarch64-windows-gnu'}else{'x86_64-windows-gnu'}
& $zig c++ -target $target -O2 -municode -DDISABLE_JBIG "-I$upstream/include" (Join-Path $PSScriptRoot 'render.cpp') @sources -o (Join-Path $out 'SCX4200-Render.exe')
if($LASTEXITCODE -ne 0){throw 'Renderer compilation failed'}
Get-FileHash (Join-Path $out 'SCX4200-Render.exe')
