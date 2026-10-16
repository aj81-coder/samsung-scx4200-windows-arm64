# SPDX-License-Identifier: Apache-2.0
param([ValidateSet('x64','arm64','both')][string]$Architecture='arm64',[switch]$UseExistingSources)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'Development builds require PowerShell 7.'}
$root=Split-Path $PSScriptRoot -Parent
& (Join-Path $root 'native-preview/rebuild-from-source.ps1') -Architecture $Architecture -UseExistingSources:$UseExistingSources
$targets=if($Architecture -eq 'both'){@('x64','arm64')}else{@($Architecture)}
foreach($arch in $targets){
 & (Join-Path $PSScriptRoot 'build-framework.ps1') -Architecture $arch
 & (Join-Path $PSScriptRoot 'build-engine.ps1') -Architecture $arch
 & (Join-Path $PSScriptRoot 'build-host.ps1') -Architecture $arch
}
Write-Host 'Background builds complete; no printer or Windows startup settings changed.'
