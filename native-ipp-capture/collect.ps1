# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$runs=@(Get-ChildItem -LiteralPath $PSScriptRoot -Directory | Where-Object { $_.Name -match '^capture-\d{8}-\d{6}-\d{3}-\d+$' })
$files=@(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'queue-*.json' | Select-Object -ExpandProperty FullName)
foreach($run in $runs){$files += $run.FullName}
if(-not $files){throw 'No capture or queue reports found yet.'}
$zip=Join-Path $PSScriptRoot ('capture-results-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.zip')
Compress-Archive -LiteralPath $files -DestinationPath $zip
Write-Host 'Attach this ZIP to the chat. It contains captured page content and logs:'
Write-Host $zip
