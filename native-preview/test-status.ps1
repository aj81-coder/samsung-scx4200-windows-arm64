# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path $root ('build/preview/status-tests-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $out | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'status.ps1') -Destination $out
Copy-Item -LiteralPath (Join-Path $root 'native-reliable-bridge/cancel-current-job.ps1') -Destination $out
. (Join-Path $out 'status.ps1')
$script:mode='stopped';$script:operations=@()
function Get-PrintJob {if($script:mode -eq 'queue-error'){throw 'Mock queue error'};if($script:mode -eq 'retained'){[pscustomobject]@{ID=8;JobStatus='Complete, Retained, Error'}}}
function Get-BridgeIdentity {if($script:mode -eq 'identity-error'){throw 'Mock identity error'};if($script:mode -in 'running','processing','blocked','bad-response','changed'){return @{Id=123}};return $null}
function Assert-SameBridge {if($script:mode -eq 'changed'){throw 'Mock changed bridge'}}
function Invoke-Ipp($operation){
 $script:operations+=@($operation)
 if($operation -ne 10){throw 'Status attempted a mutating IPP operation'}
 if($script:mode -eq 'bad-response'){return @{Groups=@(@{Tag=2;Attributes=@{'job-id'=@(1,2);'job-state'=@(5)}})}}
 if($script:mode -eq 'processing'){return @{Groups=@(@{Tag=2;Attributes=@{'job-id'=@(2);'job-state'=@(5)}})}}
 return @{Groups=@()}
}
$run=Join-Path $out 'bridge-20261014-test';New-Item -ItemType Directory -Path $run | Out-Null
$lock=Join-Path $out 'SESSION-ACTIVE.lock'
$results=@()
foreach($case in @('stopped','running','processing','blocked','retained','queue-error','identity-error','bad-response','changed')){
 $script:mode=$case
 @{blocked=($case -eq 'blocked')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'session-result.json')
 if($case -in 'blocked','retained'){Set-Content -LiteralPath $lock 'Original lock'}elseif(Test-Path -LiteralPath $lock){Remove-Item -LiteralPath $lock}
 $report=Get-PreviewStatus
 $expected=switch($case){'running'{'Running'};'processing'{'Running'};'blocked'{'Blocked'};'retained'{'RecoveryRequired'};'queue-error'{'Stopped'};'stopped'{'Stopped'};default{'Unknown'}}
 if($report.state -ne $expected){throw ('Wrong state for '+$case+': '+$report.state)}
 if($case -eq 'retained' -and ($report.windows_jobs.Count -ne 1 -or $report.windows_jobs[0].id -ne 8)){throw 'Retained queue row hidden'}
 if($case -eq 'processing' -and $report.bridge_jobs[0].id -ne 2){throw 'Bridge job hidden'}
 if($case -in 'blocked','retained' -and (Get-Content -LiteralPath $lock -Raw).Trim() -ne 'Original lock'){throw 'Status changed the lock'}
 if($case -eq 'queue-error' -and -not $report.errors.Count){throw 'Queue error hidden'}
 $results+=@{name=$case;result='PASS'}
}
@{result='PASS';tests=$results;ipp_operations=$script:operations;status_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'status.ps1')).Hash;scope='Mocked queue/process/IPP; isolated files only'} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'results.json')
Write-Host $out
