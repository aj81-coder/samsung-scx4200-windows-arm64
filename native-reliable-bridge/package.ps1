# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$name='SCX4200-Reliable-Bridge-0.7.0-arm64'
$package=Join-Path $root ('dist/'+$name)
$source=Join-Path $root 'build/reliable/source-package-0.7.0'
$verification=Get-Content (Join-Path $root 'build/reliable/verification.json') -Raw | ConvertFrom-Json
if($verification.result -ne 'PASS'){throw 'Verified build required'}
New-Item -ItemType Directory -Force $package,$source | Out-Null
foreach($binary in $verification.binaries){
 $path=Join-Path $root ('build/reliable/'+$binary.architecture+'/'+$binary.name)
 if((Get-FileHash $path).Hash -ne $binary.sha256){throw 'Stale binary verification'}
 if($binary.architecture -eq 'arm64'){Copy-Item $path $package}
}
foreach($directory in @('native-reliable-bridge','native-ipp-capture','native-render-print')){
 $destination=Join-Path $source $directory
 New-Item -ItemType Directory -Force $destination | Out-Null
 Get-ChildItem (Join-Path $root $directory) -File | Copy-Item -Destination $destination
}
New-Item -ItemType Directory -Force (Join-Path $source 'native-print-test'),(Join-Path $source 'build'),(Join-Path $source 'reference-job/upstream') | Out-Null
Copy-Item (Join-Path $root 'native-print-test/usb_read_helpers.h') (Join-Path $source 'native-print-test')
Copy-Item (Join-Path $root 'reference-job/upstream/splix-source.zip') (Join-Path $source 'reference-job/upstream')
foreach($file in @('test-page.qpdl','generate.cpp','fixture.py','rebuild.ps1')){Copy-Item (Join-Path $root ('reference-job/'+$file)) (Join-Path $source 'reference-job')}
foreach($file in @('cups-2.4.11.zip','pappl-1.4.10.zip','zlib-1.3.1.tar.gz')){Copy-Item (Join-Path $root ('build/'+$file)) (Join-Path $source 'build')}
foreach($file in @('START-HERE.txt','REBUILDING.txt','preflight.ps1','collect-results.ps1','recover-session.ps1')){Copy-Item (Join-Path $PSScriptRoot $file) $package}
Copy-Item (Join-Path $root 'native-ipp-capture/SAMPLE-PAGE.txt') $package
Copy-Item (Join-Path $root 'output/pdf/TWO-PAGE-SAMPLE.pdf') $package
Copy-Item (Join-Path $root 'build/reliable/verification.json') (Join-Path $package 'validation.json')
$licenses=@{'build/cups-2.4.11/LICENSE'='CUPS-LICENSE.txt';'build/cups-2.4.11/NOTICE'='CUPS-NOTICE.txt';'build/cups-2.4.11/vcnet/regex/COPYRIGHT'='Regex-COPYRIGHT.txt';'build/pappl-1.4.10/LICENSE'='PAPPL-LICENSE.txt';'build/pappl-1.4.10/NOTICE'='PAPPL-NOTICE.txt';'build/zlib-1.3.1/LICENSE'='zlib-LICENSE.txt';'reference-job/upstream/splix-7a802180c7b50802aaa16bbd2b3e326237286730/COPYING'='SPLIX-COPYING.txt';'.tools/zig-x86_64-windows-0.15.2/lib/libc/mingw/COPYING'='MinGW-runtime-LICENSE.txt';'.tools/zig-x86_64-windows-0.15.2/LICENSE'='Zig-LICENSE.txt'}
foreach($key in $licenses.Keys){Copy-Item (Join-Path $root $key) (Join-Path $package $licenses[$key])}
$start="@echo off`r`ncd /d `"%~dp0`"`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0preflight.ps1`"`r`nif errorlevel 1 goto end`r`n`"%~dp0SCX4200-Reliable-Bridge.exe`"`r`n:end`r`npause`r`n"
[IO.File]::WriteAllText((Join-Path $package '1-START-RELIABLE-BRIDGE.cmd'),$start,[Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $package '2-COLLECT-RESULTS.cmd'),"@echo off`r`ncd /d `"%~dp0`"`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0collect-results.ps1`"`r`npause`r`n",[Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $package '3-RECOVER-STOPPED-SESSION.cmd'),"@echo off`r`ncd /d `"%~dp0`"`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0recover-session.ps1`"`r`npause`r`n",[Text.Encoding]::ASCII)
Compress-Archive -LiteralPath $source -DestinationPath (Join-Path $package 'source.zip') -Force
Get-ChildItem $package -File | Where-Object Name -ne 'SHA256SUMS.txt' | ForEach-Object {(Get-FileHash $_.FullName).Hash+'  '+$_.Name} | Set-Content (Join-Path $package 'SHA256SUMS.txt') -Encoding ascii
$zip=Join-Path $root ('dist/'+$name+'.zip')
Compress-Archive -LiteralPath $package -DestinationPath $zip -Force
$check=Join-Path $root 'build/reliable/package-check'
Expand-Archive -LiteralPath $zip -DestinationPath $check -Force
foreach($line in Get-Content (Join-Path $package 'SHA256SUMS.txt')){$parts=$line -split '  ',2;if((Get-FileHash (Join-Path (Join-Path $check $name) $parts[1])).Hash -ne $parts[0]){throw 'ZIP hash mismatch'}}
Get-Item $zip | Select-Object FullName,Length
