# SPDX-License-Identifier: Apache-2.0
param(
    [Parameter(Mandatory=$true)][string]$Python,
    [Parameter(Mandatory=$true)][string]$Zig,
    [switch]$UseExistingRaster
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache\zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache\zig-local'
if((& $Zig version) -ne '0.15.2'){throw 'Use pinned Zig 0.15.2'}
Push-Location $PSScriptRoot
try {
    $upstream=Join-Path $PSScriptRoot 'upstream/splix-7a802180c7b50802aaa16bbd2b3e326237286730'
    if(-not (Test-Path -LiteralPath $upstream)){
        $archive=Join-Path $PSScriptRoot 'upstream/splix-source.zip'
        if((Get-FileHash -LiteralPath $archive).Hash -ne 'BBBA212ECD05AE704291103413DD087E8F039C78A06CC5FDF270065C00ED49C9'){
            throw 'Upstream source archive hash mismatch'
        }
        Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $PSScriptRoot 'upstream')
    }
    $sources=@('algorithm','algo0x0d','algo0x0e','algo0x11','band','bandplane','page','compress','qpdl') | ForEach-Object { Join-Path $upstream "src/$_.cpp" }
    if(-not $UseExistingRaster){
        & $Python fixture.py raster
        if($LASTEXITCODE -ne 0){throw 'Raster generation failed'}
    }
    & $Zig c++ -target x86_64-windows-gnu -O2 -DDISABLE_JBIG "-I$upstream/include" generate.cpp @sources -o generate.exe
    if($LASTEXITCODE -ne 0){throw 'Compilation failed'}
    & ./generate.exe page.raw test-page.qpdl
    if($LASTEXITCODE -ne 0){throw 'Job generation failed'}
    & $Python fixture.py verify
    if($LASTEXITCODE -ne 0){throw 'Validation failed'}
} finally { Pop-Location }
