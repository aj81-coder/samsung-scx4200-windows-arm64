# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$name='SCX4200-Controlled-Print-0.4.0-arm64'
$package=Join-Path $root ('dist/'+$name)
$source=Join-Path $root 'build/render-print/source-package'
$validation=Get-Content (Join-Path $root 'build/render-print/captured-page-validation.json') -Raw | ConvertFrom-Json
if($validation.result -ne 'PASS'){throw 'Captured page round-trip verification required'}
$buildVerification=Get-Content (Join-Path $root 'build/render-print/build-verification.json') -Raw | ConvertFrom-Json
foreach($binary in $buildVerification.binaries){
 if((Get-FileHash (Join-Path $root ('build/render-print/'+$binary.path))).Hash -ne $binary.sha256){throw 'Stale binary verification'}
}
New-Item -ItemType Directory -Force $package,(Join-Path $source 'native-render-print'),(Join-Path $source 'native-print-test'),(Join-Path $source 'reference-job/upstream') | Out-Null
Copy-Item (Join-Path $root 'build/render-print/arm64/SCX4200-Render.exe') $package
Copy-Item (Join-Path $root 'build/render-print/scx4200-render-print-arm64.exe') $package
foreach($file in @('prepare.ps1','print-prepared.ps1','collect-results.ps1','START-HERE.txt','REBUILDING.txt')){Copy-Item (Join-Path $PSScriptRoot $file) $package}
Get-ChildItem $PSScriptRoot -File | Copy-Item -Destination (Join-Path $source 'native-render-print')
Copy-Item (Join-Path $root 'native-print-test/usb_read_helpers.h') (Join-Path $source 'native-print-test')
Copy-Item (Join-Path $root 'reference-job/upstream/splix-source.zip') (Join-Path $source 'reference-job/upstream')
Copy-Item (Join-Path $root 'reference-job/upstream/splix-7a802180c7b50802aaa16bbd2b3e326237286730/COPYING') (Join-Path $package 'SPLIX-COPYING.txt')
Copy-Item (Join-Path $root '.tools/zig-x86_64-windows-0.15.2/lib/libc/mingw/COPYING') (Join-Path $package 'MinGW-runtime-LICENSE.txt')
Copy-Item (Join-Path $root '.tools/zig-x86_64-windows-0.15.2/LICENSE') (Join-Path $package 'Zig-LICENSE.txt')
Copy-Item (Join-Path $root 'build/render-print/captured-page-validation.json') (Join-Path $package 'validation.json')
Copy-Item (Join-Path $root 'build/render-print/build-verification.json') (Join-Path $package 'build-verification.json')
$commands=@{'1-PREPARE-PAGE.cmd'='prepare.ps1';'2-PRINT-PREPARED-PAGE.cmd'='print-prepared.ps1';'3-COLLECT-RESULTS.cmd'='collect-results.ps1'}
foreach($file in $commands.Keys){[IO.File]::WriteAllText((Join-Path $package $file),"@echo off`r`ncd /d `"%~dp0`"`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0"+$commands[$file]+"`"`r`npause`r`n",[Text.Encoding]::ASCII)}
Compress-Archive -LiteralPath $source -DestinationPath (Join-Path $package 'source.zip') -Force
Get-ChildItem $package -File | Where-Object Name -ne 'SHA256SUMS.txt' | ForEach-Object {(Get-FileHash $_.FullName).Hash+'  '+$_.Name} | Set-Content (Join-Path $package 'SHA256SUMS.txt') -Encoding ascii
$zip=Join-Path $root ('dist/'+$name+'.zip')
Compress-Archive -LiteralPath $package -DestinationPath $zip -Force
$check=Join-Path $root 'build/render-print/package-check'
Expand-Archive -LiteralPath $zip -DestinationPath $check -Force
foreach($line in Get-Content (Join-Path $package 'SHA256SUMS.txt')){
 $parts=$line -split '  ',2
 if((Get-FileHash (Join-Path (Join-Path $check $name) $parts[1])).Hash -ne $parts[0]){throw 'Packaged hash mismatch'}
}
Get-Item $zip | Select-Object FullName,Length
