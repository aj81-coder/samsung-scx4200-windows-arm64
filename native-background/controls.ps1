# SPDX-License-Identifier: Apache-2.0
param([string]$DataDir,[ValidateSet('Cancel','Recover','Diagnostics')][string]$Action)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'setup.ps1')
. (Join-Path $PSScriptRoot 'control-ipp.ps1')
function Show-BackgroundControlMessage([string]$Text,[switch]$Confirm){
 Add-Type -AssemblyName System.Windows.Forms
 if($Confirm){return [Windows.Forms.MessageBox]::Show($Text,'Samsung SCX-4200',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,[Windows.Forms.MessageBoxDefaultButton]::Button2) -eq [Windows.Forms.DialogResult]::Yes}
 $null=[Windows.Forms.MessageBox]::Show($Text,'Samsung SCX-4200',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)
}
function Get-BackgroundControlData([string]$Path){
 if($Path -notmatch '^[A-Za-z]:\\'){throw 'An absolute local data folder is required.'}
 $full=Assert-BackgroundSafePath $Path
 if(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))).DriveType -ne [IO.DriveType]::Fixed){throw 'The application data folder must be on a fixed local drive.'}
 if(!(Test-Path -LiteralPath $full -PathType Container)){throw 'The installed data folder does not exist.'}
 $base=[IO.Path]::GetDirectoryName($full);$recordPath=Join-Path $base 'installation-complete.json';$null=Assert-BackgroundSafePath $recordPath
 $record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json
 if($record.schema_version -ne 1 -or $record.state -cne 'Installed' -or $record.transaction_id -notmatch '^[a-f0-9]{32}$' -or $record.data -cne $full -or $record.app -ine $PSScriptRoot -or $record.queue.uri -cne 'http://127.0.0.1:8631/ipp/print' -or $record.queue.name -cne 'SCX-4200 Capture Test' -or $record.queue.driver -cne 'Microsoft IPP Class Driver' -or $record.queue.owned -ne $false){throw 'Installed application/data identity could not be verified.'}
 return @{path=$full;receipt=$record}
}
function Assert-BackgroundRecoveryStopped {
 if(@(Get-Process -Name 'SCX4200-Reliable-Bridge' -ErrorAction SilentlyContinue).Count){throw 'The print engine is still running. Use Stop printing, then try recovery again.'}
 if(@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -eq 8631).Count){throw 'Port 8631 is active. Stop the print engine before recovery.'}
}
function Assert-BackgroundRecoveryQueue($Receipt){
 $queues=@(Get-Printer -ErrorAction Stop|Where-Object Name -eq 'SCX-4200 Capture Test')
 if($queues.Count -ne 1 -or $queues[0].Name -cne $Receipt.queue.name -or $queues[0].DriverName -cne $Receipt.queue.driver -or $queues[0].PortName -cne $Receipt.queue.port){throw 'The installed printer queue identity changed. No recovery was performed.'}
 $jobs=@(Get-PrintJob -PrinterName $queues[0].Name -ErrorAction Stop)
 if($jobs.Count){$rows=@($jobs|ForEach-Object {'Job '+$_.ID+': '+[string]$_.JobStatus});throw ("Windows still holds these print jobs:`r`n"+($rows -join "`r`n")+"`r`nOpen the Windows print queue and cancel only the failed document you intend to abandon. Wait until its row disappears, then try recovery again. Keep the printer installed. No queue changes were made.")}
}
function Write-BackgroundControlReport([string]$Root,$Report){
 $path=Join-Path $Root ('control-'+$Report.action.ToLowerInvariant()+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N')+'.json')
 Write-BackgroundJson $path $Report
 return $path
}
function New-BackgroundRecoveryArchive([string]$Root,[string]$Lock){
 Add-Type -AssemblyName System.IO.Compression
 $entries=@(@{path=$Lock;name='SESSION-ACTIVE.lock'})
 foreach($run in @(Get-ChildItem -LiteralPath $Root -Directory -Force|Where-Object Name -match '^bridge-\d')){
  $null=Assert-BackgroundSafePath $run.FullName
  foreach($item in @(Get-ChildItem -LiteralPath $run.FullName -Recurse -Force)){
   $null=Assert-BackgroundSafePath $item.FullName
   if(!$item.PSIsContainer){$entries+=@{path=$item.FullName;name=$item.FullName.Substring($Root.Length+1).Replace('\','/')}}
  }
 }
 foreach($item in @(Get-ChildItem -LiteralPath $Root -File -Force|Where-Object Name -match '^startup-check-.*\.json$')){$null=Assert-BackgroundSafePath $item.FullName;$entries+=@{path=$item.FullName;name=$item.Name}}
 $path=Join-Path $Root ('recovery-backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N')+'.zip')
 $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
  try{foreach($item in $entries){$null=Assert-BackgroundSafePath $item.path;$entry=$zip.CreateEntry($item.name,[IO.Compression.CompressionLevel]::Optimal);$input=[IO.File]::Open($item.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{$output=$entry.Open();try{$input.CopyTo($output)}finally{$output.Dispose()}}finally{$input.Dispose()}}}finally{$zip.Dispose()};$stream.Flush($true)
 }finally{$stream.Dispose()}
 $stream=[IO.File]::OpenRead($path);try{$zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read);try{if($zip.Entries.Count -ne $entries.Count -or !$zip.GetEntry('SESSION-ACTIVE.lock')){throw 'Recovery archive verification failed.'};foreach($entry in $zip.Entries){$input=$entry.Open();try{$input.CopyTo([IO.Stream]::Null)}finally{$input.Dispose()}}}finally{$zip.Dispose()}}finally{$stream.Dispose()}
 return $path
}
function Invoke-BackgroundRecovery($Context){
 $root=$Context.path;$lock=Join-Path $root 'SESSION-ACTIVE.lock';$null=Assert-BackgroundSafePath $lock
 $report=[ordered]@{schema_version=1;action='Recover';outcome='Refused';utc=[DateTime]::UtcNow.ToString('o');automatic_replay=$false;backup_archive=$null;backup_lock=$null;error=$null}
 if(!(Test-Path -LiteralPath $lock)){$report.outcome='NoBlockedSession';return $report}
 if(!(Test-Path -LiteralPath $lock -PathType Leaf) -or ((Get-Item -LiteralPath $lock -Force).Attributes -band [IO.FileAttributes]::ReadOnly)){throw 'The session lock is not a writable regular file. It was preserved.'}
 Assert-BackgroundRecoveryStopped;Assert-BackgroundRecoveryQueue $Context.receipt
 $hash=Get-BackgroundHash $lock
 $report.backup_archive=[IO.Path]::GetFileName((New-BackgroundRecoveryArchive $root $lock))
 $confirm=Show-BackgroundControlMessage -Confirm -Text "Recovery abandons the previous print job. It may have printed partly or fully; keep that output separate.`r`n`r`n1. Disconnect the printer USB cable.`r`n2. Turn the printer off and wait 20 seconds.`r`n3. Turn it on, load A4 paper and wait until ready.`r`n4. Reconnect USB.`r`n`r`nHave you completed these steps and do you intend to abandon the old job? Choose Yes only when ready. No old data will be resent."
 if(!$confirm){$report.outcome='UserDeclined';return $report}
 Assert-BackgroundRecoveryStopped;Assert-BackgroundRecoveryQueue $Context.receipt
 $null=Assert-BackgroundSafePath $lock
 if((Get-Item -LiteralPath $lock -Force).Attributes -band [IO.FileAttributes]::ReadOnly){throw 'The session lock became read-only. It was preserved.'}
 if((Get-BackgroundHash $lock) -cne $hash){throw 'The session lock changed during recovery. It was preserved.'}
 $backup=Join-Path $root ('SESSION-ACTIVE-recovered-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N')+'.lock')
 [IO.File]::Move($lock,$backup);$report.backup_lock=[IO.Path]::GetFileName($backup);$report.outcome='Recovered';return $report
}
function New-BackgroundDiagnostics([string]$Root){
 Add-Type -AssemblyName System.IO.Compression
 $entries=New-Object Collections.ArrayList
 foreach($item in @(Get-ChildItem -LiteralPath $Root -File -Force|Where-Object Name -match '^control-.*\.json$')){[void]$entries.Add($item)}
 foreach($item in @(Get-ChildItem -LiteralPath $Root -File -Force|Where-Object Name -match '^background-.*\.log$'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 2)){[void]$entries.Add($item)}
 $framework=New-Object Collections.ArrayList
 foreach($run in @(Get-ChildItem -LiteralPath $Root -Directory -Force|Where-Object Name -match '^bridge-\d')){
  $null=Assert-BackgroundSafePath $run.FullName
  foreach($name in 'session-result.json','framework.log'){
   $path=Join-Path $run.FullName $name
   if(Test-Path -LiteralPath $path){$null=Assert-BackgroundSafePath $path;$item=Get-Item -LiteralPath $path -Force;if($name -eq 'framework.log'){[void]$framework.Add($item)}else{[void]$entries.Add($item)}}
  }
  foreach($job in @(Get-ChildItem -LiteralPath $run.FullName -Directory -Force|Where-Object Name -match '^job-\d+$')){
   $null=Assert-BackgroundSafePath $job.FullName
   foreach($item in @(Get-ChildItem -LiteralPath $job.FullName -File -Force|Where-Object Extension -eq '.json')){[void]$entries.Add($item)}
  }
 }
 foreach($item in @($framework|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 2)){[void]$entries.Add($item)}
 if($entries.Count -gt 500){throw 'Diagnostics exceed the 500-file limit. Existing files were preserved.'}
 [long]$total=0;$limit=20MB
 foreach($item in $entries){$null=Assert-BackgroundSafePath $item.FullName;if($item.PSIsContainer){throw 'A diagnostic input is not a regular file.'};$total+=$item.Length;if($total -gt $limit){throw 'Diagnostics exceed the 20 MiB limit. Existing files were preserved.'}}
 $path=Join-Path $Root ('diagnostics-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N')+'.zip');$null=Assert-BackgroundSafePath $path
 $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
  try{
   [long]$copied=0;$buffer=New-Object byte[] 8192
   foreach($item in $entries){
    $null=Assert-BackgroundSafePath $item.FullName
    $input=[IO.File]::Open($item.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{$entry=$zip.CreateEntry($item.FullName.Substring($Root.Length+1).Replace('\','/'),[IO.Compression.CompressionLevel]::Optimal);$output=$entry.Open();try{while(($n=$input.Read($buffer,0,$buffer.Length)) -gt 0){$copied+=$n;if($copied -gt $limit){throw 'Diagnostics grew beyond the 20 MiB limit; the partial archive must not be shared.'};$output.Write($buffer,0,$n)}}finally{$output.Dispose()}}finally{$input.Dispose()}
   }
  }finally{$zip.Dispose()};$stream.Flush($true)
 }finally{$stream.Dispose()}
 $stream=[IO.File]::OpenRead($path)
 try{$zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read);try{if($zip.Entries.Count -ne $entries.Count){throw 'Diagnostic archive verification failed.'};foreach($entry in $zip.Entries){$input=$entry.Open();try{$input.CopyTo([IO.Stream]::Null)}finally{$input.Dispose()}}}finally{$zip.Dispose()}}finally{$stream.Dispose()}
 return [ordered]@{schema_version=1;action='Diagnostics';outcome='DiagnosticsCollected';utc=[DateTime]::UtcNow.ToString('o');archive=[IO.Path]::GetFileName($path);files=$entries.Count;page_data_included=$false;automatic_replay=$false}
}
function Invoke-BackgroundControl([string]$Directory,[string]$Operation){
 $context=$null;$guard=$null;$guardPath=$null;$report=$null;$gate=$null;$gateOwned=$false
 try{
  if($Operation -notin @('Cancel','Recover','Diagnostics')){throw 'Choose Cancel, Recover or Diagnostics.'}
  $context=Get-BackgroundControlData $Directory
  $gate=[Threading.Mutex]::new($false,'Local\SCX4200.ControlGate')
  try{$gateOwned=$gate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$gateOwned=$true}
  if(!$gateOwned){throw 'Another printer operation is active. Wait for it to finish, then try again.'}
  $guardPath=Join-Path $context.path 'CONTROL-ACTIVE.lock';$null=Assert-BackgroundSafePath $guardPath
  $guard=[IO.File]::Open($guardPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  if($Operation -eq 'Cancel'){$report=Invoke-CurrentJobCancellation;$report.action='Cancel'}elseif($Operation -eq 'Recover'){$report=Invoke-BackgroundRecovery $context}else{$report=New-BackgroundDiagnostics $context.path}
  $null=Write-BackgroundControlReport $context.path $report
  $message=switch($report.outcome){
   'CancelAccepted' {'Cancellation was accepted. Printer-buffered data may remain; this does not reset the printer. Use Stop printing, cancel the failed Windows queue row if one remains, then choose Recover stopped session before submitting a new document.'}
   'NoBridgeProcess' {'The print engine is stopped. No cancellation was sent.'}
   'NoProcessingJob' {'No document is currently processing. No cancellation was sent.'}
   'Recovered' {'Recovery is complete. Choose Start printing, then submit a new document. No old job was resent.'}
   'UserDeclined' {'Recovery was cancelled. The session lock and original pages remain unchanged.'}
   'NoBlockedSession' {'There is no blocked session. Choose Start printing when ready.'}
   'DiagnosticsCollected' {"Diagnostic ZIP saved to:`r`n"+(Join-Path $context.path $report.archive)+"`r`n`r`nPage images and print data are excluded. Logs can contain document names and local paths. Review the contents before sharing."}
   default {'The operation could not complete. '+[string]$report.error}
  }
  Show-BackgroundControlMessage $message
 }catch{
  $message=$_.Exception.Message
  if($context){try{$null=Write-BackgroundControlReport $context.path @{schema_version=1;action=$Operation;outcome='Refused';utc=[DateTime]::UtcNow.ToString('o');error=$message;automatic_replay=$false}}catch{}}
  Show-BackgroundControlMessage ('No recovery or retry was started. '+$message)
 }finally{if($guard){$guard.Dispose();Remove-Item -LiteralPath $guardPath -ErrorAction SilentlyContinue};if($gate){if($gateOwned){$gate.ReleaseMutex()};$gate.Dispose()}}
}
if($MyInvocation.InvocationName -ne '.') {Invoke-BackgroundControl -Directory $DataDir -Operation $Action}
