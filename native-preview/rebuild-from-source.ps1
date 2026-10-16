# SPDX-License-Identifier: Apache-2.0
param([ValidateSet('x64','arm64','both')][string]$Architecture='arm64',[switch]$UseExistingSources)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'Source generation requires PowerShell7. Runtime printer commands still use Windows PowerShell5.1.'}
$root=Split-Path $PSScriptRoot -Parent
$pins=[ordered]@{
 'build/cups-2.4.11.zip'='7C8481ADC19E92399BA847E65DF7A7251D96CB29B3E704CAD780965D99403E42'
 'build/pappl-1.4.10.zip'='1E93FFC841EA560B93A3F699BC0F3B3220AC4DF2E0F0934F0C30F62BB8C6C72F'
 'build/zlib-1.3.1.tar.gz'='9A93B2B7DFDAC77CEBA5A558A580E74667DD6FEDE4585B91EEFB60F03B72DF23'
 'reference-job/upstream/splix-source.zip'='BBBA212ECD05AE704291103413DD087E8F039C78A06CC5FDF270065C00ED49C9'
}
foreach($relative in $pins.Keys){if((Get-FileHash -LiteralPath (Join-Path $root $relative)).Hash -ne $pins[$relative]){throw ('Pinned archive differs: '+$relative)}}
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
if((& $zig version) -ne '0.15.2'){throw 'Use the pinned Zig0.15.2 compiler distribution.'}
$extractions=@(@('build/cups-2.4.11.zip','build/cups-2.4.11','build'),@('build/pappl-1.4.10.zip','build/pappl-1.4.10','build'),@('reference-job/upstream/splix-source.zip','reference-job/upstream/splix-7a802180c7b50802aaa16bbd2b3e326237286730','reference-job/upstream'))
foreach($entry in $extractions){
 if(Test-Path -LiteralPath (Join-Path $root $entry[1])){if(-not $UseExistingSources){throw ('Upstream directory already exists: '+$entry[1]+'. Use a fresh source extraction, or deliberately pass -UseExistingSources for a repeat build.')}}
 else{Expand-Archive -LiteralPath (Join-Path $root $entry[0]) -DestinationPath (Join-Path $root $entry[2])}
}
if(Test-Path -LiteralPath (Join-Path $root 'build/zlib-1.3.1')){if(-not $UseExistingSources){throw 'zlib source already exists; use a fresh tree or -UseExistingSources.'}}
else{
 & tar.exe -xf (Join-Path $root 'build/zlib-1.3.1.tar.gz') -C (Join-Path $root 'build')
 if($LASTEXITCODE -ne 0){throw 'zlib extraction failed'}
}
$targets=if($Architecture -eq 'both'){@('x64','arm64')}else{@($Architecture)}
foreach($arch in $targets){
 & (Join-Path $root 'native-async-bridge/build-dependencies.ps1') -Architecture $arch
 & (Join-Path $root 'native-render-print/build-renderer.ps1') -Architecture $arch -OutputRoot 'build/margin-fix'
}
& (Join-Path $root 'native-reliable-bridge/sender-build.ps1')
$binaries=@()
foreach($arch in $targets){
 & (Join-Path $root 'native-async-bridge/build-bridge.ps1') -Architecture $arch -RendererRoot 'build/margin-fix'
 foreach($name in @('SCX4200-Reliable-Bridge.exe','SCX4200-Render.exe','SCX4200-Bridge-Sender.exe','cups.dll')){
  $path=Join-Path $root ('build/async/'+$arch+'/'+$name)
  $binaries+=@{architecture=$arch;name=$name;sha256=(Get-FileHash -LiteralPath $path).Hash}
 }
}
@{result='PASS_SOURCE_BUILDS';powershell_version=$PSVersionTable.PSVersion.ToString();zig_version='0.15.2';archive_pins=$pins;binaries=$binaries;existing_sources_reused=[bool]$UseExistingSources;printing_attempted=$false} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $root ('build/rebuild-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.json')) -Encoding UTF8
Write-Host 'Native build finished. No printing or queue changes were performed.'
