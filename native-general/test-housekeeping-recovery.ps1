# SPDX-License-Identifier: Apache-2.0
# Device-free regression cases for interrupted, journaled cleanup only.
param([string]$OutputRoot=(Join-Path $PSScriptRoot ('../build/general/housekeeping-recovery-tests-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))),[string]$CasePattern='*')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'housekeeping.ps1')
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $OutputRoot){throw 'Existing recovery test output must be preserved.'}
$null=New-Item -ItemType Directory -Path $OutputRoot
# Reuse fixture builders without executing the main suite or modifying its file.
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'test-housekeeping.ps1'))
$start=$source.IndexOf('$script:results=');$end=$source.IndexOf("Run-Case 'global_history_and_repeated_starts'")
if($start -lt 0 -or $end -le $start){throw 'Fixture definition boundaries changed.'}
. ([ScriptBlock]::Create($source.Substring($start,$end-$start)))
$script:OriginalRunCase=(Get-Command Run-Case).ScriptBlock
function Run-Case([string]$Name,[scriptblock]$Body){if($Name -like $CasePattern){& $script:OriginalRunCase $Name $Body}}
$script:OriginalRemove=(Get-Command Remove-HousekeepingFile).ScriptBlock
Run-Case 'actual_cancel_schema_without_replay_field_is_bounded' {
 $root=New-FixtureRoot 'actual Cancel schema'
 foreach($i in 1..22){
  $name='control-cancel-'+([DateTime]'2026-09-01').AddDays($i).ToString('yyyyMMdd')+'-120000-000-'+('a'*32)+'.json'
  Save-Json (Join-Path $root $name) @{schema_version=1;action='Cancel';outcome='NoProcessingJob';candidate_jobs=@();cancelled_job_id=$null;error=$null}
 }
 $report=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
 Check ($report.deleted_count -eq 2 -and @(Get-ChildItem -LiteralPath $root -File).Count -eq 20) 'Actual Cancel reports were not bounded.'
 foreach($value in @('False',$true)){
  Check (!(Test-HousekeepingControl ([pscustomobject]@{schema_version=1;action='Cancel';outcome='CancelAccepted';automatic_replay=$value}))) 'Invalid Cancel replay value accepted.'
 }
 Check (!(Test-HousekeepingControl ([pscustomobject]@{schema_version=1;action='Diagnostics';outcome='DiagnosticsCollected'}))) 'Diagnostics without replay metadata was accepted.'
}
Run-Case 'payload_failure_after_earlier_payload_deleted_is_resumable' {
 $root=New-FixtureRoot 'payload retry';$old=New-CleanSession $root 0 2;Fill-History $root 10
 function Remove-HousekeepingFile([string]$Root,[string]$Path){
  if($Path.EndsWith('job-000002\pages.index')){throw 'Injected payload unlink failure.'}
  & $script:OriginalRemove $Root $Path
 }
 try{$report=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)}finally{Set-Item function:Remove-HousekeepingFile -Value $script:OriginalRemove}
 Check ($report.error_count -eq 1) 'Expected injected payload failure.'
 Check (!(Test-Path -LiteralPath (Join-Path $old 'job-000001/pages.index'))) 'Earlier payload was not removed.'
 Check (Test-Path -LiteralPath (Join-Path $old 'job-000001/bridge-result.json')) 'Success marker removed before payload cleanup completed.'
 $null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
 Check (!(Test-Path -LiteralPath $old)) 'Payload cleanup could not resume.'
}
Run-Case 'final_journal_unlink_failure_is_resumable_without_session_directory' {
 $root=New-FixtureRoot 'orphan retry';$old=New-CleanSession $root 0;Fill-History $root 10
 function Remove-HousekeepingFile([string]$Root,[string]$Path){
  if([IO.Path]::GetFileName($Path).StartsWith('housekeeping-bridge-')){throw 'Injected journal unlink failure.'}
  & $script:OriginalRemove $Root $Path
 }
 try{$report=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)}finally{Set-Item function:Remove-HousekeepingFile -Value $script:OriginalRemove}
 Check ($report.error_count -eq 1 -and !(Test-Path -LiteralPath $old)) 'Did not reach final journal deletion.'
 Check (@(Get-ChildItem -LiteralPath $root -Filter 'housekeeping-bridge-*.json').Count -eq 1) 'Retry journal is absent.'
 $plan=Get-HousekeepingPlan $root
 Check ($plan.orphan_journals.Count -eq 1) 'Valid orphan journal not recognized.'
 $null=Invoke-HousekeepingPlan $root $plan
 Check (@(Get-ChildItem -LiteralPath $root -Filter 'housekeeping-bridge-*.json').Count -eq 0) 'Orphan journal could not be retired.'
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HousekeepingDirectoryLock {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 public static extern IntPtr CreateFile(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
}
'@
foreach($kind in @('job','session')){
 Run-Case ('directory_unlink_failure_after_receipt_removal_'+$kind) {
  $root=New-FixtureRoot ('directory '+$kind);$old=New-CleanSession $root 0;Fill-History $root 10
  $lockedPath=$old;if($kind -ceq 'job'){$lockedPath=Join-Path $old 'job-000001'}
  $handle=[HousekeepingDirectoryLock]::CreateFile($lockedPath,1,3,[IntPtr]::Zero,3,0x02000000,[IntPtr]::Zero)
  if($handle -eq [IntPtr]::new(-1)){throw 'Could not lock fixture directory.'}
  try{$report=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)}finally{$null=[HousekeepingDirectoryLock]::CloseHandle($handle)}
  Save-Json (Join-Path $root 'cleanup-report.json') $report
  Check ($report.error_count -eq 1) ('Expected sharing failure at directory unlink: '+($report.errors|ConvertTo-Json -Compress))
  Check (!(Test-Path -LiteralPath (Join-Path $old 'job-000001/bridge-result.json'))) 'Test did not reach receipt removal.'
  $null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
  Check (!(Test-Path -LiteralPath $old)) 'Journal could not resume directory removal.'
 }
}
Run-Case 'corrupt_retry_proof_preserves_remaining_session' {
 $root=New-FixtureRoot 'corrupt retry';$old=New-CleanSession $root 0;Fill-History $root 10
 function Remove-HousekeepingFile([string]$Root,[string]$Path){if($Path.EndsWith('pages.index')){throw 'Injected pause.'};& $script:OriginalRemove $Root $Path}
 try{$null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)}finally{Set-Item function:Remove-HousekeepingFile -Value $script:OriginalRemove}
 $journal=Get-ChildItem -LiteralPath $root -Filter 'housekeeping-bridge-*.json'
 $proof=Get-Content -LiteralPath $journal.FullName -Raw | ConvertFrom-Json;$proof.summary_base64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'));Save-Json $journal.FullName $proof
 $before=Snapshot $root;$null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
 Check ((Snapshot $root) -ceq $before) 'Corrupt retry metadata allowed further deletion.'
}
Run-Case 'retry_journal_cannot_associate_another_sessions_host_log' {
 $root=New-FixtureRoot 'foreign host log';$old=New-CleanSession $root 0;Fill-History $root 10
 function Remove-HousekeepingFile([string]$Root,[string]$Path){if($Path.EndsWith('pages.index')){throw 'Injected pause.'};& $script:OriginalRemove $Root $Path}
 try{$null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)}finally{Set-Item function:Remove-HousekeepingFile -Value $script:OriginalRemove}
 $journal=Get-ChildItem -LiteralPath $root -Filter 'housekeeping-bridge-*.json'
 $foreignName='background-20260101-120000-999-1000.log';$foreignPath=Join-Path $root $foreignName
 [IO.File]::WriteAllText($foreignPath,"Results: bridge-20260101-120000-000-999`r`nFailed printer session; preserve.`r`n")
 $proof=Get-Content -LiteralPath $journal.FullName -Raw | ConvertFrom-Json
 $proof.logs=@([pscustomobject]@{name=$foreignName;sha256=(Get-HousekeepingFileHash $foreignPath)});Save-Json $journal.FullName $proof
 $before=Snapshot $root;$null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
 Check ((Snapshot $root) -ceq $before) 'A copied host-log hash defeated session association.'
}
Write-Host ('PASS: '+$script:results.Count+' interrupted-cleanup tests; '+$OutputRoot)
