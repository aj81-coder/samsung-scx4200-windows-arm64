# SPDX-License-Identifier: Apache-2.0
# All printer/process/network entry points are in-memory mocks. No engine launches.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'queue-setup.ps1')
$source=Join-Path $PSScriptRoot 'queue-setup.ps1'
$output=Join-Path (Split-Path $PSScriptRoot -Parent) ('build/general-queue-setup-tests-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $output | Out-Null
$baseline=[pscustomobject]@{Name='Samsung SCX-4200';DriverName='Microsoft IPP Class Driver';PortName='WSD-11111111-2222-3333-4444-555555555555';Comment='Windows actual rewritten comment'}
$results=New-Object Collections.ArrayList
$originalSave=${function:Save-SetupOwnership}
$originalAssertBinary=${function:Assert-SetupBinary}
$originalAssertBootstrap=${function:Assert-SetupBootstrap}
$originalStopBootstrap=${function:Stop-SetupBootstrap}
function Get-SetupQueues {
 $global:queueReads++
 if($global:enumerationFail){throw 'Mock enumeration denied'}
 if($global:raceQueueAt -eq $global:queueReads){$global:queue=$baseline.PSObject.Copy()}
 if($global:duplicateQueue){return @($baseline.PSObject.Copy(),$baseline.PSObject.Copy())}
 if($null -ne $global:queue){return $global:queue}
 return @()
}
function Get-SetupLegacyQueue {return @($global:legacyQueue)}
function Get-SetupJobs {
 $global:jobReads++
 if($global:jobsFail){throw 'Mock jobs query denied'}
 if($global:raceJobs -and $global:jobReads -ge 2){return @([pscustomobject]@{ID=91})}
 return @($global:jobs)
}
function Get-SetupListeners {return @($global:listeners)}
function Assert-SetupBinary($root){if(!(Test-Path -LiteralPath (Join-Path $root 'SCX4200-Reliable-Bridge.exe'))){throw 'Mock missing binary'};if($global:binaryHash -cne 'C28F6598E1A3578AF411225524DDD1DAD25FA247E10AD195C8C701075FE072D0'){throw 'Mock package binary hash mismatch'};return (Join-Path $root 'SCX4200-Reliable-Bridge.exe')}
function Get-SetupBinaryHash($path){return $global:binaryHash}
function Get-Process {param($Name,$ErrorAction) if($global:bridgeActive){return [pscustomobject]@{Id=71}};return @()}
function Start-SetupBootstrap($root,$stem) {
 $global:bootstrapStarts++
 if(!(Test-Path -LiteralPath ($stem+'-intent.json'))){throw 'Intent missing before bootstrap'}
 return @{process=@{Id=42};identity=@{id=42;path='mock';start=123}}
}
function Assert-SetupBootstrap($bootstrap){if($global:bootstrapChanged){throw 'Mock bootstrap identity changed'}}
function Stop-SetupBootstrap($bootstrap){$global:bootstrapStops++;if($global:cleanupFail){throw 'Mock child cleanup denied'}}
function Add-Printer {
 param($Name,$IppURL,$Comment,$ErrorAction)
 if($Name -cne $baseline.Name -or $IppURL -cne 'http://127.0.0.1:8631/ipp/print'){throw 'Unexpected Add target'}
 $global:addCalls++
 if($global:addFail){throw 'Mock Add failed after possible mutation'}
 $global:queue=$baseline.PSObject.Copy()
 if($global:badCreatedDriver){$global:queue.DriverName='Other driver'}
}
function Remove-Printer {
 param($Name,$ErrorAction)
 if($Name -cne $baseline.Name){throw 'Unexpected Remove target'}
 $global:removeCalls++
 if($global:removeFail){throw 'Mock Remove failed'}
 if(!$global:removeSticks){$global:queue=$null}
}
function Check($condition,$message){if(!$condition){throw $message}}
function Reset-QueueCase($name,[bool]$owned=$false,[bool]$present=$false) {
 $global:caseRoot=Join-Path $output $name;New-Item -ItemType Directory -Path $global:caseRoot | Out-Null
 [IO.File]::WriteAllText((Join-Path $global:caseRoot 'SCX4200-Reliable-Bridge.exe'),'Not executable: test placeholder only')
 $global:binaryHash='C28F6598E1A3578AF411225524DDD1DAD25FA247E10AD195C8C701075FE072D0'
 $global:queue=$null;if($present){$global:queue=$baseline.PSObject.Copy()}
 $global:legacyQueue=@();$global:listeners=@();$global:jobs=@();$global:bridgeActive=$false
 $global:addCalls=0;$global:removeCalls=0;$global:bootstrapStarts=0;$global:bootstrapStops=0
 $global:enumerationFail=$false;$global:duplicateQueue=$false;$global:addFail=$false;$global:removeFail=$false
 $global:removeSticks=$false;$global:badCreatedDriver=$false;$global:bootstrapChanged=$false;$global:cleanupFail=$false
 $global:raceQueueAt=-1;$global:queueReads=0;$global:jobReads=0;$global:raceJobs=$false;$global:jobsFail=$false
 if($owned){
  Write-SetupNewJson (Join-Path $global:caseRoot 'queue-owned.json') @{schema_version=1;state='Owned';transaction_id=('a'*32);uri='http://127.0.0.1:8631/ipp/print';queue=(Get-SetupQueueView $baseline)}
 }
}
function Record-Pass($name){[void]$results.Add(@{name=$name;result='PASS'})}
Reset-QueueCase 'fresh-install'
$r=Invoke-QueueSetup Install $caseRoot
Check ($r.success -and $r.outcome -eq 'Created' -and $addCalls -eq 1 -and $removeCalls -eq 0 -and $bootstrapStarts -eq 1 -and $bootstrapStops -eq 1) 'Fresh install failed'
$saved=Read-SetupOwnership (Join-Path $caseRoot 'queue-owned.json')
Check ($saved.queue.Comment -ceq $baseline.Comment) 'Did not persist actual Windows comment'
$before=(Get-FileHash (Join-Path $caseRoot 'queue-owned.json')).Hash
$r=Invoke-QueueSetup Install $caseRoot
Check ($r.outcome -eq 'AlreadyOwned' -and $addCalls -eq 1 -and $bootstrapStarts -eq 1) 'Owned install is not idempotent'
Check ((Get-FileHash (Join-Path $caseRoot 'queue-owned.json')).Hash -eq $before) 'Owned reuse changed record'
Record-Pass 'fresh-create-actual-comment-and-owned-idempotence'
Reset-QueueCase 'existing-legacy-printer'
$global:legacyQueue=@([pscustomobject]@{Name='SCX-4200 Capture Test';DriverName='Microsoft IPP Class Driver';PortName='old-port';Comment='existing'})
$r=Invoke-QueueSetup Install $caseRoot
Check ($r.success -and $r.outcome -eq 'ExistingLegacyNotOwned' -and !$addCalls -and !$bootstrapStarts) 'Legacy queue caused duplicate friendly creation'
Record-Pass 'legacy-queue-preserved-without-duplicate-creation'
Reset-QueueCase 'existing-unowned' $false $true
$r=Invoke-QueueSetup Install $caseRoot
Check ($r.success -and $r.outcome -eq 'ExistingNotOwned' -and !$addCalls -and !$removeCalls -and !$bootstrapStarts) 'Existing queue was mutated/adopted'
Check (!(Test-Path (Join-Path $caseRoot 'queue-owned.json'))) 'Unowned queue adopted'
$r=Invoke-QueueSetup Remove $caseRoot
Check (!$r.success -and !$removeCalls -and $null -ne $queue) 'Unowned queue was removed'
Record-Pass 'existing-unowned-preserved-and-remove-refused'
Reset-QueueCase 'existing-other-driver' $false $true
$queue.DriverName='Other driver'
$r=Invoke-QueueSetup Install $caseRoot
Check ($r.outcome -eq 'ExistingNotOwned' -and !$addCalls -and !$bootstrapStarts -and $queue.DriverName -ceq 'Other driver') 'Same-name unrelated queue changed'
Record-Pass 'same-name-unrelated-queue-preserved'
foreach($field in @('Name','DriverName','PortName','Comment')){
 Reset-QueueCase ('changed-'+$field) $true $true
 # Name enumeration remains canonical while the supplied identity differs.
 if($field -eq 'Name'){$record=Get-Content (Join-Path $caseRoot 'queue-owned.json') -Raw | ConvertFrom-Json;$record.queue.Name='Other';Set-Content (Join-Path $caseRoot 'queue-owned.json') ($record|ConvertTo-Json -Depth 6)}
 else{$queue.$field='Changed'}
 $r=Invoke-QueueSetup Remove $caseRoot
 Check (!$r.success -and !$removeCalls -and (Test-Path (Join-Path $caseRoot 'queue-owned.json'))) ('Changed '+$field+' not protected')
}
Record-Pass 'all-identity-fields-protected'
Reset-QueueCase 'remove-success' $true $true
$recordBytes=[IO.File]::ReadAllBytes((Join-Path $caseRoot 'queue-owned.json'))
New-Item -ItemType Directory -Path (Join-Path $caseRoot 'bridge-old') | Out-Null
[IO.File]::WriteAllText((Join-Path $caseRoot 'bridge-old/evidence.txt'),'Preserve evidence')
$r=Invoke-QueueSetup Remove $caseRoot
Check ($r.success -and $r.outcome -eq 'Removed' -and $removeCalls -eq 1 -and !$bootstrapStarts) 'Owned removal failed'
Check (!(Test-Path (Join-Path $caseRoot 'queue-owned.json'))) 'Active ownership not archived'
$archive=Get-ChildItem $caseRoot -Filter '*-owned-archived.json'
Check ($archive.Count -eq 1 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($archive.FullName)) -eq [Convert]::ToBase64String($recordBytes)) 'Archived record differs'
Check ([IO.File]::ReadAllText((Join-Path $caseRoot 'bridge-old/evidence.txt')) -ceq 'Preserve evidence') 'Evidence changed'
$r=Invoke-QueueSetup Remove $caseRoot
Check ($r.success -and $r.outcome -eq 'AlreadyAbsent' -and $removeCalls -eq 1) 'Absent remove not idempotent'
Record-Pass 'owned-removal-archives-record-preserves-evidence-idempotent'
Reset-QueueCase 'owned-absent' $true $false
$r=Invoke-QueueSetup Install $caseRoot
Check (!$r.success -and !$addCalls -and !$bootstrapStarts) 'Stale ownership allowed replacement'
$r=Invoke-QueueSetup Remove $caseRoot
Check ($r.success -and $r.outcome -eq 'AlreadyAbsent' -and !$removeCalls -and !(Test-Path (Join-Path $caseRoot 'queue-owned.json'))) 'Absent owned archive failed'
Record-Pass 'stale-owned-queue-requires-explicit-archive'
foreach($kind in @('active','port','jobs','jobs-query','enumeration','duplicate','lock')){
 Reset-QueueCase ('remove-refuse-'+$kind) $true $true
 switch($kind){
  active{$global:bridgeActive=$true};port{$global:listeners=@(@{LocalAddress='127.0.0.1';OwningProcess=97})}
  jobs{$global:jobs=@(@{ID=9})};'jobs-query'{$global:jobsFail=$true};enumeration{$global:enumerationFail=$true};duplicate{$global:duplicateQueue=$true};lock{[IO.File]::WriteAllText((Join-Path $caseRoot 'SESSION-ACTIVE.lock'),'Keep blocked session')}
 }
 $r=Invoke-QueueSetup Remove $caseRoot
 Check (!$r.success -and !$removeCalls -and (Test-Path (Join-Path $caseRoot 'queue-owned.json'))) ('Removal not refused for '+$kind)
}
Record-Pass 'remove-resource-query-and-ambiguity-guards'
foreach($kind in @('active','port','enumeration','duplicate','bootstrap','queue-race','add-error','bad-driver','cleanup','lock','wrong-binary','missing-binary')){
 Reset-QueueCase ('install-refuse-'+$kind)
 switch($kind){
  active{$global:bridgeActive=$true};port{$global:listeners=@(@{LocalAddress='127.0.0.1';OwningProcess=97})}
  enumeration{$global:enumerationFail=$true};duplicate{$global:duplicateQueue=$true};bootstrap{$global:bootstrapChanged=$true}
  'queue-race'{$global:raceQueueAt=2};'add-error'{$global:addFail=$true};'bad-driver'{$global:badCreatedDriver=$true};cleanup{$global:cleanupFail=$true}
  lock{[IO.File]::WriteAllText((Join-Path $caseRoot 'SESSION-ACTIVE.lock'),'Keep blocked session')}
  'wrong-binary'{$global:binaryHash='BAD'};'missing-binary'{Remove-Item -LiteralPath (Join-Path $caseRoot 'SCX4200-Reliable-Bridge.exe')}
 }
 $r=Invoke-QueueSetup Install $caseRoot
 if($kind -eq 'cleanup'){Check (!$r.success -and $r.outcome -eq 'CleanupRequired' -and (Test-Path (Join-Path $caseRoot 'queue-owned.json'))) 'Cleanup failure not surfaced'}
 else{Check (!$r.success -and !$removeCalls -and !(Test-Path (Join-Path $caseRoot 'queue-owned.json'))) ('Installation guard failed: '+$kind)}
 if($kind -notin 'add-error','bad-driver','cleanup'){Check (!$addCalls) ('Unexpected Add: '+$kind)}
 if($kind -in 'lock','wrong-binary','missing-binary'){Check (!$bootstrapStarts) ('Unexpected bootstrap: '+$kind)}
 if($bootstrapStarts){Check ($bootstrapStops -eq 1) ('Child cleanup not attempted: '+$kind)}
}
Record-Pass 'install-guards-races-and-uncertainty-no-rollback'
Reset-QueueCase 'job-race' $true $true;$global:raceJobs=$true
$r=Invoke-QueueSetup Remove $caseRoot
Check (!$r.success -and !$removeCalls) 'Job appeared between removal checks but was ignored'
Record-Pass 'removal-rechecks-empty-queue'
foreach($kind in @('throws','persists')){
 Reset-QueueCase ('remove-uncertain-'+$kind) $true $true
 if($kind -eq 'throws'){$global:removeFail=$true}else{$global:removeSticks=$true}
 $r=Invoke-QueueSetup Remove $caseRoot
 Check (!$r.success -and $r.outcome -eq 'Uncertain' -and $removeCalls -eq 1 -and (Test-Path (Join-Path $caseRoot 'queue-owned.json'))) ('Uncertain removal lost record: '+$kind)
}
Record-Pass 'uncertain-removal-record-retained'
Reset-QueueCase 'save-failure'
function Save-SetupOwnership($path,$value){throw 'Mock disk denied'}
$r=Invoke-QueueSetup Install $caseRoot
Check (!$r.success -and $r.outcome -eq 'Uncertain' -and $addCalls -eq 1 -and !$removeCalls -and $bootstrapStops -eq 1) 'Save uncertainty triggered rollback or retry'
Set-Item Function:Save-SetupOwnership $originalSave
Record-Pass 'ownership-write-failure-no-destructive-rollback'
foreach($bad in @('{}','{"schema_version":1,"state":"Owned","transaction_id":"bad"}')){
 Reset-QueueCase ('invalid-record-'+$results.Count+'-'+[guid]::NewGuid().ToString('N')) $false $true
 [IO.File]::WriteAllText((Join-Path $caseRoot 'queue-owned.json'),$bad)
 $r=Invoke-QueueSetup Remove $caseRoot
 Check (!$r.success -and !$removeCalls) 'Malformed ownership allowed removal'
}
Record-Pass 'malformed-ownership-fail-closed'
# Exercise real identity guard with mock identities/listeners, never process APIs.
function Get-SetupProcessIdentity($process){return $global:processIdentity}
$global:processIdentity=@{id=42;path='mock';start=123}
$b=@{process=@{Id=42};identity=@{id=42;path='mock';start=123}}
$global:listeners=@(@{LocalAddress='127.0.0.1';OwningProcess=42})
& $originalAssertBootstrap $b
foreach($kind in @('pid','start','path','wildcard','owner','duplicate','absent')){
 $global:processIdentity=@{id=42;path='mock';start=123};$global:listeners=@(@{LocalAddress='127.0.0.1';OwningProcess=42})
 switch($kind){pid{$processIdentity.id=43};start{$processIdentity.start=124};path{$processIdentity.path='other'};wildcard{$listeners[0].LocalAddress='0.0.0.0'};owner{$listeners[0].OwningProcess=43};duplicate{$global:listeners+=@{LocalAddress='::1';OwningProcess=42}};absent{$global:listeners=@()}}
 $refused=$false;try{& $originalAssertBootstrap $b}catch{$refused=$true}
 Check $refused ('Bootstrap identity guard failed: '+$kind)
}
Record-Pass 'bootstrap-path-pid-start-exclusive-loopback-identity'
# The actual cleanup implementation may stop only the same child identity.
$global:killCalls=0
$child=New-Object PSObject -Property @{Id=42;HasExited=$false}
$child | Add-Member ScriptMethod Refresh {}
$child | Add-Member ScriptMethod Kill {$global:killCalls++}
$child | Add-Member ScriptMethod WaitForExit {param($timeout) return ($global:killCalls -gt 0)}
$b=@{process=$child;identity=@{id=42;path='mock';start=123}}
$global:processIdentity=@{id=42;path='mock';start=124}
$refused=$false;try{& $originalStopBootstrap $b}catch{$refused=$true}
Check ($refused -and !$killCalls) 'Cleanup stopped a reused/different process identity'
$global:processIdentity=@{id=42;path='mock';start=123}
& $originalStopBootstrap $b
Check ($killCalls -eq 1) 'Owned child was not stopped exactly once'
$child.HasExited=$true
& $originalStopBootstrap $b
Check ($killCalls -eq 1) 'Exited bootstrap was stopped again'
Record-Pass 'bootstrap-cleanup-owned-child-only'
$scriptText=Get-Content -LiteralPath $source -Raw
Check ($scriptText.Contains("-ArgumentList '--background --mock-transport=fail'") -and $scriptText.Contains('-WindowStyle Hidden')) 'Bootstrap is not explicitly hidden failing mock transport'
Check ($scriptText -notmatch 'Remove-PrinterPort|Remove-PrinterDriver|Set-Printer|Restart-Service|Stop-Service|Set-Service|Set-ExecutionPolicy') 'Unexpected system mutation in installer'
Record-Pass 'bootstrap-no-usb-and-no-extra-system-mutations'
# Independently exercise the real complete-package hash/ARM guard with inert bytes.
function Get-SetupBinaryHash($path){return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
$guard=Join-Path $output 'real-package-guard';$null=New-Item -ItemType Directory -Path $guard
$guardExe=Join-Path $guard 'SCX4200-Reliable-Bridge.exe'
$bytes=New-Object byte[] 128;$bytes[0]=0x4d;$bytes[1]=0x5a;$bytes[60]=64;$bytes[64]=0x50;$bytes[65]=0x45;$bytes[68]=0x64;$bytes[69]=0xaa
[IO.File]::WriteAllBytes($guardExe,$bytes)
$guardPayload=Join-Path $guard 'notice.txt';[IO.File]::WriteAllText($guardPayload,'inert test payload')
$manifestPath=Join-Path $guard 'background-package-manifest.json'
function Set-GuardManifest {
 @{schema_version=1;files=@(@{path='SCX4200-Reliable-Bridge.exe';sha256=(Get-SetupBinaryHash $guardExe)},@{path='notice.txt';sha256=(Get-SetupBinaryHash $guardPayload)})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}
Set-GuardManifest
Check ((& $originalAssertBinary $guard) -ceq $guardExe) 'Valid synthetic ARM package refused'
[IO.File]::AppendAllText($guardPayload,'corrupt')
$refused=$false;try{& $originalAssertBinary $guard}catch{$refused=$_.Exception.Message -like '*hash mismatch*'}
Check $refused 'Non-engine manifest payload corruption ignored'
Set-GuardManifest;$bytes[68]=0x64;$bytes[69]=0x86;[IO.File]::WriteAllBytes($guardExe,$bytes);Set-GuardManifest
$refused=$false;try{& $originalAssertBinary $guard}catch{$refused=$_.Exception.Message -like '*ARM64*'}
Check $refused 'X64 executable accepted as ARM64'
@{schema_version=1;files=@(@{path='../outside.exe';sha256=('a'*64)})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8
$refused=$false;try{& $originalAssertBinary $guard}catch{$refused=$_.Exception.Message -like '*Invalid package file entry*'}
Check $refused 'Manifest parent path accepted'
Record-Pass 'actual-package-hash-non-engine-payload-arm64-and-path-guards'
$report=@{result='PASS';tests=@($results.ToArray());queue_setup_sha256=(Get-FileHash -LiteralPath $source).Hash;real_printer_access=$false;real_process_launches=$false}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'results.json') -Encoding UTF8
Write-Host ('PASS: '+$results.Count+' queue setup groups; '+$output)
