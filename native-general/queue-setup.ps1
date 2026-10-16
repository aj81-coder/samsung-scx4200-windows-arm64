# SPDX-License-Identifier: Apache-2.0
# First-use preview setup. Never adopts an existing queue for later removal.
param([ValidateSet('Install','Remove')][string]$Action='Install')
$script:SetupQueueName='Samsung SCX-4200'
$ErrorActionPreference='Stop'
function Get-SetupQueues {
 return @(Get-Printer -ErrorAction Stop | Where-Object {$_.Name -ieq $script:SetupQueueName})
}
function Get-SetupLegacyQueue {return @(Get-Printer -ErrorAction Stop | Where-Object Name -eq 'SCX-4200 Capture Test')}
function Get-SetupJobs { return @(Get-PrintJob -PrinterName $script:SetupQueueName -ErrorAction Stop) }
function Get-SetupListeners {
 return @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {$_.LocalPort -eq 8631})
}
function Assert-SetupStopped([string]$root) {
 if(Test-Path -LiteralPath (Join-Path $root 'SESSION-ACTIVE.lock')){throw 'A session lock remains. Collect results and deliberately recover the stopped session before queue setup/removal.'}
 if(@(Get-Process -Name 'SCX4200-Printer','SCX4200-Reliable-Bridge' -ErrorAction SilentlyContinue).Count){throw 'Stop every bridge window before queue setup/removal.'}
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
    $record.transaction_id -notmatch '^[0-9a-f]{32}$' -or $record.queue.Name -cne $script:SetupQueueName -or
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
 $manifest=Get-Content -LiteralPath (Join-Path $root 'background-package-manifest.json') -Raw -ErrorAction Stop | ConvertFrom-Json
 if($manifest.schema_version -ne 1){throw 'Invalid package manifest.'}
 $seen=@{};$engine=$false
 foreach($file in $manifest.files){
  $relative=[string]$file.path
  if(!$relative -or $relative -match '(^[\\/]|:|(^|[\\/])\.\.?([\\/]|$))' -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $seen.ContainsKey($relative)){throw 'Invalid package file entry.'}
  $seen[$relative]=$true
  $input=Assert-SetupSafePath (Join-Path $root $relative)
  if((Get-SetupBinaryHash $input) -ine $file.sha256){throw ('Package hash mismatch: '+$relative)}
  if($relative -ceq 'SCX4200-Reliable-Bridge.exe'){$engine=$true}
 }
 if(!$engine){throw 'No bridge executable in package manifest.'}
 $stream=[IO.File]::OpenRead($exe);$reader=New-Object IO.BinaryReader($stream)
 try{if($reader.ReadUInt16() -ne 0x5a4d){throw 'Invalid executable.'};$stream.Position=60;$offset=$reader.ReadUInt32();if($offset -gt $stream.Length-6){throw 'Invalid executable.'};$stream.Position=$offset;if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0xaa64){throw 'Native ARM64 package required.'}}finally{$reader.Dispose();$stream.Dispose()}
 return $exe
}
function Assert-SetupSafePath([string]$Path){
 $full=[IO.Path]::GetFullPath($Path)
 if($full -notmatch '^[A-Za-z]:\\' -or $full.Length -le 3 -or $full.Substring(3).Contains(':')){throw 'A local absolute path is required.'}
 $cursor=$full
 while($cursor){if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked folders are not supported.'}};$parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent}
 return $full
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
 $signal=$null
 try{$signal=[Threading.EventWaitHandle]::OpenExisting(('Local\SCX4200.Stop.'+$now.id));$null=$signal.Set()}catch{}finally{if($signal){$signal.Dispose()}}
 if(!$bootstrap.process.WaitForExit(10000)){$bootstrap.process.Kill();if(!$bootstrap.process.WaitForExit(10000)){throw 'Setup bootstrap did not stop.'}}

}
function Start-SetupBootstrap($root,$stem) {
 $exe=Assert-SetupBinary $root
 # All setup captures/locks are isolated from the real installed session.
 $work=Assert-SetupSafePath ($stem+'-bootstrap');$null=New-Item -ItemType Directory -Path $work
 $process=Start-Process -FilePath $exe -ArgumentList '--background --mock-transport=fail' -WorkingDirectory $work -WindowStyle Hidden -PassThru -RedirectStandardOutput ($stem+'-bootstrap.stdout.txt') -RedirectStandardError ($stem+'-bootstrap.stderr.txt')
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
 $root=Assert-SetupSafePath $Root
 $ownership=Join-Path $root 'queue-owned.json'
 $transaction=[guid]::NewGuid().ToString('N')
 $stem=Join-Path $root ('queue-setup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+$transaction)
 $result=[ordered]@{schema_version=1;action=$Action;outcome='Refused';success=$false;queue=$script:SetupQueueName;uri='http://127.0.0.1:8631/ipp/print';transaction_id=$transaction;existing=$null;add_attempted=$false;remove_attempted=$false;bootstrap_mock_transport=$false;error=$null;cleanup_error=$null}
 $bootstrap=$null
 try{
  if($Action -notin 'Install','Remove'){throw 'Unknown setup action.'}
  $saved=Read-SetupOwnership $ownership
  $existing=Get-SetupQueue
  if($existing){$result.existing=Get-SetupQueueView $existing}
  if($Action -eq 'Install'){
   $legacy=@(Get-SetupLegacyQueue)
   if(!$existing -and $legacy.Count){
    $result.existing=Get-SetupQueueView $legacy[0];$result.outcome='ExistingLegacyNotOwned';$result.success=$true
   }elseif($existing){
    if($saved){Assert-SetupQueueIdentity $existing $saved.queue;$result.outcome='AlreadyOwned'}
    else{$result.outcome='ExistingNotOwned'}
    $result.success=$true
   }else{
    if($saved){throw 'Owned queue is absent. Run Remove to archive its old record before installing again.'}
    Assert-SetupStopped $root
    $null=Assert-SetupBinary $root
    # Durable intent precedes both bootstrap and the sole Add-Printer call.
    Write-SetupNewJson ($stem+'-intent.json') @{schema_version=1;action='Install';transaction_id=$transaction;utc=[DateTime]::UtcNow.ToString('o');name=$result.queue;uri=$result.uri;bootstrap_argument='--background --mock-transport=fail'}
    $bootstrap=Start-SetupBootstrap $root $stem;$result.bootstrap_mock_transport=$true
    Assert-SetupBootstrap $bootstrap
    if($null -ne (Get-SetupQueue)){throw 'Queue appeared during setup; no add attempted.'}
    if(Test-Path -LiteralPath $ownership){throw 'Ownership record appeared during setup; no add attempted.'}
    $result.add_attempted=$true
    Add-Printer -Name $result.queue -IppURL $result.uri -Comment ('SCX4200 printer '+$transaction) -ErrorAction Stop
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
  if($Action -eq 'Install' -and !$result.success){$result.error+=' If Windows refused permission to add the printer, right-click ADD-PRINTER.cmd and choose Run as administrator, then run INSTALL.cmd normally. Never run INSTALL.cmd as another administrator account.'}
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
 if($result.outcome -in @('ExistingNotOwned','ExistingLegacyNotOwned')){Write-Host 'Your existing printer was left unchanged. This folder has no permission record to remove it.'}
 if($result.outcome -eq 'Created'){Write-Host 'Printer created. The temporary setup listener has stopped. Run INSTALL.cmd using your normal Windows account.'}
 if($result.error){Write-Host $result.error}
 if($result.cleanup_error){Write-Host ('Bootstrap cleanup: '+$result.cleanup_error)}
 if(!$result.success){exit 1}
}
