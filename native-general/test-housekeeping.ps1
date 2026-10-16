# SPDX-License-Identifier: Apache-2.0
# Isolated filesystem fixtures; queue/process/endpoint APIs below are mocks.
param([string]$OutputRoot=(Join-Path $PSScriptRoot ('../build/general/housekeeping-tests-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'housekeeping.ps1')
$script:loadedHousekeepingHash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'housekeeping.ps1')).Hash
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $OutputRoot){throw 'Existing test output must be preserved.'}
$null=New-Item -ItemType Directory -Path $OutputRoot
$script:results=New-Object Collections.ArrayList;$script:engine=$false;$script:listener=$false
function Get-Process {param($Name,$ErrorAction) if($script:engine){[pscustomobject]@{Id=123}}}
function Get-NetTCPConnection {param($State,$ErrorAction) if($script:listener){[pscustomobject]@{LocalPort=8631}}}
function Check($Condition,[string]$Message){if(!$Condition){throw $Message}}
function Save-Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
function New-FixtureRoot([string]$Name){$path=Join-Path $OutputRoot $Name;$null=New-Item -ItemType Directory -Path $path;return $path}
function New-CleanSession([string]$Root,[int]$Index,[int]$Jobs=1){
 $stamp=([DateTime]'2026-09-01').AddDays($Index).ToString('yyyyMMdd')
 $name='bridge-'+$stamp+'-120000-000-'+(100+$Index);$path=Join-Path $Root $name
 $null=New-Item -ItemType Directory -Path $path;$null=New-Item -ItemType Directory -Path (Join-Path $path 'spool')
 Save-Json (Join-Path $path 'session-result.json') ([ordered]@{version='0.12.0-general-dev';state='CLEAN_SHUTDOWN';mock_transport=$false;accepted_jobs=$Jobs;completed_jobs=$Jobs;accepted_pages=$Jobs;completed_pages=$Jobs;decoded_bytes=8697360*$Jobs;maximum_document_pages=$null;maximum_session_pages=$null;blocked=$false;automatic_retry=$false})
 [IO.File]::WriteAllText((Join-Path $path 'framework.log'),'fixture framework log')
 foreach($id in 1..$Jobs){
  if(!$Jobs){break};$job=Join-Path $path ('job-'+$id.ToString('000000'));$null=New-Item -ItemType Directory -Path $job
  $hash='a'*64
  Save-Json (Join-Path $job 'bridge-result.json') ([ordered]@{version='0.12.0-general-dev';architecture='ARM64';job_id=$id;result='USB_WRITE_COMPLETED_PHYSICAL_OUTPUT_UNCONFIRMED';success=$true;mock_transport=$false;bundle_sha256=$hash;rows_sha256=$hash;job_bytes=100;usb_bytes=100;acknowledged_bytes=100;acknowledged_bytes_known=$true;delivery_uncertain=$false;document_pages=1;bundle_bytes=160;automatic_retry=$false})
  Save-Json (Join-Path $job 'sender-report.json') ([ordered]@{version='0.12.0';build_architecture='ARM64';result='USB_WRITE_COMPLETED_PHYSICAL_OUTPUT_UNCONFIRMED';check_only=$false;job_sha256=$hash;job_bytes=100;bundle_bytes=160;document_pages=1;job_hash_verified=$true;exclusive_read_write_open=$true;bridge_permit_consumed=$true;printer_wait=@{write_requests_replayed=0};transfer=@{attempted=$true;acknowledged_bytes=100;write_calls=1;win32_error=0;delivery_uncertain=$false;timed_out=$false;cancellation_pending=$false;pages_data_completed=1}})
  Save-Json (Join-Path $job 'sender-progress.json') @{state='fixture'}
  Save-Json (Join-Path $job 'SEND_STARTED.json') @{bundle_sha256=$hash}
  [IO.File]::WriteAllText((Join-Path $job 'pages.index'),'fixture index')
 }
 $log=Join-Path $Root ('background-'+$stamp+'-120000-'+(100+$Index)+'-1000.log')
 [IO.File]::WriteAllText($log,"SCX-4200 automatic development bridge 0.12.0-general-dev (ARM64)`r`nResults: $name`r`n")
 return $path
}
function Fill-History([string]$Root,[int]$Count=12){foreach($index in 1..$Count){$null=New-CleanSession $Root $index $(if($index -le 2){1}else{0})}}
function Snapshot([string]$Root){return (@(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName | ForEach-Object {$_.FullName.Substring($Root.Length)+':'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}) -join "`n")}
function Run-Case([string]$Name,[scriptblock]$Body){$script:engine=$false;$script:listener=$false;try{& $Body;[void]$script:results.Add(@{name=$Name;result='PASS'})}catch{[void]$script:results.Add(@{name=$Name;result='FAIL';error=$_.Exception.Message});throw}finally{Save-Json (Join-Path $OutputRoot 'results.json') @{result=$(if(@($script:results | Where-Object result -eq FAIL).Count){'FAIL'}else{'PASS'});tests=@($script:results.ToArray());device_free=$true}}}
Run-Case 'global_history_and_repeated_starts' {
 $root=New-FixtureRoot 'history';Fill-History $root
 $plan=Get-HousekeepingPlan $root;Check ($plan.sessions.Count -eq 2) 'Expected two old clean sessions.'
 $report=Invoke-HousekeepingPlan $root $plan;Check ($report.removed_sessions.Count -eq 2) 'Old sessions not removed.'
 Check (@(Get-ChildItem -LiteralPath $root -Directory).Count -eq 10) 'History is not ten.'
 Check (@(Get-ChildItem -LiteralPath $root -File -Filter 'background-*.log').Count -eq 10) 'Mapped logs not pruned.'
 Check ((Get-HousekeepingPlan $root).sessions.Count -eq 0) 'Second start was not idempotent.'
 $null=New-CleanSession $root 13;$next=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
 Check ($next.removed_sessions.Count -eq 1) 'Next start did not prune new excess history.'
}
Run-Case 'idle_clean_session' {
 $root=New-FixtureRoot 'idle';$old=New-CleanSession $root 0 0;Fill-History $root 10
 $report=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
 Check (!(Test-Path -LiteralPath $old)) 'Old clean zero-job session was retained.'
}
foreach($kind in @('failed','uncertain','incomplete','string-bool','string-count','unknown-file','nested-directory','nonempty-spool','readonly','corrupt-json','bad-sender','page-out-of-range')){
 Run-Case ('preserve_'+$kind) {
  $root=New-FixtureRoot $kind;$old=New-CleanSession $root 0;Fill-History $root 10
  $summary=Join-Path $old 'session-result.json';$job=Join-Path $old 'job-000001';$bridge=Join-Path $job 'bridge-result.json'
  switch($kind){
   failed {$d=Get-Content -LiteralPath $summary -Raw|ConvertFrom-Json;$d.state='INTERRUPTED_OR_FAILED_NO_RETRY';Save-Json $summary $d}
   uncertain {$d=Get-Content -LiteralPath $bridge -Raw|ConvertFrom-Json;$d.delivery_uncertain=$true;Save-Json $bridge $d}
   incomplete {$d=Get-Content -LiteralPath $summary -Raw|ConvertFrom-Json;$d.completed_pages=0;Save-Json $summary $d}
   string-bool {$d=Get-Content -LiteralPath $bridge -Raw|ConvertFrom-Json;$d.success='True';Save-Json $bridge $d}
   string-count {$d=Get-Content -LiteralPath $summary -Raw|ConvertFrom-Json;$d.completed_jobs='1';Save-Json $summary $d}
   unknown-file {[IO.File]::WriteAllText((Join-Path $job 'my-notes.txt'),'keep')}
   nested-directory {$null=New-Item -ItemType Directory -Path (Join-Path $job 'unknown')}
   nonempty-spool {[IO.File]::WriteAllText((Join-Path $old 'spool/active.pwg'),'keep')}
   readonly {(Get-Item -LiteralPath (Join-Path $old 'framework.log')).IsReadOnly=$true}
   corrupt-json {[IO.File]::WriteAllText($summary,'{invalid')}
   bad-sender {$d=Get-Content -LiteralPath (Join-Path $job 'sender-report.json') -Raw|ConvertFrom-Json;$d.transfer.delivery_uncertain=$true;Save-Json (Join-Path $job 'sender-report.json') $d}
   page-out-of-range {[IO.File]::WriteAllText((Join-Path $job 'page-02.qpdl'),'keep')}
  }
  $before=Snapshot $old;$report=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
  Check ((Snapshot $old) -ceq $before) ('Protected session modified: '+$kind)
 }
}
Run-Case 'reparse_preservation' {
 $root=New-FixtureRoot 'links';$old=New-CleanSession $root 0;Fill-History $root 10
 $outside=New-FixtureRoot 'external sentinel';[IO.File]::WriteAllText((Join-Path $outside 'keep.txt'),'never delete')
 $null=New-Item -ItemType Junction -Path (Join-Path $old 'job-000001/linked') -Target $outside
 $plan=Get-HousekeepingPlan $root;Check (@($plan.sessions | Where-Object path -eq $old).Count -eq 0) 'Linked session was eligible.'
 $null=Invoke-HousekeepingPlan $root $plan;Check ((Get-Content -LiteralPath (Join-Path $outside 'keep.txt') -Raw) -ceq 'never delete') 'Link target changed.'
}
Run-Case 'active_guards' {
 $root=New-FixtureRoot 'active';Fill-History $root;$plan=Get-HousekeepingPlan $root;$before=Snapshot $root
 [IO.File]::WriteAllText((Join-Path $root 'SESSION-ACTIVE.lock'),'active')
 $report=Invoke-HousekeepingPlan $root $plan;Check ($report.removed_sessions.Count -eq 0) 'Active session cleanup occurred.'
 [IO.File]::Delete((Join-Path $root 'SESSION-ACTIVE.lock'));Check ((Snapshot $root) -ceq $before) 'Data changed under lock.'
 $script:engine=$true;$report=Invoke-HousekeepingPlan $root $plan;Check ($report.removed_sessions.Count -eq 0) 'Engine guard failed.';$script:engine=$false
 $script:listener=$true;$report=Invoke-HousekeepingPlan $root $plan;Check ($report.removed_sessions.Count -eq 0) 'Endpoint guard failed.';$script:listener=$false
}
Run-Case 'changed_after_plan' {
 $root=New-FixtureRoot 'changed';Fill-History $root;$plan=Get-HousekeepingPlan $root;$old=$plan.sessions[0].path
 [IO.File]::WriteAllText((Join-Path $old 'unknown.txt'),'keep');$before=Snapshot $old
 $null=Invoke-HousekeepingPlan $root $plan;Check ((Snapshot $old) -ceq $before) 'Changed session not preserved.'
}
Run-Case 'partial_file_failure_retry' {
 $root=New-FixtureRoot 'retry';$old=New-CleanSession $root 0 2;Fill-History $root 10
 $locked=[IO.File]::Open((Join-Path $old 'job-000002/pages.index'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{$report=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root);Check ($report.removed_sessions.Count -eq 0) 'Locked session reported removed.'}finally{$locked.Dispose()}
 $next=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
 Check (!(Test-Path -LiteralPath $old)) 'Partial cleanup did not resume after releasing file.'
}
Run-Case 'locked_host_log_retry' {
 $root=New-FixtureRoot 'log retry';$old=New-CleanSession $root 0;Fill-History $root 10
 $log=Get-ChildItem -LiteralPath $root -Filter 'background-20260901-*.log'
 $locked=[IO.File]::Open($log.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{$null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)}finally{$locked.Dispose()}
 $null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
 Check (!(Test-Path -LiteralPath $old) -and !(Test-Path -LiteralPath $log.FullName)) 'Locked log association could not resume.'
}
Run-Case 'control_history_sorted_by_time_and_exports_preserved' {
 $root=New-FixtureRoot 'controls'
 foreach($i in 1..22){
  $stamp=([DateTime]'2026-09-01').AddDays($i).ToString('yyyyMMdd');$name='control-diagnostics-'+$stamp+'-120000-000-'+('a'*32)+'.json'
  Save-Json (Join-Path $root $name) @{schema_version=1;action='Diagnostics';outcome='DiagnosticsCollected';automatic_replay=$false}
 }
 $recent='control-cancel-20261014-120000-000-'+('b'*32)+'.json';Save-Json (Join-Path $root $recent) @{schema_version=1;action='Cancel';outcome='CancelAccepted'}
 foreach($name in @(('control-recover-20260901-120000-000-'+('c'*32)+'.json'),('control-cancel-20260901-120000-000-'+('d'*32)+'.json'))){Save-Json (Join-Path $root $name) @{schema_version=1;action='Recover';outcome='Refused'}}
 [IO.File]::WriteAllText((Join-Path $root 'diagnostics-example.zip'),'user export');[IO.File]::WriteAllText((Join-Path $root 'recovery-backup-example.zip'),'recovery data')
 $report=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
 Check (Test-Path -LiteralPath (Join-Path $root $recent)) 'Recent cancellation report deleted by action-prefix sorting.'
 Check (@(Get-ChildItem -LiteralPath $root -Filter '*.json').Count -eq 22) 'Wrong successful report retention.'
 Check (@(Get-ChildItem -LiteralPath $root -Filter '*.zip').Count -eq 2) 'Exports removed.'
}
Run-Case 'installed_wrapper_guard_and_receipt' {
 $base=New-FixtureRoot 'installed';$root=Join-Path $base 'data';$null=New-Item -ItemType Directory -Path $root;Fill-History $root
 Save-Json (Join-Path $base 'installation-complete.json') @{schema_version=1;state='Installed';data=$root;app=$PSScriptRoot}
 Invoke-InstalledHousekeeping $root
 Check (Test-Path -LiteralPath (Join-Path $root 'housekeeping-latest.json')) 'No housekeeping report.'
 Check (!(Test-Path -LiteralPath (Join-Path $root 'CONTROL-ACTIVE.lock'))) 'Guard leaked.'
 [IO.File]::WriteAllText((Join-Path $root 'CONTROL-ACTIVE.lock'),'other controller')
 try{Invoke-InstalledHousekeeping $root;throw 'Expected guard refusal.'}catch{Check (Test-Path -LiteralPath (Join-Path $root 'CONTROL-ACTIVE.lock')) 'Foreign guard was deleted.'}
}
Run-Case 'journal_tampering_preserved' {
 $root=New-FixtureRoot 'journal altered';$old=New-CleanSession $root 0 2;Fill-History $root 10
 $locked=[IO.File]::Open((Join-Path $old 'job-000002/pages.index'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{$null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)}finally{$locked.Dispose()}
 $journal=Get-HousekeepingJournalPath $root ([IO.Path]::GetFileName($old));Check (Test-Path -LiteralPath $journal) 'No resumable proof was created.'
 $receipt=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json;$receipt.summary_sha256='0'*64;Save-Json $journal $receipt
 $before=Snapshot $root;$null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root)
 Check ((Snapshot $root) -ceq $before) 'Tampered proof changed protected state.'
}
Run-Case 'rolled_off_jobs_and_large_residual_preserved' {
 $root=New-FixtureRoot 'rolled';$old=New-CleanSession $root 0;Fill-History $root 10
 $path=Join-Path $old 'session-result.json';$summary=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
 $summary.accepted_jobs=25;$summary.completed_jobs=25;$summary.accepted_pages=25;$summary.completed_pages=25;Save-Json $path $summary
 $null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root);Check (!(Test-Path -LiteralPath $old)) 'Already pruned in-session history prevented cleanup.'
 $older=New-CleanSession $root 0;$large=Join-Path $older 'job-000001/document.scxjob';$stream=[IO.File]::Open($large,'CreateNew','Write','None');try{$stream.SetLength(5MB)}finally{$stream.Dispose()}
 $before=Snapshot $older;$null=Invoke-HousekeepingPlan $root (Get-HousekeepingPlan $root);Check ((Snapshot $older) -ceq $before) 'Large residual payload did not preserve its session.'
}
Check ($script:loadedHousekeepingHash -ceq (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'housekeeping.ps1')).Hash) 'Runtime source changed during test execution.'
Save-Json (Join-Path $OutputRoot 'source-sha256.json') @{housekeeping=$script:loadedHousekeepingHash;test=(Get-FileHash -LiteralPath $PSCommandPath).Hash}
Run-Case 'mixed_case_replay_flag_preserved' {
 $report=[pscustomobject]@{schema_version=1;action='Cancel';outcome='CancelAccepted';Automatic_Replay=$true}
 Check (!(Test-HousekeepingControl $report)) 'Mixed-case replay flag bypassed preservation.'
}
Write-Output (Join-Path $OutputRoot 'results.json')
