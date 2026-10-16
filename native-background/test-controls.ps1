# SPDX-License-Identifier: Apache-2.0
param([string]$OutputRoot=(Join-Path $PSScriptRoot '../build/background/control-tests'))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'controls.ps1')
$script:out=[IO.Path]::GetFullPath((Join-Path $OutputRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N'))))
$null=New-Item -ItemType Directory -Path $script:out
$script:results=@();$script:realRecovery=${function:Invoke-BackgroundRecovery};$script:realCancel=${function:Invoke-CurrentJobCancellation};$script:realIpp=${function:Invoke-Ipp};$script:realIdentity=${function:Get-BridgeIdentity}
function Check($Condition,[string]$Why){if(!$Condition){throw $Why}}
function Refuses([scriptblock]$Body,[string]$Text){$caught=$null;try{& $Body}catch{$caught=$_.Exception.Message};Check ($caught -and $caught.Contains($Text)) ('Expected refusal: '+$Text+'; got '+$caught)}
function Get-Process {param($Name,$ErrorAction) if($script:engine){[pscustomobject]@{Id=901;Path=(Join-Path $PSScriptRoot 'SCX4200-Reliable-Bridge.exe');StartTime=[datetime]'2026-01-01'}}}
function Get-NetTCPConnection {param($State,$LocalPort,$ErrorAction) if($script:port){[pscustomobject]@{LocalPort=8631;LocalAddress='127.0.0.1';OwningProcess=901}}}
function Get-Printer {param($ErrorAction) [pscustomobject]@{Name='SCX-4200 Capture Test';DriverName=$script:driver;PortName='mock-port'}}
function Get-PrintJob {param($PrinterName,$ErrorAction) if($script:jobs){[pscustomobject]@{ID=32;JobStatus='Error'}}}
foreach($name in 'Remove-Printer','Remove-PrintJob','Set-PrintJob','Restart-Service','Start-Process'){Set-Item -Path ('function:'+ $name) -Value {throw 'Forbidden device or system mutation'}}
function Show-BackgroundControlMessage {param($Text,[switch]$Confirm) $script:messages+=@($Text);if($Confirm){if($script:confirmationHook){& $script:confirmationHook};return $script:confirm}}
function Case([string]$Name,[scriptblock]$Body){
 $script:root=Join-Path $script:out $Name;$null=New-Item -ItemType Directory -Path $script:root
 $script:data=Join-Path $script:root 'data';$null=New-Item -ItemType Directory -Path $script:data
 $script:lock=Join-Path $script:data 'SESSION-ACTIVE.lock';[IO.File]::WriteAllText($script:lock,'original-session')
 $script:receipt=@{schema_version=1;state='Installed';transaction_id=('a'*32);data=$script:data;app=$PSScriptRoot;queue=@{name='SCX-4200 Capture Test';driver='Microsoft IPP Class Driver';port='mock-port';uri='http://127.0.0.1:8631/ipp/print';owned=$false}}
 Write-BackgroundJson (Join-Path $script:root 'installation-complete.json') $script:receipt
 $script:context=@{path=$script:data;receipt=$script:receipt};$script:engine=$false;$script:port=$false;$script:jobs=$false;$script:driver='Microsoft IPP Class Driver';$script:confirm=$true;$script:confirmationHook=$null;$script:messages=@()
 Set-Item function:Invoke-BackgroundRecovery $script:realRecovery;Set-Item function:Invoke-CurrentJobCancellation $script:realCancel;Set-Item function:Get-BridgeIdentity $script:realIdentity;Set-Item function:Invoke-Ipp $script:realIpp
 try{& $Body;$script:results+=@{name=$Name;status='PASS'}}catch{$script:results+=@{name=$Name;status='FAIL';error=$_.Exception.Message};throw}
}
try{
 Case identity-valid {Check ((Get-BackgroundControlData $script:data).path -ceq $script:data) 'Valid identity rejected'}
 Case identity-mismatch {$script:receipt.app='C:\unrelated';[IO.File]::WriteAllText((Join-Path $script:root 'installation-complete.json'),($script:receipt|ConvertTo-Json -Depth 6));Refuses {Get-BackgroundControlData $script:data} 'identity'}
 Case path-relative {Refuses {Get-BackgroundControlData 'relative'} 'absolute local'}
 Case no-session {Remove-Item -LiteralPath $script:lock;Check ((Invoke-BackgroundRecovery $script:context).outcome -eq 'NoBlockedSession') 'Wrong empty outcome'}
 Case engine-active {$script:engine=$true;Refuses {Invoke-BackgroundRecovery $script:context} 'still running';Check (Test-Path $script:lock) 'Lock lost'}
 Case port-active {$script:port=$true;Refuses {Invoke-BackgroundRecovery $script:context} 'Port 8631'}
 Case jobs-present {$script:jobs=$true;Refuses {Invoke-BackgroundRecovery $script:context} 'Job 32';Check (Test-Path $script:lock) 'Lock lost'}
 Case queue-changed {$script:driver='wrong';Refuses {Invoke-BackgroundRecovery $script:context} 'identity changed'}
 Case declined {$script:confirm=$false;$before=Get-BackgroundHash $script:lock;$r=Invoke-BackgroundRecovery $script:context;Check ($r.outcome -eq 'UserDeclined' -and (Get-BackgroundHash $script:lock) -eq $before) 'Decline changed lock';Check (Test-Path (Join-Path $script:data $r.backup_archive)) 'No evidence archive'}
 Case readonly-lock {(Get-Item $script:lock).IsReadOnly=$true;try{Refuses {Invoke-BackgroundRecovery $script:context} 'writable regular';Check (Test-Path $script:lock) 'Readonly lock lost'}finally{(Get-Item $script:lock).IsReadOnly=$false}}
 Case reparse-lock {$target=Join-Path $script:data 'target';$null=New-Item -ItemType Directory -Path $target;Move-Item -LiteralPath $script:lock -Destination (Join-Path $target 'original');$null=New-Item -ItemType Junction -Path $script:lock -Target $target;Refuses {Invoke-BackgroundRecovery $script:context} 'Linked';Check (Test-Path (Join-Path $target 'original')) 'Target lost'}
 Case archive-failure {$run=Join-Path $script:data 'bridge-20260101';$null=New-Item -ItemType Directory -Path $run;$file=Join-Path $run 'held';[IO.File]::WriteAllText($file,'evidence');$held=[IO.File]::Open($file,'Open','ReadWrite','None');try{Refuses {Invoke-BackgroundRecovery $script:context} 'used by another process';Check (Test-Path $script:lock) 'Lock lost'}finally{$held.Dispose()}}
 Case archive-reparse {$run=Join-Path $script:data 'bridge-20260101';$target=Join-Path $script:root 'linked-target';$null=New-Item -ItemType Directory -Path $target;$null=New-Item -ItemType Junction -Path $run -Target $target;Refuses {Invoke-BackgroundRecovery $script:context} 'Linked';Check (Test-Path $script:lock) 'Lock lost'}
 Case archive-preserves-pages {$run=Join-Path $script:data 'bridge-20260101';$null=New-Item -ItemType Directory -Path $run;$page=Join-Path $run 'page.qpdl';[IO.File]::WriteAllText($page,'private page bytes');$before=Get-BackgroundHash $page;$r=Invoke-BackgroundRecovery $script:context;Check ((Get-BackgroundHash $page) -eq $before) 'Original page changed';$s=[IO.File]::OpenRead((Join-Path $script:data $r.backup_archive));try{$z=[IO.Compression.ZipArchive]::new($s,[IO.Compression.ZipArchiveMode]::Read);try{$entry=$z.GetEntry('bridge-20260101/page.qpdl');Check ($null -ne $entry) 'Page missing from archive';$reader=[IO.StreamReader]::new($entry.Open());try{Check ($reader.ReadToEnd() -eq 'private page bytes') 'Archived page changed'}finally{$reader.Dispose()}}finally{$z.Dispose()}}finally{$s.Dispose()}}
 Case engine-recheck {$script:confirmationHook={$script:engine=$true};Refuses {Invoke-BackgroundRecovery $script:context} 'still running'}
 Case port-recheck {$script:confirmationHook={$script:port=$true};Refuses {Invoke-BackgroundRecovery $script:context} 'Port 8631'}
 Case jobs-recheck {$script:confirmationHook={$script:jobs=$true};Refuses {Invoke-BackgroundRecovery $script:context} 'Job 32'}
 Case lock-changed {$script:confirmationHook={[IO.File]::WriteAllText($script:lock,'new-session')};Refuses {Invoke-BackgroundRecovery $script:context} 'lock changed';Check ([IO.File]::ReadAllText($script:lock) -eq 'new-session') 'Changed lock lost'}
 Case success-receipt {$before=Get-BackgroundHash $script:lock;Invoke-BackgroundControl $script:data 'Recover';Check (!(Test-Path $script:lock)) 'Lock not renamed';Check (!(Test-Path (Join-Path $script:data 'CONTROL-ACTIVE.lock'))) 'Guard leaked';$report=Get-Content (Get-ChildItem $script:data -Filter 'control-recover-*.json').FullName -Raw|ConvertFrom-Json;Check ($report.outcome -eq 'Recovered' -and !$report.automatic_replay) 'Wrong receipt';$saved=Join-Path $script:data $report.backup_lock;Check ((Get-BackgroundHash $saved) -eq $before) 'Renamed bytes changed';[IO.File]::Move($saved,$script:lock);Check ((Get-BackgroundHash $script:lock) -eq $before) 'Rename not reversible'}
 Case guard-existing {$guard=Join-Path $script:data 'CONTROL-ACTIVE.lock';[IO.File]::WriteAllText($guard,'existing');Invoke-BackgroundControl $script:data 'Recover';Check ([IO.File]::ReadAllText($guard) -eq 'existing') 'Foreign guard deleted';Check (Test-Path $script:lock) 'Lock lost'}
 Case guard-failure-cleanup {$script:engine=$true;Invoke-BackgroundControl $script:data 'Recover';Check (!(Test-Path (Join-Path $script:data 'CONTROL-ACTIVE.lock'))) 'Guard leaked on refusal';Check (Test-Path $script:lock) 'Lock lost'}
 Case mutex-busy {
  $ready=[Threading.ManualResetEventSlim]::new();$release=[Threading.ManualResetEventSlim]::new();$worker=[PowerShell]::Create()
  $null=$worker.AddScript({param($Ready,$Release) $m=[Threading.Mutex]::new($false,'Local\SCX4200.ControlGate');$null=$m.WaitOne();try{$Ready.Set();$Release.Wait()}finally{$m.ReleaseMutex();$m.Dispose()}}).AddArgument($ready).AddArgument($release);$async=$worker.BeginInvoke()
  try{Check ($ready.Wait(10000)) 'Mutex holder failed';Invoke-BackgroundControl $script:data 'Recover';Check (Test-Path $script:lock) 'Busy recovery changed lock';Check (($script:messages -join '') -match 'Another printer operation') 'Busy not reported'}finally{$release.Set();$null=$worker.EndInvoke($async);$worker.Dispose();$ready.Dispose();$release.Dispose()}
 }
 Case cancellation-same-bridge {
  $script:engine=$true;$script:port=$true;$script:cancels=@();function Invoke-Ipp {param($operation,$jobId) if($operation -eq 10){return @{Groups=@(@{Tag=2;Attributes=@{'job-id'=@(17);'job-state'=@(5)}})}};$script:cancels+=@($jobId);return @{}}
  $r=Invoke-CurrentJobCancellation;Check ($r.outcome -eq 'CancelAccepted' -and $script:cancels.Count -eq 1 -and $script:cancels[0] -eq 17) 'Wrong cancellation'
 }
 Case cancellation-identity-changed {
  $script:engine=$true;$script:port=$true;$script:cancels=@();function Invoke-Ipp {param($operation,$jobId) if($operation -eq 10){$script:engine=$false;return @{Groups=@(@{Tag=2;Attributes=@{'job-id'=@(17);'job-state'=@(5)}})}};$script:cancels+=@($jobId)}
  $r=Invoke-CurrentJobCancellation;Check ($r.outcome -eq 'Failed' -and $script:cancels.Count -eq 0 -and $r.error -match 'Bridge changed') 'Changed process cancellation unsafe'
 }
 Case cancellation-ambiguous {
  $script:engine=$true;$script:port=$true;$script:cancels=@();function Invoke-Ipp {param($operation,$jobId) if($operation -eq 10){return @{Groups=@(@{Tag=2;Attributes=@{'job-id'=@(17);'job-state'=@(5)}},@{Tag=2;Attributes=@{'job-id'=@(18);'job-state'=@(5)}})}};$script:cancels+=@($jobId)}
  $r=Invoke-CurrentJobCancellation;Check ($r.outcome -eq 'Failed' -and $script:cancels.Count -eq 0) 'Ambiguous cancel unsafe'
 }
 Case cancellation-listener-owner {
  $script:engine=$true;$script:port=$true;function Get-NetTCPConnection {param($State,$LocalPort,$ErrorAction) [pscustomobject]@{LocalPort=8631;LocalAddress='127.0.0.1';OwningProcess=999}}
  Refuses {Get-BridgeIdentity} 'does not belong exclusively'
 }
 Case invalid-action {Invoke-BackgroundControl $script:data 'Other';Check (($script:messages -join '') -match 'Choose Cancel, Recover or Diagnostics') 'Invalid action not refused';Check (Test-Path $script:lock) 'Lock lost'}
 Case diagnostics-content {
  [IO.File]::WriteAllText((Join-Path $script:data 'control-old.json'),'{}');[IO.File]::WriteAllText((Join-Path $script:data 'installation-complete.json'),'private receipt');[IO.File]::WriteAllText((Join-Path $script:data 'recovery-backup.zip'),'private pages')
  foreach($i in 1..3){$run=Join-Path $script:data ('bridge-2026010'+$i);$job=Join-Path $run 'job-000001';$null=New-Item -ItemType Directory -Path $job -Force;foreach($name in 'session-result.json','framework.log'){[IO.File]::WriteAllText((Join-Path $run $name),('safe '+$name))};foreach($name in 'sender-report.json','page-01.qpdl.json','page-01.pgm','page-01.pwg','page-01.qpdl','document.scxjob'){[IO.File]::WriteAllText((Join-Path $job $name),'test bytes')};[IO.File]::WriteAllText((Join-Path $script:data ('background-'+$i+'.log')),'safe log')}
  $before=Get-BackgroundHash $script:lock;Invoke-BackgroundControl $script:data 'Diagnostics';Check ((Get-BackgroundHash $script:lock) -eq $before) 'Diagnostics altered lock'
  $r=Get-Content (Get-ChildItem $script:data -Filter 'control-diagnostics-*.json').FullName -Raw|ConvertFrom-Json;Check ($r.outcome -eq 'DiagnosticsCollected' -and !$r.page_data_included) 'No successful diagnostics receipt'
  $s=[IO.File]::OpenRead((Join-Path $script:data $r.archive));try{$z=[IO.Compression.ZipArchive]::new($s,[IO.Compression.ZipArchiveMode]::Read);try{$names=@($z.Entries|ForEach-Object FullName);Check (@($names|Where-Object {$_ -match '(^|/)framework\.log$'}).Count -eq 2) 'Framework log bound';Check (@($names|Where-Object {$_ -match '^background-.*\.log$'}).Count -eq 2) 'Background log bound';Check (@($names|Where-Object {$_ -match 'session-result\.json$'}).Count -eq 3) 'Session reports absent';Check (@($names|Where-Object {$_ -match 'sender-report\.json$'}).Count -eq 3) 'Job reports absent';Check ($names -contains 'control-old.json') 'Controls absent';Check (!@($names|Where-Object {$_ -match '\.(pgm|pwg|qpdl|scxjob|zip)$|installation-complete|SESSION-ACTIVE'}).Count) 'Private captures included';Check ($z.Entries.Count -eq 14) 'Unexpected archive contents'}finally{$z.Dispose()}}finally{$s.Dispose()}
  Check (($script:messages -join '') -match 'Review the contents before sharing') 'Privacy review message absent';Check (!(Test-Path (Join-Path $script:data 'CONTROL-ACTIVE.lock'))) 'Diagnostic guard leaked'
 }
 Case diagnostics-reparse {$target=Join-Path $script:root 'target';$null=New-Item -ItemType Directory -Path $target;$null=New-Item -ItemType Junction -Path (Join-Path $script:data 'bridge-20260101') -Target $target;Refuses {New-BackgroundDiagnostics $script:data} 'Linked';Check (Test-Path $script:lock) 'Lock lost'}
 Case diagnostics-file-cap {foreach($i in 1..501){[IO.File]::WriteAllText((Join-Path $script:data ('control-'+$i+'.json')),'{}')};Invoke-BackgroundControl $script:data 'Diagnostics';Check (($script:messages -join '') -match '500-file') 'File cap not refused';Check (!(Test-Path (Join-Path $script:data 'CONTROL-ACTIVE.lock'))) 'Cap guard leaked';Check (!@(Get-ChildItem $script:data -Filter 'diagnostics-*.zip').Count) 'Oversize zip created';$r=Get-Content (Get-ChildItem $script:data -Filter 'control-diagnostics-*.json').FullName -Raw|ConvertFrom-Json;Check ($r.outcome -eq 'Refused') 'Cap refusal receipt missing'}
 Case diagnostics-byte-cap {$path=Join-Path $script:data 'background-big.log';$s=[IO.File]::Open($path,'CreateNew','Write','None');try{$s.SetLength(21MB)}finally{$s.Dispose()};Refuses {New-BackgroundDiagnostics $script:data} '20 MiB';Check (!@(Get-ChildItem $script:data -Filter 'diagnostics-*.zip').Count) 'Oversize zip created';Check ((Get-Item $path).Length -eq 21MB) 'Original oversized log altered'}
}finally{
 $summary=@{schema_version=1;device_free=$true;status=if(@($script:results|Where-Object status -eq 'FAIL').Count){'FAIL'}else{'PASS'};tests=$script:results}
 Write-BackgroundJson (Join-Path $script:out 'results.json') $summary
 Write-Host ($summary.status+': '+$script:results.Count+' groups; '+$script:out)
}
