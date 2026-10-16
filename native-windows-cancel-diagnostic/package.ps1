# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$name='SCX4200-Windows-Cancel-Diagnostic-0.8.4-arm64'
$package=Join-Path $root ('dist/'+$name)
$sourceStage=Join-Path $root 'build/windows-cancel-diagnostic/source-stage-0.8.4'
$baselineZip=Join-Path $root 'dist/SCX4200-Async-Bridge-0.8.0-arm64.zip'
$baselineHash='6DB0A06746D81BD7E885D7B7485C5B6FFD10CF85FBDBD60EE488AE5A058DA067'
if((Get-FileHash $baselineZip).Hash -ne $baselineHash){throw 'Baseline archive differs from audited 0.8.0'}
if((Test-Path $package) -or (Test-Path $sourceStage)){throw 'Preserve existing package/staging; use a fresh explicit version.'}
$tests=Get-Content (Join-Path $root 'build/windows-cancel-diagnostic/test-results.json') -Raw | ConvertFrom-Json
if($tests.result -ne 'PASS'){throw 'Diagnostic tests must pass before packaging'}
if((Get-FileHash (Join-Path $PSScriptRoot 'windows-cancel-diagnostic.ps1')).Hash -ne $tests.script_sha256){throw 'Diagnostic changed since tests'}
$probeTests=Get-Content (Join-Path $root 'build/windows-cancel-diagnostic/spooler-identity-tests.json') -Raw | ConvertFrom-Json
if($probeTests.result -ne 'PASS' -or (Get-FileHash (Join-Path $PSScriptRoot 'spooler-identity.ps1')).Hash -ne $probeTests.helper_sha256){throw 'Native spooler probe evidence failed or stale'}
New-Item -ItemType Directory -Force $package,$sourceStage | Out-Null
$baseline=Join-Path $root 'dist/SCX4200-Async-Bridge-0.8.0-arm64'
foreach($line in Get-Content (Join-Path $baseline 'SHA256SUMS.txt')){
 $parts=$line -split '  ',2
 if((Get-FileHash (Join-Path $baseline $parts[1])).Hash -ne $parts[0]){throw 'Baseline extracted files changed'}
}
Get-ChildItem $baseline -File | Copy-Item -Destination $package
$verification=Get-Content (Join-Path $package 'validation.json') -Raw | ConvertFrom-Json
foreach($binary in $verification.binaries){
 if($binary.architecture -eq 'arm64' -and (Get-FileHash (Join-Path $package $binary.name)).Hash -ne $binary.sha256){throw 'Printing binary changed'}
}
Copy-Item (Join-Path $PSScriptRoot 'START-HERE.txt') $package -Force
Copy-Item (Join-Path $PSScriptRoot 'windows-cancel-diagnostic.ps1') $package
Copy-Item (Join-Path $PSScriptRoot 'spooler-identity.ps1') $package
Copy-Item (Join-Path $root 'build/windows-cancel-diagnostic/spooler-identity-tests.json') (Join-Path $package 'spooler-identity-validation.json')
Copy-Item (Join-Path $PSScriptRoot 'VALIDATION.md') (Join-Path $package 'DIAGNOSTIC-VALIDATION.md')
Copy-Item (Join-Path $root 'build/windows-cancel-diagnostic/test-results.json') (Join-Path $package 'diagnostic-validation.json')
$collector=Get-Content (Join-Path $package 'collect-results.ps1') -Raw
$collector=$collector.Replace("if(-not `$files)","`$files+=@(Get-ChildItem -LiteralPath `$PSScriptRoot -File -Filter 'control-windows-cancel-*.json' | Select-Object -ExpandProperty FullName)`r`n`$files+=@(Get-ChildItem -LiteralPath `$PSScriptRoot -File -Filter 'control-windows-cancel-*.jsonl' | Select-Object -ExpandProperty FullName)`r`nif(-not `$files)")
[IO.File]::WriteAllText((Join-Path $package 'collect-results.ps1'),$collector,[Text.Encoding]::UTF8)
$command="@echo off`r`ncd /d `"%~dp0`"`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0windows-cancel-diagnostic.ps1`"`r`npause`r`n"
[IO.File]::WriteAllText((Join-Path $package '5-DIAGNOSE-WINDOWS-CANCELLATION.cmd'),$command,[Text.Encoding]::ASCII)
Expand-Archive -LiteralPath (Join-Path $package 'source.zip') -DestinationPath $sourceStage
$source=Join-Path $sourceStage 'source-package-0.8.0'
$diagSource=Join-Path $source 'native-windows-cancel-diagnostic'
New-Item -ItemType Directory -Force $diagSource | Out-Null
Get-ChildItem $PSScriptRoot -File | Copy-Item -Destination $diagSource
Compress-Archive -LiteralPath $source -DestinationPath (Join-Path $package 'source.zip') -Force
Get-ChildItem $package -File | Where-Object Name -ne 'SHA256SUMS.txt' | ForEach-Object {(Get-FileHash $_.FullName).Hash+'  '+$_.Name} | Set-Content (Join-Path $package 'SHA256SUMS.txt') -Encoding ascii
$zip=Join-Path $root ('dist/'+$name+'.zip')
Compress-Archive -LiteralPath $package -DestinationPath $zip
Get-Item $zip | Select-Object FullName,Length
Get-FileHash $zip
