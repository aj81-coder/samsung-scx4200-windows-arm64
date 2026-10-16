# SPDX-License-Identifier: Apache-2.0
param([string]$Python='python.exe')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dir=(Resolve-Path (Join-Path $root 'build/ipp/x64')).Path
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$stdout=Join-Path $dir ('test-'+$stamp+'-stdout.log')
$stderr=Join-Path $dir ('test-'+$stamp+'-stderr.log')
$proc=Start-Process -FilePath (Join-Path $dir 'SCX4200-IPP-Capture.exe') -WorkingDirectory $dir -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
try {
  for($i=0;$i -lt 50;$i++){
    Start-Sleep -Milliseconds 100
    $log=Get-Content $stdout -Raw
    if($log -match 'Captures: ([^\r\n]+)'){ $capture=Join-Path $dir $Matches[1]; break }
    if($proc.HasExited){throw ('Capture server exited: '+(Get-Content $stderr -Raw))}
  }
  if(-not $capture){throw 'Capture server did not report readiness'}
  $listeners=@(Get-NetTCPConnection -State Listen -OwningProcess $proc.Id)
  if($listeners.Count -ne 1 -or $listeners[0].LocalAddress -ne '127.0.0.1' -or $listeners[0].LocalPort -ne 8631){throw 'Unexpected listener addresses'}
  $report=Join-Path $dir ('integration-'+$stamp+'.json')
  & $Python (Join-Path $PSScriptRoot 'test-capture.py') --fixture (Join-Path $dir 'fixture.pwg') --capture-dir $capture --report $report --test-truncated-next-header
  if($LASTEXITCODE -ne 0){throw 'Local IPP integration checks failed'}
  $evidence=Get-Content $report -Raw | ConvertFrom-Json
  $evidence | Add-Member -NotePropertyName binaries -NotePropertyValue @((Get-FileHash (Join-Path $dir 'SCX4200-IPP-Capture.exe')), (Get-FileHash (Join-Path $dir 'cups.dll')))
  $evidence | Add-Member -NotePropertyName listener -NotePropertyValue '127.0.0.1:8631 only'
  $evidence | ConvertTo-Json -Depth 10 | Set-Content $report
} finally {
  if(-not $proc.HasExited){Stop-Process -Id $proc.Id}
}
