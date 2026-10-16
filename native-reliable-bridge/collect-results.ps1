# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$files=@(Get-ChildItem -LiteralPath $PSScriptRoot -Directory | Where-Object Name -match '^bridge-\d' | Select-Object -ExpandProperty FullName)
$files+=@(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'startup-check-*.json' | Select-Object -ExpandProperty FullName)
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'SESSION-ACTIVE.lock')){$files+=Join-Path $PSScriptRoot 'SESSION-ACTIVE.lock'}
if(-not $files){throw 'No bridge results found yet.'}
$files+=@(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'recovery-*.json' | Select-Object -ExpandProperty FullName)
$files+=@(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'SESSION-ACTIVE-recovered-*.lock' | Select-Object -ExpandProperty FullName)
$zip=Join-Path $PSScriptRoot ('reliable-bridge-results-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.zip')
Compress-Archive -LiteralPath $files -DestinationPath $zip
Write-Host 'Attach this ZIP to the chat. It includes the sample page and logs:'
Write-Host $zip
