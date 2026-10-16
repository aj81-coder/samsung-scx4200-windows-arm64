# SPDX-License-Identifier: Apache-2.0
# Safe, stopped-session housekeeping. No recursive deletion, queue or USB access.
param([string]$DataDir)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'setup.ps1')
function Assert-HousekeepingEntry([string]$Root,[string]$Path,[bool]$Directory){
 $full=Assert-BackgroundSafePath $Path
 $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
 if(!$full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Cleanup target is outside the data directory.'}
 $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
 if($item.PSIsContainer -ne $Directory -or ($item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::ReadOnly))){throw 'Linked, readonly or unexpected cleanup entry.'}
 return $item
}
function Read-HousekeepingJson([string]$Root,[string]$Path){
 $item=Assert-HousekeepingEntry $Root $Path $false
 if($item.Length -gt 65536){throw 'Unexpectedly large cleanup metadata.'}
 $value=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
 if($value -isnot [pscustomobject]){throw 'Cleanup metadata must be a JSON object.'}
 return $value
}
function Test-HousekeepingCount($Value){
 return ($Value -is [int] -or $Value -is [long]) -and $Value -ge 0
}
function Test-HousekeepingBool($Value,[bool]$Expected){return $Value -is [bool] -and $Value -eq $Expected}
function Test-HousekeepingHash($Value){return $Value -is [string] -and $Value -cmatch '^[a-fA-F0-9]{64}$'}
function Get-HousekeepingFileHash([string]$Path){
 # Avoid cmdlet autoload dependencies in native ARM64 Windows PowerShell.
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$sha.Dispose();$stream.Dispose()}
}
function Read-HousekeepingProof($Encoded,[string]$ExpectedHash){
 if($Encoded -isnot [string] -or !(Test-HousekeepingHash $ExpectedHash)){throw 'Invalid journal receipt encoding.'}
 $bytes=[Convert]::FromBase64String($Encoded);$sha=[Security.Cryptography.SHA256]::Create()
 try{$actual=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
 if($actual -ine $ExpectedHash){throw 'Journal receipt hash mismatch.'}
 $value=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff) | ConvertFrom-Json
 if($value -isnot [pscustomobject]){throw 'Invalid journal receipt object.'};return $value
}
function Assert-HousekeepingSummary($Summary){
 if($Summary -isnot [pscustomobject] -or $Summary.version -isnot [string] -or $Summary.state -isnot [string] -or @('0.11.0-background-dev','0.12.0-general-dev') -cnotcontains $Summary.version -or $Summary.state -cne 'CLEAN_SHUTDOWN' -or !(Test-HousekeepingBool $Summary.blocked $false) -or !(Test-HousekeepingBool $Summary.mock_transport $false) -or !(Test-HousekeepingBool $Summary.automatic_retry $false)){throw 'Session is not a recognized clean production session.'}
 foreach($field in @('accepted_jobs','completed_jobs','accepted_pages','completed_pages')){if(!(Test-HousekeepingCount $Summary.$field)){throw 'Invalid session counts.'}}
 if($Summary.accepted_jobs -ne $Summary.completed_jobs -or $Summary.accepted_pages -ne $Summary.completed_pages -or $Summary.completed_jobs -gt $Summary.completed_pages -or ($Summary.completed_jobs -eq 0 -and $Summary.completed_pages -ne 0)){throw 'Session is not wholly completed.'}
}
function Assert-HousekeepingJob($Result,$Sender,$Summary,[long]$JobId){
 if($Result -isnot [pscustomobject] -or $Result.version -isnot [string] -or $Result.architecture -isnot [string] -or $Result.result -isnot [string] -or $Result.version -cne $Summary.version -or @('ARM64','x64') -cnotcontains $Result.architecture -or !(Test-HousekeepingCount $Result.job_id) -or $Result.job_id -ne $JobId -or $Result.result -cne 'USB_WRITE_COMPLETED_PHYSICAL_OUTPUT_UNCONFIRMED'){throw 'Job identity is not a successful production job.'}
 foreach($field in @('success','acknowledged_bytes_known')){if(!(Test-HousekeepingBool $Result.$field $true)){throw 'Invalid successful-job Boolean.'}}
 foreach($field in @('mock_transport','delivery_uncertain','automatic_retry')){if(!(Test-HousekeepingBool $Result.$field $false)){throw 'Uncertain, mock or replayed job.'}}
 foreach($field in @('document_pages','job_bytes','usb_bytes','bundle_bytes','acknowledged_bytes')){if(!(Test-HousekeepingCount $Result.$field) -or $Result.$field -le 0){throw 'Invalid completed-job counters.'}}
 if($Result.acknowledged_bytes -ne $Result.job_bytes -or $Result.usb_bytes -ne $Result.job_bytes -or !(Test-HousekeepingHash $Result.bundle_sha256) -or !(Test-HousekeepingHash $Result.rows_sha256)){throw 'Invalid completed-job bytes or hashes.'}
 if($Sender -isnot [pscustomobject] -or $Sender.result -isnot [string] -or $Sender.build_architecture -isnot [string] -or $Sender.result -cne $Result.result -or $Sender.build_architecture -cne $Result.architecture -or !(Test-HousekeepingHash $Sender.job_sha256) -or $Sender.job_sha256 -ine $Result.bundle_sha256 -or !(Test-HousekeepingBool $Sender.check_only $false)){throw 'Sender proof does not match completed job.'}
 foreach($field in @('job_hash_verified','exclusive_read_write_open','bridge_permit_consumed')){if(!(Test-HousekeepingBool $Sender.$field $true)){throw 'Sender proof is incomplete.'}}
 foreach($field in @('job_bytes','bundle_bytes','document_pages')){if(!(Test-HousekeepingCount $Sender.$field) -or $Sender.$field -ne $Result.$field){throw 'Sender counters do not match completed job.'}}
 $transfer=$Sender.transfer
 if($transfer -isnot [pscustomobject] -or !(Test-HousekeepingBool $transfer.attempted $true)){throw 'Sender transfer proof is missing.'}
 foreach($field in @('delivery_uncertain','timed_out','cancellation_pending')){if(!(Test-HousekeepingBool $transfer.$field $false)){throw 'Sender transfer is uncertain.'}}
 if(!(Test-HousekeepingCount $transfer.acknowledged_bytes) -or $transfer.acknowledged_bytes -ne $Result.job_bytes -or !(Test-HousekeepingCount $transfer.pages_data_completed) -or $transfer.pages_data_completed -ne $Result.document_pages -or !(Test-HousekeepingCount $transfer.win32_error) -or $transfer.win32_error -ne 0){throw 'Sender transfer counters conflict.'}
}
function Get-HousekeepingJournalPath([string]$Root,[string]$Name){return Join-Path $Root ('housekeeping-'+$Name+'.json')}
function Test-HousekeepingControl($Report){
 if($Report -isnot [pscustomobject] -or $Report.action -isnot [string] -or $Report.outcome -isnot [string] -or !(Test-HousekeepingCount $Report.schema_version) -or $Report.schema_version -ne 1){return $false}
 # The shipped IPP Cancel report predates automatic_replay. Its absence is
 # recognized only for Cancel; present values must always be Boolean false.
 if($Report.PSObject.Properties.Name -contains 'automatic_replay'){
  if(!(Test-HousekeepingBool $Report.automatic_replay $false)){return $false}
 }elseif($Report.action -cne 'Cancel'){return $false}
 return ($Report.action -ceq 'Cancel' -and @('CancelAccepted','NoProcessingJob','NoBridgeProcess') -ccontains $Report.outcome) -or ($Report.action -ceq 'Diagnostics' -and $Report.outcome -ceq 'DiagnosticsCollected')
}
function Get-HousekeepingSession([string]$Root,$Run,[switch]$AllowMissing){
 if($AllowMissing -and !(Test-Path -LiteralPath $Run.FullName)){$null=Assert-BackgroundSafePath $Run.FullName}else{$null=Assert-HousekeepingEntry $Root $Run.FullName $true}
 if($Run.Name -cnotmatch '^bridge-\d{8}-\d{6}-\d{3}-\d+$'){throw 'Unrecognized session directory.'}
 $summaryPath=Join-Path $Run.FullName 'session-result.json';$journalPath=Get-HousekeepingJournalPath $Root $Run.Name;$journal=$null
 if(Test-Path -LiteralPath $journalPath){
  $journal=Read-HousekeepingJson $Root $journalPath
  if(!(Test-HousekeepingCount $journal.schema_version) -or $journal.schema_version -ne 1 -or $journal.purpose -cne 'SCX4200CleanSessionCleanup' -or $journal.name -cne $Run.Name -or !(Test-HousekeepingHash $journal.summary_sha256)){throw 'Invalid cleanup journal identity.'}
  $journal | Add-Member -NotePropertyName summary -NotePropertyValue (Read-HousekeepingProof $journal.summary_base64 $journal.summary_sha256)
  Assert-HousekeepingSummary $journal.summary
  if($null -eq $journal.jobs -or $null -eq $journal.files -or $null -eq $journal.directories -or $null -eq $journal.logs){throw 'Incomplete cleanup journal.'}
 }
 if(Test-Path -LiteralPath $summaryPath){
  $summary=Read-HousekeepingJson $Root $summaryPath;$summaryHash=Get-HousekeepingFileHash $summaryPath
  if($journal -and $summaryHash -ine $journal.summary_sha256){throw 'Session summary changed during cleanup.'}
 }elseif($journal){$summary=$journal.summary;$summaryHash=$journal.summary_sha256}else{throw 'Session summary unavailable.'}
 Assert-HousekeepingSummary $summary
 $files=New-Object Collections.ArrayList;$directories=New-Object Collections.ArrayList;$proofs=New-Object Collections.ArrayList
 [long]$jobs=0;[long]$pages=0;[long]$totalBytes=0;[int]$fileCount=0
 $seenJobs=@{}
 if($journal){
  foreach($proof in @($journal.jobs)){
   if($proof.name -isnot [string] -or $proof.name -cnotmatch '^job-(\d{6,10})$' -or $seenJobs.ContainsKey($proof.name)){throw 'Invalid or duplicated journal job.'}
   $jobId=[long]$Matches[1]
   $resultSnapshot=@($journal.files | Where-Object relative -ceq ($proof.name+'\bridge-result.json'))
   $senderSnapshot=@($journal.files | Where-Object relative -ceq ($proof.name+'\sender-report.json'))
   if($resultSnapshot.Count -ne 1 -or $senderSnapshot.Count -ne 1){throw 'Journal job receipt snapshots are missing.'}
   $proof | Add-Member -NotePropertyName result -NotePropertyValue (Read-HousekeepingProof $proof.result_base64 $resultSnapshot[0].sha256)
   $proof | Add-Member -NotePropertyName sender -NotePropertyValue (Read-HousekeepingProof $proof.sender_base64 $senderSnapshot[0].sha256)
   Assert-HousekeepingJob $proof.result $proof.sender $summary $jobId
   $seenJobs[$proof.name]=$proof;$jobs++;$pages+=$proof.result.document_pages
  }
 }
 $entries=@();if(Test-Path -LiteralPath $Run.FullName){$entries=@(Get-ChildItem -LiteralPath $Run.FullName -Force)}
 foreach($entry in $entries){
  if($entry.PSIsContainer){
   $null=Assert-HousekeepingEntry $Root $entry.FullName $true
   if($entry.Name -ceq 'spool'){
    if(@(Get-ChildItem -LiteralPath $entry.FullName -Force).Count){throw 'Spool is not empty.'}
    [void]$directories.Add($entry.FullName);continue
   }
   if($entry.Name -cnotmatch '^job-(\d{6,10})$'){throw 'Unknown session subdirectory.'}
   $jobId=[long]$Matches[1]
   $resultPath=Join-Path $entry.FullName 'bridge-result.json';$senderPath=Join-Path $entry.FullName 'sender-report.json'
   if($journal){
    if(!$seenJobs.ContainsKey($entry.Name)){throw 'New job appeared during cleanup.'}
    $proof=$seenJobs[$entry.Name];$result=$proof.result;$sender=$proof.sender
    if(Test-Path -LiteralPath $resultPath){$result=Read-HousekeepingJson $Root $resultPath}
    if(Test-Path -LiteralPath $senderPath){$sender=Read-HousekeepingJson $Root $senderPath}
   }else{
    $result=Read-HousekeepingJson $Root $resultPath;$sender=Read-HousekeepingJson $Root $senderPath
    Assert-HousekeepingJob $result $sender $summary $jobId
    [void]$proofs.Add([pscustomobject]@{name=$entry.Name;result_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($resultPath));sender_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($senderPath))});$jobs++;$pages+=$result.document_pages
   }
   Assert-HousekeepingJob $result $sender $summary $jobId
   foreach($file in @(Get-ChildItem -LiteralPath $entry.FullName -Force)){
    $null=Assert-HousekeepingEntry $Root $file.FullName $false
    $totalBytes+=$file.Length;$fileCount++
    if($file.Length -gt 4MB -or $fileCount -gt 256 -or $totalBytes -gt 16MB){throw 'Residual session files exceed the conservative startup cleanup budget.'}
    if($file.Name -ceq 'bridge-result.json'){continue}
    if(@('sender-report.json','sender-progress.json','SEND_STARTED.json','pages.index','document.scxjob') -cnotcontains $file.Name){
     if($file.Name -cnotmatch '^page-(\d{2,10})\.(pgm|qpdl|json|qpdl\.json)$' -or [long]$Matches[1] -lt 1 -or [long]$Matches[1] -gt $result.document_pages){throw 'Unknown job file.'}
    }
    [void]$files.Add($file.FullName)
   }
   # Keep the success marker until every payload in this job has been removed.
   if(Test-Path -LiteralPath $resultPath){[void]$files.Add($resultPath)};[void]$directories.Add($entry.FullName)
  }else{
   $null=Assert-HousekeepingEntry $Root $entry.FullName $false
   $totalBytes+=$entry.Length;$fileCount++
   if($entry.Length -gt 4MB -or $fileCount -gt 256 -or $totalBytes -gt 16MB){throw 'Session files exceed the conservative startup cleanup budget.'}
   if(@('framework.log','framework.log.O','session-result.json') -cnotcontains $entry.Name){throw 'Unknown session file.'}
   if($entry.Name -cne 'session-result.json'){[void]$files.Add($entry.FullName)}
  }
 }
 # The in-process ring may already have removed earlier successful job folders.
 if($jobs -gt $summary.completed_jobs -or $pages -gt $summary.completed_pages){throw 'Remaining job counts conflict with session summary.'}
 if($journal){
  $known=@{};$knownDirs=@{}
  foreach($item in @($journal.files)){
   if($item.relative -isnot [string] -or $item.relative -cnotmatch '^(framework\.log(\.O)?|session-result\.json|job-\d{6,10}\\(bridge-result\.json|sender-report\.json|sender-progress\.json|SEND_STARTED\.json|pages\.index|document\.scxjob|page-\d{2,10}\.(pgm|qpdl|json|qpdl\.json)))$' -or !(Test-HousekeepingHash $item.sha256) -or $known.ContainsKey($item.relative)){throw 'Invalid journal file snapshot.'}
   $known[$item.relative]=$item.sha256
  }
  foreach($relative in @($journal.directories)){if($relative -isnot [string] -or $relative -cnotmatch '^(spool|job-\d{6,10})$' -or $knownDirs.ContainsKey($relative)){throw 'Invalid journal directory snapshot.'};$knownDirs[$relative]=$true}
  $present=@($files.ToArray());if(Test-Path -LiteralPath $summaryPath){$present+=@($summaryPath)}
  foreach($path in $present){$relative=$path.Substring($Run.FullName.Length+1);if(!$known.ContainsKey($relative) -or (Get-HousekeepingFileHash $path) -ine $known[$relative]){throw 'Session file changed after cleanup snapshot.'}}
  foreach($path in @($directories.ToArray())){if(!$knownDirs.ContainsKey($path.Substring($Run.FullName.Length+1))){throw 'Session directory changed after cleanup snapshot.'}}
  if(!$known.ContainsKey('session-result.json') -or $known['session-result.json'] -ine $journal.summary_sha256){throw 'Journal summary snapshot is inconsistent.'}
  $logNames=@{}
  foreach($log in @($journal.logs)){
   if($log.name -isnot [string] -or $log.name -cnotmatch '^background-\d{8}-\d{6}-\d+-\d+\.log$' -or !(Test-HousekeepingHash $log.sha256) -or $logNames.ContainsKey($log.name)){throw 'Invalid journal log snapshot.'};$logNames[$log.name]=$true
   $logPath=Join-Path $Root $log.name
   if(Test-Path -LiteralPath $logPath){
    $item=Assert-HousekeepingEntry $Root $logPath $false
    if($item.Length -gt 4MB -or (Get-HousekeepingFileHash $logPath) -ine $log.sha256){throw 'Host log changed during cleanup.'}
    $references=[regex]::Matches([IO.File]::ReadAllText($logPath,[Text.Encoding]::UTF8),'(?m)^Results: (bridge-\d{8}-\d{6}-\d{3}-\d+)\r?$')
    if($references.Count -ne 1 -or $references[0].Groups[1].Value -cne $Run.Name){throw 'Cleanup journal host log does not belong to this session.'}
   }
  }
 }
 return [pscustomobject]@{name=$Run.Name;path=$Run.FullName;files=@($files.ToArray());directories=@($directories.ToArray());summary=$summaryPath;summary_value=$summary;summary_hash=$summaryHash;jobs=@($proofs.ToArray());journal=$journal;journal_path=$journalPath}
}
function Get-HousekeepingPlan([string]$Root){
 $eligible=New-Object Collections.ArrayList;$preserved=New-Object Collections.ArrayList;$orphans=New-Object Collections.ArrayList
 foreach($run in @(Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object Name -cmatch '^bridge-')){
  try{[void]$eligible.Add((Get-HousekeepingSession $Root $run))}catch{[void]$preserved.Add([ordered]@{name=$run.Name;reason=$_.Exception.Message})}
 }
 foreach($file in @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object Name -cmatch '^housekeeping-bridge-\d{8}-\d{6}-\d{3}-\d+\.json$')){
  $name=$file.Name.Substring(13,$file.Name.Length-18);$path=Join-Path $Root $name
  if(Test-Path -LiteralPath $path){continue}
  try{
   $proof=Get-HousekeepingSession $Root ([pscustomobject]@{Name=$name;FullName=$path}) -AllowMissing
   if(!$proof.journal){throw 'Cleanup journal proof is missing.'}
   foreach($log in @($proof.journal.logs)){if(Test-Path -LiteralPath (Join-Path $Root $log.name)){throw 'A completed cleanup still has a host log.'}}
   [void]$orphans.Add($proof)
  }catch{[void]$preserved.Add([ordered]@{name=$file.Name;reason=$_.Exception.Message})}
 }
 $ordered=@($eligible.ToArray() | Sort-Object name -Descending)
 $pending=@($ordered | Where-Object {$_.journal})
 $normal=@($ordered | Where-Object {!$_.journal})
 $prune=@($pending)+@($normal | Select-Object -Skip 10);$logs=New-Object Collections.ArrayList
 foreach($file in @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object Name -cmatch '^background-\d{8}-\d{6}-\d+-\d+\.log$')){
  try{
   $item=Assert-HousekeepingEntry $Root $file.FullName $false
   if($item.Length -gt 4MB){continue}
   $text=[IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8)
   $matches=[regex]::Matches($text,'(?m)^Results: (bridge-\d{8}-\d{6}-\d{3}-\d+)\r?$')
   if($matches.Count -eq 1 -and @($prune | Where-Object name -ceq $matches[0].Groups[1].Value).Count -eq 1){[void]$logs.Add([pscustomobject]@{path=$file.FullName;session=$matches[0].Groups[1].Value})}
  }catch{[void]$preserved.Add([ordered]@{name=$file.Name;reason=$_.Exception.Message})}
 }
 $controls=New-Object Collections.ArrayList
 foreach($file in @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object Name -cmatch '^control-(cancel|diagnostics)-\d{8}-\d{6}-\d{3}-[a-f0-9]{32}\.json$')){
  try{
   $report=Read-HousekeepingJson $Root $file.FullName
   if(Test-HousekeepingControl $report){[void]$controls.Add([pscustomobject]@{FullName=$file.FullName;Name=$file.Name;stamp=([regex]::Match($file.Name,'\d{8}-\d{6}-\d{3}').Value);sha256=(Get-HousekeepingFileHash $file.FullName)})}
  }catch{[void]$preserved.Add([ordered]@{name=$file.Name;reason=$_.Exception.Message})}
 }
 return [pscustomobject]@{sessions=$prune;orphan_journals=@($orphans.ToArray());logs=@($logs.ToArray());controls=@($controls.ToArray() | Sort-Object stamp,Name -Descending | Select-Object -Skip 20);retained_sessions=[Math]::Min(10,$normal.Count);preserved=@($preserved.ToArray())}
}
function Assert-HousekeepingStopped([string]$Root){
 if(Test-Path -LiteralPath (Join-Path $Root 'SESSION-ACTIVE.lock')){throw 'Session lock present; housekeeping is deferred.'}
 if(@(Get-Process -Name SCX4200-Reliable-Bridge -ErrorAction SilentlyContinue).Count){throw 'A print engine is running; housekeeping is deferred.'}
 if(@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -eq 8631).Count){throw 'The printer endpoint is active; housekeeping is deferred.'}
}
function Remove-HousekeepingFile([string]$Root,[string]$Path){Assert-HousekeepingStopped $Root;$null=Assert-HousekeepingEntry $Root $Path $false;[IO.File]::Delete($Path)}
function Invoke-HousekeepingPlan([string]$Root,$Plan){
 $deleted=New-Object Collections.ArrayList;$errors=New-Object Collections.ArrayList;$completed=New-Object Collections.ArrayList
 foreach($session in $Plan.sessions){
  try{
   Assert-HousekeepingStopped $Root
   $current=Get-HousekeepingSession $Root (Get-Item -LiteralPath $session.path -Force)
   if((@($current.files | Sort-Object) -join "`n") -cne (@($session.files | Sort-Object) -join "`n")){throw 'Session contents changed after planning.'}
   if(!$current.journal){
    $snapshot=New-Object Collections.ArrayList
    foreach($path in @($current.files)+@($current.summary)){[void]$snapshot.Add([ordered]@{relative=$path.Substring($current.path.Length+1);sha256=(Get-HousekeepingFileHash $path)})}
    $logs=New-Object Collections.ArrayList
    foreach($log in @($Plan.logs | Where-Object session -ceq $current.name)){$null=Assert-HousekeepingEntry $Root $log.path $false;[void]$logs.Add([ordered]@{name=[IO.Path]::GetFileName($log.path);sha256=(Get-HousekeepingFileHash $log.path)})}
    $journal=[ordered]@{schema_version=1;purpose='SCX4200CleanSessionCleanup';name=$current.name;summary_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($current.summary));summary_sha256=$current.summary_hash;jobs=@($current.jobs);files=@($snapshot.ToArray());directories=@($current.directories | ForEach-Object {$_.Substring($current.path.Length+1)});logs=@($logs.ToArray())}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($journal | ConvertTo-Json -Depth 20))
    if($bytes.Length -gt 65536){throw 'Cleanup journal would exceed its bounded metadata size.'}
    Assert-HousekeepingStopped $Root;$null=Assert-BackgroundSafePath $current.journal_path
    $stream=[IO.File]::Open($current.journal_path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    $current=Get-HousekeepingSession $Root (Get-Item -LiteralPath $session.path -Force)
   }
   # Keep the job receipts and clean summary through all payload/log deletion.
   # The external, bounded journal remains until directory removal succeeds.
   foreach($path in @($current.files | Where-Object {[IO.Path]::GetFileName($_) -cnotin @('bridge-result.json','sender-report.json')})){Remove-HousekeepingFile $Root $path;[void]$deleted.Add($path.Substring($Root.Length+1))}
   foreach($log in @($current.journal.logs)){$path=Join-Path $Root $log.name;if(Test-Path -LiteralPath $path){Remove-HousekeepingFile $Root $path;[void]$deleted.Add($log.name)}}
   foreach($path in @($current.files | Where-Object {[IO.Path]::GetFileName($_) -cin @('bridge-result.json','sender-report.json')})){Remove-HousekeepingFile $Root $path;[void]$deleted.Add($path.Substring($Root.Length+1))}
   foreach($path in $current.directories){Assert-HousekeepingStopped $Root;$null=Assert-HousekeepingEntry $Root $path $true;[IO.Directory]::Delete($path,$false)}
   if(Test-Path -LiteralPath $current.summary){Remove-HousekeepingFile $Root $current.summary}
   Assert-HousekeepingStopped $Root;$null=Assert-HousekeepingEntry $Root $current.path $true;[IO.Directory]::Delete($current.path,$false)
   Remove-HousekeepingFile $Root $current.journal_path;[void]$completed.Add($current.name)
  }catch{[void]$errors.Add([ordered]@{name=$session.name;reason=$_.Exception.Message})}
 }
 foreach($file in $Plan.controls){
  try{
   Assert-HousekeepingStopped $Root
   $report=Read-HousekeepingJson $Root $file.FullName
   if(!(Test-HousekeepingControl $report) -or (Get-HousekeepingFileHash $file.FullName) -ine $file.sha256){throw 'Control report changed after planning.'}
   Remove-HousekeepingFile $Root $file.FullName;[void]$deleted.Add($file.Name)
  }catch{[void]$errors.Add([ordered]@{name=$file.Name;reason=$_.Exception.Message})}
 }
 foreach($orphan in @($Plan.orphan_journals)){
  if(!$orphan){continue}
  try{
   Assert-HousekeepingStopped $Root
   if(Test-Path -LiteralPath $orphan.path){throw 'Session path appeared during journal cleanup.'}
   $current=Get-HousekeepingSession $Root ([pscustomobject]@{Name=$orphan.name;FullName=$orphan.path}) -AllowMissing
   foreach($log in @($current.journal.logs)){if(Test-Path -LiteralPath (Join-Path $Root $log.name)){throw 'A completed cleanup still has a host log.'}}
   Remove-HousekeepingFile $Root $current.journal_path;[void]$deleted.Add([IO.Path]::GetFileName($current.journal_path))
  }catch{[void]$errors.Add([ordered]@{name=$orphan.name;reason=$_.Exception.Message})}
 }
 return [ordered]@{schema_version=1;action='Housekeeping';outcome=$(if($errors.Count){'CompletedWithPreservedEntries'}else{'Completed'});utc=[DateTime]::UtcNow.ToString('o');retained_clean_sessions=$Plan.retained_sessions;successful_control_history_limit=20;deleted_count=$deleted.Count;deleted=@($deleted.ToArray() | Select-Object -First 200);removed_session_count=$completed.Count;removed_sessions=@($completed.ToArray() | Select-Object -First 200);preserved_count=@($Plan.preserved).Count;preserved=@($Plan.preserved | Select-Object -First 200);error_count=$errors.Count;errors=@($errors.ToArray() | Select-Object -First 200);report_sample_limit=200;exports_removed=$false;automatic_replay=$false}
}
function Invoke-InstalledHousekeeping([string]$Path){
 # This helper executes only before an engine starts. The same gate and marker
 # as interactive controls prevent startup/control races across processes.
 $root=Assert-BackgroundSafePath $Path
 $receiptPath=Join-Path ([IO.Path]::GetDirectoryName($root)) 'installation-complete.json';$null=Assert-BackgroundSafePath $receiptPath
 $receipt=Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
 if($receipt -isnot [pscustomobject] -or !(Test-HousekeepingCount $receipt.schema_version) -or $receipt.schema_version -ne 1 -or $receipt.state -cne 'Installed' -or $receipt.data -cne $root -or $receipt.app -ine $PSScriptRoot){throw 'Housekeeping installation identity is unavailable.'}
 $gate=[Threading.Mutex]::new($false,'Local\SCX4200.ControlGate');$owned=$false;$guard=$null;$guardPath=Join-Path $root 'CONTROL-ACTIVE.lock'
 try{
  try{$owned=$gate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
  if(!$owned){throw 'Another printer control operation is active.'}
  Assert-HousekeepingStopped $root
  $null=Assert-BackgroundSafePath $guardPath
  $guard=[IO.File]::Open($guardPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  $plan=Get-HousekeepingPlan $root;$report=Invoke-HousekeepingPlan $root $plan
  $latest=Join-Path $root 'housekeeping-latest.json';$null=Assert-BackgroundSafePath $latest
  if(Test-Path -LiteralPath $latest){$null=Assert-HousekeepingEntry $root $latest $false}
  [IO.File]::WriteAllText($latest,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
 }finally{
  if($guard){$guard.Dispose();[IO.File]::Delete($guardPath)}
  if($owned){$gate.ReleaseMutex()};$gate.Dispose()
 }
}
if($MyInvocation.InvocationName -ne '.'){
 try{Invoke-InstalledHousekeeping $DataDir;exit 0}catch{Write-Error $_;exit 1}
}
