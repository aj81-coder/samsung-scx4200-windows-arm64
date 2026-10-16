# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$report=[ordered]@{version='0.7.0';success=$false;queue='SCX-4200 Capture Test';pending_jobs=$null;error=$null}
try {
 if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'SESSION-ACTIVE.lock')){throw 'A session is still active or ended with an interruption/failure. Stop the bridge and use 3-RECOVER-STOPPED-SESSION.cmd for a deliberate fresh test; do not delete the lock.'}
 $queue=Get-Printer -Name $report.queue
 if($queue.DriverName -ne 'Microsoft IPP Class Driver'){throw 'The existing capture queue does not use Microsoft IPP Class Driver.'}
 $jobs=@(Get-PrintJob -PrinterName $report.queue)
 $report.pending_jobs=$jobs.Count
 if($jobs.Count){throw 'The Windows test queue still contains jobs. Do not start this test until that queue is empty.'}
 $listeners=@(Get-NetTCPConnection -LocalPort 8631 -State Listen -ErrorAction SilentlyContinue)
 if($listeners.Count){throw 'Port 8631 is already in use. Close the old capture/bridge window before starting this test.'}
 $report.success=$true
 Write-Host 'Startup check passed: the existing test queue is empty.'
}catch{$report.error=$_.Exception.Message;Write-Host ('Startup check stopped: '+$report.error)}
$report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot ('startup-check-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.json')) -Encoding UTF8
if(-not $report.success){exit 1}
