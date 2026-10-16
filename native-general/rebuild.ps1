# SPDX-License-Identifier: Apache-2.0
param([ValidateSet('x64','arm64','both')][string]$Architecture='arm64',[switch]$UseExistingSources)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'Development builds require PowerShell 7.'}
$root=Split-Path $PSScriptRoot -Parent
# Build the pinned dependencies, unchanged margin renderer and native tray host.
# Preserve all prior outputs; general binaries/dependencies have separate roots.
& (Join-Path $root 'native-background/rebuild.ps1') -Architecture $Architecture -UseExistingSources:$UseExistingSources
# The streaming sender recipe currently builds both architectures explicitly.
& (Join-Path $PSScriptRoot 'sender-build.ps1')
$targets=if($Architecture -eq 'both'){@('x64','arm64')}else{@($Architecture)}
foreach($arch in $targets){
 & (Join-Path $PSScriptRoot 'build-host.ps1') -Architecture $arch
 & (Join-Path $PSScriptRoot 'build-framework.ps1') -Architecture $arch
 & (Join-Path $PSScriptRoot 'build-engine.ps1') -Architecture $arch
}
Write-Host 'General preview builds complete under build/general/ARCH. No printing, queue or startup changes were made.'
