# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'cancel-current-job.ps1')
function Get-PreviewStatus {
 $report=[ordered]@{schema_version=1;utc=[DateTime]::UtcNow.ToString('o');state='Unknown';windows_jobs=@();bridge_jobs=@();latest_session=$null;errors=@()}
 try{
  foreach($job in @(Get-PrintJob -PrinterName 'SCX-4200 Capture Test')){
   $report.windows_jobs+=@{id=$job.ID;status=[string]$job.JobStatus}
  }
 }catch{$report.errors+=('Windows queue unavailable: '+$_.Exception.Message)}
 $lock=Test-Path -LiteralPath (Join-Path $PSScriptRoot 'SESSION-ACTIVE.lock')
 try{
  $latest=Get-ChildItem -LiteralPath $PSScriptRoot -Directory | Where-Object Name -match '^bridge-\d' | Sort-Object Name | Select-Object -Last 1
  if($latest){
   $path=Join-Path $latest.FullName 'session-result.json'
   if(Test-Path -LiteralPath $path){$report.latest_session=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json}
  }
  $identity=Get-BridgeIdentity
  if($identity){
   $response=Invoke-Ipp 10
   foreach($group in $response.Groups){
    if($group.Tag -ne 2){continue}
    $ids=@($group.Attributes['job-id']);$states=@($group.Attributes['job-state'])
    if($ids.Count -ne 1 -or $states.Count -ne 1 -or $ids[0] -le 0 -or $states[0] -notin 3,4,5,6,7,8,9){throw 'Ambiguous bridge job response'}
    $report.bridge_jobs+=@{id=$ids[0];state=$states[0]}
   }
   Assert-SameBridge $identity
   if($report.latest_session -and $report.latest_session.blocked){$report.state='Blocked'}else{$report.state='Running'}
  }elseif($lock){$report.state='RecoveryRequired'}else{$report.state='Stopped'}
 }catch{$report.state='Unknown';$report.errors+=$_.Exception.Message}
 return $report
}
if($MyInvocation.InvocationName -ne '.'){
 $report=Get-PreviewStatus
 Write-Host ('Bridge: '+$report.state)
 foreach($job in $report.bridge_jobs){Write-Host ('  IPP job '+$job.id+' | state '+$job.state)}
 foreach($job in $report.windows_jobs){Write-Host ('  Windows job '+$job.id+' | '+$job.status)}
 Write-Host 'Windows Sent/Complete and bridge transport completion do not confirm physical paper output.'
 if($report.windows_jobs.Count){Write-Host 'Windows still holds queue records. Recovery requires every row to be removed.'}
 if($report.state -in 'Blocked','RecoveryRequired'){Write-Host 'Do not resend. Stop the bridge, collect results, and use command 3 for deliberate recovery.'}
 foreach($errorText in $report.errors){Write-Host $errorText}
 $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $PSScriptRoot ('control-status-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.json')) -Encoding UTF8
}
