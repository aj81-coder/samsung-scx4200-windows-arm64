# SPDX-License-Identifier: Apache-2.0
param([switch]$InspectOnly)
$ErrorActionPreference='Stop'
$lock=Join-Path $PSScriptRoot 'SESSION-ACTIVE.lock'
if(-not (Test-Path -LiteralPath $lock)){Write-Host 'No blocked session is present. You can start the bridge normally.';exit 0}
$active=@(Get-Process -Name 'SCX4200-Reliable-Bridge' -ErrorAction SilentlyContinue)
if($active.Count){throw 'Stop the bridge with Ctrl+C and wait for its window to close before recovery.'}
if(@(Get-NetTCPConnection -LocalPort 8631 -State Listen -ErrorAction SilentlyContinue).Count){throw 'A bridge/capture listener is still active. Close it before recovery.'}
$jobs=@(Get-PrintJob -PrinterName 'SCX-4200 Capture Test')
if($jobs.Count){
 Write-Host 'Windows still holds these queue records:'
 foreach($job in $jobs){Write-Host ('  Job '+$job.ID+' | '+[string]$job.JobStatus)}
 Write-Host 'Sent to printer, Complete, Retained, and Error do not mean the queue is empty.'
 Write-Host 'Keep this bridge stopped and USB disconnected. In the Windows print queue, cancel only the failed document you intend to abandon.'
 Write-Host 'Wait for its row to disappear, then run recovery again. Keep the printer entry installed.'
 Write-Host 'If the row remains after one minute, collect results and report its job number/status. Do not delete spool files or restart the spooler.'
 throw 'Recovery stopped: Windows queue records remain. No session lock was changed.'
}
$runs=@(Get-ChildItem -LiteralPath $PSScriptRoot -Directory | Where-Object Name -match '^bridge-\d')
$states=@()
foreach($run in $runs){
 $report=Join-Path $run.FullName 'session-result.json'
 if(Test-Path -LiteralPath $report){$value=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json;$states+=@{run=$run.Name;state=$value.state;completed_jobs=$value.completed_jobs;completed_pages=$value.completed_pages;blocked=$value.blocked}}
}
Write-Host 'Recovery starts a new session. It will not resume or resend the old job.'
Write-Host 'A previous job may have printed partly or fully. Keep its output separate.'
foreach($state in $states){Write-Host ($state.run+': '+$state.state+', '+$state.completed_pages+' page data completed')}
if($InspectOnly){Write-Host 'Inspection only: no archive or lock changes made.';exit 0}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$archive=Join-Path $PSScriptRoot ('recovery-backup-'+$stamp+'.zip')
$files=@($lock)+@($runs | Select-Object -ExpandProperty FullName)
$files+=@(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'startup-check-*.json' | Select-Object -ExpandProperty FullName)
Compress-Archive -LiteralPath $files -DestinationPath $archive
if(-not (Test-Path -LiteralPath $archive) -or (Get-Item -LiteralPath $archive).Length -eq 0){throw 'Recovery backup failed. No lock was changed.'}
Write-Host ('Saved the old results: '+$archive)
Write-Host 'Before continuing: disconnect USB, power the printer off/on, wait until ready, load A4 paper, then reconnect USB. This abandons incomplete printer data.'
$answer=Read-Host 'When the printer has been cleared and you intend a NEW test, type RESET'
if($answer -cne 'RESET'){Write-Host 'Recovery cancelled. The session lock remains.';exit 1}
# Recheck immediately before the reversible file rename. Never stop processes,
# cancel print jobs, remove a printer queue or delete captured pages here.
if(@(Get-Process -Name 'SCX4200-Reliable-Bridge' -ErrorAction SilentlyContinue).Count -or @(Get-NetTCPConnection -LocalPort 8631 -State Listen -ErrorAction SilentlyContinue).Count -or @(Get-PrintJob -PrinterName 'SCX-4200 Capture Test').Count){throw 'The bridge or queue became active. Recovery stopped; the lock remains.'}
$backup=Join-Path $PSScriptRoot ('SESSION-ACTIVE-recovered-'+$stamp+'.lock')
Move-Item -LiteralPath $lock -Destination $backup
@{version='0.7.0';action='Explicit recovery after stopped session';backup_archive=[IO.Path]::GetFileName($archive);backup_lock=[IO.Path]::GetFileName($backup);automatic_replay=$false;time_utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot ('recovery-'+$stamp+'.json')) -Encoding UTF8
Write-Host 'Recovery complete. Start the bridge, type ARM, and submit a NEW document when ready.'
