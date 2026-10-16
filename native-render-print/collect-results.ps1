# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$files=@(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'print-test-*.json' | Select-Object -ExpandProperty FullName)
$prepared=Join-Path $PSScriptRoot 'prepared'
if(Test-Path -LiteralPath $prepared){$files += $prepared}
if(-not $files){throw 'No preparation or print results found yet.'}
$zip=Join-Path $PSScriptRoot ('controlled-print-results-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.zip')
Compress-Archive -LiteralPath $files -DestinationPath $zip
Write-Host 'Attach this ZIP to the chat. It includes the sample page, preview and print reports:'
Write-Host $zip
