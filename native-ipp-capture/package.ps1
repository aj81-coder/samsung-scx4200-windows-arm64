# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$build=Join-Path $root 'build/ipp'
$verification=Get-Content (Join-Path $build 'verification.json') -Raw | ConvertFrom-Json
if(-not $verification.local_tests.passed){throw 'Passing local tests required'}
$name='SCX4200-IPP-Capture-0.3.1-arm64'
$package=Join-Path $root ('dist/'+$name)
$source=Join-Path $build 'source-package'
New-Item -ItemType Directory -Force $package,(Join-Path $source 'native-ipp-capture'),(Join-Path $source 'build') | Out-Null
foreach($file in @('SCX4200-IPP-Capture.exe','cups.dll')){
  $path=Join-Path $build ('arm64/'+$file)
  $expected=($verification.binaries | Where-Object {$_.architecture -eq 'arm64' -and $_.name -eq $file}).sha256
  if((Get-FileHash $path).Hash -ne $expected){throw 'Stale binary verification'}
  Copy-Item $path $package
}
Copy-Item (Join-Path $PSScriptRoot '*') (Join-Path $source 'native-ipp-capture')
foreach($file in @('START-HERE.txt','REBUILDING.txt','SAMPLE-PAGE.txt','queue.ps1','recover-queue.ps1','collect.ps1')){Copy-Item (Join-Path $PSScriptRoot $file) $package}
foreach($file in @('cups-2.4.11.zip','pappl-1.4.10.zip','zlib-1.3.1.tar.gz')){Copy-Item (Join-Path $root ('build/'+$file)) (Join-Path $source 'build')}
Copy-Item (Join-Path $build 'verification.json') (Join-Path $package 'validation.json')
Copy-Item (Join-Path $root 'build/cups-2.4.11/LICENSE') (Join-Path $package 'CUPS-LICENSE.txt')
Copy-Item (Join-Path $root 'build/cups-2.4.11/NOTICE') (Join-Path $package 'CUPS-NOTICE.txt')
Copy-Item (Join-Path $root 'build/cups-2.4.11/vcnet/regex/COPYRIGHT') (Join-Path $package 'Regex-COPYRIGHT.txt')
Copy-Item (Join-Path $root 'build/pappl-1.4.10/LICENSE') (Join-Path $package 'PAPPL-LICENSE.txt')
Copy-Item (Join-Path $root 'build/pappl-1.4.10/NOTICE') (Join-Path $package 'PAPPL-NOTICE.txt')
Copy-Item (Join-Path $root 'build/zlib-1.3.1/LICENSE') (Join-Path $package 'zlib-LICENSE.txt')
Copy-Item (Join-Path $root '.tools/zig-x86_64-windows-0.15.2/lib/libc/mingw/COPYING') (Join-Path $package 'MinGW-runtime-LICENSE.txt')
Copy-Item (Join-Path $root '.tools/zig-x86_64-windows-0.15.2/LICENSE') (Join-Path $package 'Zig-LICENSE.txt')
$commands=@{
 '0-REMOVE-OLD-TEST-QUEUE.cmd'='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0recover-queue.ps1"';
 '1-START-CAPTURE.cmd'='"%~dp0SCX4200-IPP-Capture.exe"';
 '2-ADD-TEST-QUEUE.cmd'='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0queue.ps1" -Action Add';
 '3-COLLECT-RESULTS.cmd'='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect.ps1"';
 '4-REMOVE-TEST-QUEUE.cmd'='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0queue.ps1" -Action Remove'
}
foreach($file in $commands.Keys){[IO.File]::WriteAllText((Join-Path $package $file),"@echo off`r`ntitle SCX-4200 - "+$file+"`r`ncd /d `"%~dp0`"`r`n"+$commands[$file]+"`r`npause`r`n",[Text.Encoding]::ASCII)}
Compress-Archive -LiteralPath $source -DestinationPath (Join-Path $package 'source.zip') -Force
Get-ChildItem $package -File | Where-Object {$_.Name -ne 'SHA256SUMS.txt'} | ForEach-Object {(Get-FileHash $_.FullName).Hash+'  '+$_.Name} | Set-Content (Join-Path $package 'SHA256SUMS.txt') -Encoding ascii
$zip=Join-Path $root ('dist/'+$name+'.zip')
Compress-Archive -LiteralPath $package -DestinationPath $zip -Force
$check=Join-Path $build 'package-check'
Expand-Archive -LiteralPath $zip -DestinationPath $check -Force
foreach($line in Get-Content (Join-Path $package 'SHA256SUMS.txt')){
  $parts=$line -split '  ',2
  if((Get-FileHash (Join-Path (Join-Path $check $name) $parts[1])).Hash -ne $parts[0]){throw 'Packaged hash mismatch'}
}
Get-Item $zip | Select-Object FullName,Length
