# SPDX-License-Identifier: Apache-2.0
# First-use preview setup. Never adopts an existing queue for later removal.
param([ValidateSet('Install','Remove')][string]$Action='Install')
$ErrorActionPreference='Stop'
function Get-SetupQueues {
 return @(Get-Printer -ErrorAction Stop | Where-Object {$_.Name -ieq 'SCX-4200 Capture Test'})
}
function Get-SetupJobs { return @(Get-PrintJob -PrinterName 'SCX-4200 Capture Test' -ErrorAction Stop) }
function Get-SetupListeners {
 return @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {$_.LocalPort -eq 8631})
}
function Assert-SetupStopped([string]$root) {
 if(Test-Path -LiteralPath (Join-Path $root 'SESSION-ACTIVE.lock')){throw 'A session lock remains. Collect results and deliberately recover the stopped session before queue setup/removal.'}
 if(@(Get-Process -Name 'SCX4200-Reliable-Bridge' -ErrorAction SilentlyContinue).Count){throw 'Stop every bridge window before queue setup/removal.'}
 if(@(Get-SetupListeners).Count){throw 'Port 8631 is already occupied; no queue changes made.'}
}
function Get-SetupQueue {
 $queues=@(Get-SetupQueues)
 if($queues.Count -gt 1){throw 'Ambiguous queue name; no changes made.'}
 if($queues.Count){return $queues[0]}
 return $null
}
function Get-SetupQueueView($queue) {
 return [ordered]@{Name=[string]$queue.Name;DriverName=[string]$queue.DriverName;PortName=[string]$queue.PortName;Comment=[string]$queue.Comment}
}
function Assert-SetupQueueIdentity($actual,$saved) {
 foreach($field in @('Name','DriverName','PortName','Comment')){
  if($null -eq $actual -or [string]$actual.$field -cne [string]$saved.$field){throw ('Queue '+$field+' changed; refusing changes.')}
 }
}
function Read-SetupOwnership($path) {
 if(!(Test-Path -LiteralPath $path)){return $null}
 $record=Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
 if($record.schema_version -ne 1 -or $record.state -cne 'Owned' -or $record.uri -cne 'http://127.0.0.1:8631/ipp/print' -or
    $record.transaction_id -notmatch '^[0-9a-f]{32}$' -or $record.queue.Name -cne 'SCX-4200 Capture Test' -or
    $record.queue.DriverName -cne 'Microsoft IPP Class Driver' -or
    $record.queue.PortName -notmatch '^WSD-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'){
  throw 'Invalid local ownership record; no queue changes made.'
 }
 foreach($field in @('Name','DriverName','PortName','Comment')){
  if($record.queue.$field -isnot [string]){throw 'Invalid ownership identity field.'}
 }
 return $record
}
function Write-SetupNewJson($path,$value) {
 $bytes=[Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Depth 8))
 $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Save-SetupOwnership($path,$value) {
 $temporary=$path+'.pending-'+[guid]::NewGuid().ToString('N')
 Write-SetupNewJson $temporary $value
 # Same-directory rename publishes only a fully written record, without replacing one.
 [IO.File]::Move($temporary,$path)
}
function Get-SetupProcessIdentity($process) {
 $now=Get-Process -Id $process.Id -ErrorAction Stop
 return @{id=$now.Id;path=[string]$now.Path;start=$now.StartTime.ToUniversalTime().Ticks}
}
function Get-SetupBinaryHash($path) {return (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash}
function Assert-SetupBinary([string]$root) {
 $exe=[IO.Path]::GetFullPath((Join-Path $root 'SCX4200-Reliable-Bridge.exe'))
 if(!(Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Bridge executable missing from this folder.'}
 if((Get-SetupBinaryHash $exe) -cne 'C28F6598E1A3578AF411225524DDD1DAD25FA247E10AD195C8C701075FE072D0'){
  throw 'Setup requires the pinned tested ARM64 bridge binary; no process launched.'
 }
 return $exe
}
function Assert-SetupBootstrap($bootstrap) {
 $now=Get-SetupProcessIdentity $bootstrap.process
 if($now.id -ne $bootstrap.identity.id -or $now.start -ne $bootstrap.identity.start -or
    ![string]::Equals($now.path,$bootstrap.identity.path,[StringComparison]::OrdinalIgnoreCase)){
  throw 'Setup bootstrap process identity changed.'
 }
 $listeners=@(Get-SetupListeners)
 if($listeners.Count -ne 1 -or $listeners[0].LocalAddress -ne '127.0.0.1' -or $listeners[0].OwningProcess -ne $now.id){
  throw 'Setup listener is not owned exclusively by this loopback bootstrap.'
 }
}
function Stop-SetupBootstrap($bootstrap) {
 if($null -eq $bootstrap){return}
 $bootstrap.process.Refresh()
 if($bootstrap.process.HasExited){return}
 $now=Get-SetupProcessIdentity $bootstrap.process
 if($now.id -ne $bootstrap.identity.id -or $now.start -ne $bootstrap.identity.start -or
    ![string]::Equals($now.path,$bootstrap.identity.path,[StringComparison]::OrdinalIgnoreCase)){
  throw 'Setup bootstrap changed; refusing to stop a different process.'
 }
 # This exact child was launched with --mock-transport=fail; USB is inaccessible.
 $bootstrap.process.Kill()
 if(!$bootstrap.process.WaitForExit(10000)){throw 'Setup bootstrap did not stop.'}
}
function Start-SetupBootstrap($root,$stem) {
 $exe=Assert-SetupBinary $root
 $process=Start-Process -FilePath $exe -ArgumentList '--mock-transport=fail' -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput ($stem+'-bootstrap.stdout.txt') -RedirectStandardError ($stem+'-bootstrap.stderr.txt')
 $bootstrap=$null
 try{
  $identity=Get-SetupProcessIdentity $process
  if(![string]::Equals($identity.path,$exe,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected setup bootstrap path.'}
  $bootstrap=@{process=$process;identity=$identity}
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  do{
   $process.Refresh();if($process.HasExited){throw 'Setup bootstrap exited before becoming ready.'}
   if(@(Get-SetupListeners).Count){Assert-SetupBootstrap $bootstrap;return $bootstrap}
   Start-Sleep -Milliseconds 100
  }while([DateTime]::UtcNow -lt $deadline)
  throw 'Setup bootstrap did not become ready.'
 }catch{
  # The retained Process object refers only to our newly launched child.
  if($bootstrap){Stop-SetupBootstrap $bootstrap}
  else{$process.Refresh();if(!$process.HasExited){$process.Kill();$null=$process.WaitForExit(10000)}}
  throw
 }
}
function Invoke-QueueSetup([string]$Action,[string]$Root=$PSScriptRoot) {
 $root=[IO.Path]::GetFullPath($Root)
 $ownership=Join-Path $root 'queue-owned.json'
 $transaction=[guid]::NewGuid().ToString('N')
 $stem=Join-Path $root ('queue-setup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+$transaction)
 $result=[ordered]@{schema_version=1;action=$Action;outcome='Refused';success=$false;queue='SCX-4200 Capture Test';uri='http://127.0.0.1:8631/ipp/print';transaction_id=$transaction;existing=$null;add_attempted=$false;remove_attempted=$false;bootstrap_mock_transport=$false;error=$null;cleanup_error=$null}
 $bootstrap=$null
 try{
  if($Action -notin 'Install','Remove'){throw 'Unknown setup action.'}
  $saved=Read-SetupOwnership $ownership
  $existing=Get-SetupQueue
  if($existing){$result.existing=Get-SetupQueueView $existing}
  if($Action -eq 'Install'){
   if($existing){
    if($saved){Assert-SetupQueueIdentity $existing $saved.queue;$result.outcome='AlreadyOwned'}
    else{$result.outcome='ExistingNotOwned'}
    $result.success=$true
   }else{
    if($saved){throw 'Owned queue is absent. Run Remove to archive its old record before installing again.'}
    Assert-SetupStopped $root
    $null=Assert-SetupBinary $root
    # Durable intent precedes both bootstrap and the sole Add-Printer call.
    Write-SetupNewJson ($stem+'-intent.json') @{schema_version=1;action='Install';transaction_id=$transaction;utc=[DateTime]::UtcNow.ToString('o');name=$result.queue;uri=$result.uri;bootstrap_argument='--mock-transport=fail'}
    $bootstrap=Start-SetupBootstrap $root $stem;$result.bootstrap_mock_transport=$true
    Assert-SetupBootstrap $bootstrap
    if($null -ne (Get-SetupQueue)){throw 'Queue appeared during setup; no add attempted.'}
    if(Test-Path -LiteralPath $ownership){throw 'Ownership record appeared during setup; no add attempted.'}
    $result.add_attempted=$true
    Add-Printer -Name $result.queue -IppURL $result.uri -Comment ('SCX4200 preview '+$transaction) -ErrorAction Stop
    Assert-SetupBootstrap $bootstrap
    $created=Get-SetupQueue
    if($null -eq $created -or $created.Name -cne $result.queue -or $created.DriverName -cne 'Microsoft IPP Class Driver' -or
       $created.PortName -notmatch '^WSD-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'){
     throw 'Added queue identity could not be verified. No removal or retry attempted.'
    }
    $view=Get-SetupQueueView $created
    Assert-SetupQueueIdentity (Get-SetupQueue) $view
    $record=[ordered]@{schema_version=1;state='Owned';transaction_id=$transaction;created_utc=[DateTime]::UtcNow.ToString('o');uri=$result.uri;queue=$view}
    Save-SetupOwnership $ownership $record
    $saved=Read-SetupOwnership $ownership
    Assert-SetupQueueIdentity (Get-SetupQueue) $saved.queue
    $result.existing=$view;$result.outcome='Created';$result.success=$true
   }
  }else{
   if(!$saved){
    if($existing){throw 'No local ownership record. Existing queue is not owned by this folder and will not be removed.'}
    $result.outcome='AlreadyAbsent';$result.success=$true
   }else{
    Assert-SetupStopped $root
    if($existing){
     Assert-SetupQueueIdentity $existing $saved.queue
     if(@(Get-SetupJobs).Count){throw 'Queue contains jobs; cancel failed documents manually before removal.'}
     Write-SetupNewJson ($stem+'-intent.json') @{schema_version=1;action='Remove';transaction_id=$transaction;utc=[DateTime]::UtcNow.ToString('o');owned_transaction_id=$saved.transaction_id;queue=$saved.queue}
     Assert-SetupStopped $root
     Assert-SetupQueueIdentity (Get-SetupQueue) $saved.queue
     if(@(Get-SetupJobs).Count){throw 'A queue job appeared before removal; no changes made.'}
     $result.remove_attempted=$true
     Remove-Printer -Name $result.queue -ErrorAction Stop
     if($null -ne (Get-SetupQueue)){throw 'Queue remains after removal. Ownership record retained; do not retry automatically.'}
     $result.outcome='Removed'
    }else{$result.outcome='AlreadyAbsent'}
    # Preserve the ownership evidence; never remove ports, drivers, or documents.
    [IO.File]::Move($ownership,($stem+'-owned-archived.json'))
    $result.success=$true
   }
  }
 }catch{
  $result.error=$_.Exception.Message
  if($result.add_attempted -or $result.remove_attempted){$result.outcome='Uncertain'}
 }finally{
  if($bootstrap){try{Stop-SetupBootstrap $bootstrap}catch{$result.cleanup_error=$_.Exception.Message;$result.success=$false;$result.outcome='CleanupRequired'}}
  try{Write-SetupNewJson ($stem+'-result.json') $result}catch{$result.error=($result.error+' Result report could not be written: '+$_.Exception.Message);$result.success=$false}
 }
 return $result
}
if($MyInvocation.InvocationName -ne '.'){
 $result=Invoke-QueueSetup -Action $Action
 Write-Host ('Queue setup: '+$result.outcome)
 if($result.outcome -eq 'ExistingNotOwned'){Write-Host 'Your existing printer was left unchanged. This folder has no permission record to remove it.'}
 if($result.outcome -eq 'Created'){Write-Host 'Queue created. The temporary setup listener has stopped. Use command 1 to start the real bridge.'}
 if($result.error){Write-Host $result.error}
 if($result.cleanup_error){Write-Host ('Bootstrap cleanup: '+$result.cleanup_error)}
 if(!$result.success){exit 1}
}
