# SPDX-License-Identifier: Apache-2.0
# Isolated filesystem tests. No printer, process, network or COM APIs are called.
param([string]$OutputRoot=(Join-Path $PSScriptRoot ('../build/background-setup-test-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'uninstall.ps1')
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $OutputRoot){throw 'Test output already exists.'}
$null=New-Item -ItemType Directory -Path $OutputRoot
$script:results=@();$script:queueReads=0;$script:shortcutObjects=@{}
function Assert-Test($Condition,[string]$Message){if(!$Condition){throw $Message}}
function Assert-Refused([scriptblock]$Action,[string]$Pattern){try{& $Action;throw 'Expected refusal was absent.'}catch{if($_.Exception.Message -notmatch $Pattern){throw}}}
function Assert-BackgroundPlatform {}
function Assert-BackgroundStopped([string]$Data) {if(Test-Path -LiteralPath (Join-Path $Data 'SESSION-ACTIVE.lock')){throw 'Mock active lock.'}}
function Get-BackgroundShortcutPath([string]$Kind){Join-Path $script:caseRoot ($Kind+'.lnk')}
function Get-Printer { $script:queueReads++;if($script:queueMissing){return};[pscustomobject]@{Name=$script:queueName;DriverName=$script:queueDriver;PortName=$script:queuePort} }
function New-BackgroundQueue([string]$Source){$script:createQueueCalls++;if($script:createQueueFail){return @{success=$false;error='Mock queue creation permission denied'}};$script:queueMissing=$false;$script:queueName='Samsung SCX-4200';return @{success=$true}}
function Get-PrinterProperty {if(!$script:urls.Count){[pscustomobject]@{PropertyName='FormTrayTable';Value=@()}};foreach($url in $script:urls){[pscustomobject]@{PropertyName='DeviceURL';Value=$url}}}
function Get-ItemProperty {throw 'No registry reads are permitted in this harness.'}
# Mask registry existence only; ordinary filesystem Test-Path remains real.
function Test-Path {param([string]$LiteralPath,[string]$PathType) if($LiteralPath -like 'Registry::*'){return $false};if($PathType){Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType}else{Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath}}
function Get-PrintJob { $script:queueJobs }
function Add-Printer {throw 'Test attempted a printer mutation.'}
function Remove-Printer {throw 'Test attempted a printer mutation.'}
function Set-Printer {throw 'Test attempted a printer mutation.'}
function Get-Process {throw 'Process inspection must be isolated in this harness.'}
function Get-NetTCPConnection {throw 'Network inspection must be isolated in this harness.'}
function Start-Process {throw 'Test attempted to launch a process.'}
function Get-BackgroundShortcut([string]$Path){
 if($script:shortcutObjects.ContainsKey($Path)){return $script:shortcutObjects[$Path]}
 $object=[pscustomobject]@{Path=$Path;TargetPath='';Arguments='';WorkingDirectory='';Description=''}
 $object|Add-Member ScriptMethod Save {
  if($script:failMenu -and $this.Path -like '*Programs.lnk'){throw 'Injected shortcut failure.'}
  [IO.File]::WriteAllText($this.Path,($this.TargetPath+'|'+$this.Arguments+'|'+$this.WorkingDirectory))
 }
 $script:shortcutObjects[$Path]=$object;return $object
}
function New-Case([string]$Name){
 $script:caseRoot=Join-Path $OutputRoot $Name;$script:source=Join-Path $script:caseRoot 'source';$script:local=Join-Path $script:caseRoot 'local'
 $script:base=Join-Path $script:local 'SCX4200';$script:app=Join-Path $script:base 'app';$script:data=Join-Path $script:base 'data'
 $null=New-Item -ItemType Directory -Path $script:source -Force
 $script:urls=@('http://127.0.0.1:8631/ipp/print');$script:failMenu=$false;$script:shortcutObjects=@{}
 $script:queueMissing=$false;$script:queueName='SCX-4200 Capture Test';$script:createQueueCalls=0;$script:createQueueFail=$false;$script:queueDriver='Microsoft IPP Class Driver';$script:queuePort='preserved-port'
 $script:queueJobs=@()
 $files=@();$binaries=@('SCX4200-Printer.exe','SCX4200-Reliable-Bridge.exe','SCX4200-Render.exe','SCX4200-Bridge-Sender.exe','cups.dll')
 foreach($name in @($binaries)+@('setup.ps1','uninstall.ps1','INSTALL.cmd','UNINSTALL.cmd','housekeeping.ps1','controls.ps1','control-ipp.ps1','queue-setup.ps1','LICENSES/notice.txt')){
  $path=Join-Path $script:source $name;$null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force
  if($name -in $binaries){$bytes=New-Object byte[] 128;$bytes[0]=0x4d;$bytes[1]=0x5a;$bytes[60]=64;$bytes[64]=0x50;$bytes[65]=0x45;$bytes[68]=0x64;$bytes[69]=0xaa;[IO.File]::WriteAllBytes($path,$bytes)}else{[IO.File]::WriteAllText($path,'test payload '+$name)}
  $files+=@{path=$name;sha256=Get-BackgroundHash $path}
 }
 Write-BackgroundJson (Join-Path $script:source 'background-package-manifest.json') @{schema_version=1;files=$files}
}
function Install-Test {Invoke-BackgroundInstall -Source $script:source -LocalRoot $script:local -SkipLaunch}
function Remove-Test {Invoke-BackgroundUninstall -LocalRoot $script:local}
function Pass([string]$Name){$script:results+=@{name=$Name;status='PASS'}}

New-Case 'install-remove'
Install-Test
$prepared=Get-Content -LiteralPath (Join-Path $base 'installation.json') -Raw|ConvertFrom-Json
$commit=Get-Content -LiteralPath (Join-Path $base 'installation-complete.json') -Raw|ConvertFrom-Json
Assert-Test ($prepared.state -eq 'Prepared' -and $commit.state -eq 'Installed' -and $prepared.transaction_id -eq $commit.transaction_id) 'Ownership commit failed.'
Assert-Test ($commit.queue.endpoint_verified -and $commit.queue.uri_role -eq 'ExpectedLocalBridgeEndpoint') 'Reported endpoint proof was lost.'
foreach($file in $commit.files){Assert-Test ((Get-BackgroundHash (Join-Path $app $file.path)) -eq $file.sha256) 'Copied manifest mismatch.'}
Assert-Test (@($commit.files).Count -eq 14) 'Missing copied payload.'
Assert-Refused {Install-Test} 'already exists'
[IO.File]::WriteAllText((Join-Path $data 'keep.json'),'retained diagnostics')
[IO.File]::WriteAllText((Join-Path $app 'unknown.txt'),'user file')
$reads=$script:queueReads;Remove-Test
Assert-Test ($script:queueReads -eq $reads) 'Uninstall queried queues.'
Assert-Test ((Test-Path -LiteralPath (Join-Path $data 'keep.json')) -and (Test-Path -LiteralPath (Join-Path $app 'unknown.txt'))) 'Uninstall lost unowned content.'
Assert-Test (!(Test-Path -LiteralPath (Get-BackgroundShortcutPath 'Startup')) -and !(Test-Path -LiteralPath (Join-Path $app 'SCX4200-Printer.exe'))) 'Owned content remains.'
Pass 'manifest-copy-ownership-repeat-refusal-data-and-unknown-file-preservation'

New-Case 'changed-file';Install-Test
[IO.File]::AppendAllText((Join-Path $app 'setup.ps1'),'changed')
Assert-Refused {Remove-Test} 'installed file changed'
Assert-Test (Test-Path -LiteralPath (Get-BackgroundShortcutPath 'Startup')) 'Removal started before file preflight.'
Pass 'changed-file-refuses-before-removal'

New-Case 'changed-shortcut';Install-Test
[IO.File]::AppendAllText((Get-BackgroundShortcutPath 'Startup'),'changed')
Assert-Refused {Remove-Test} 'shortcut has changed'
Assert-Test (Test-Path -LiteralPath (Join-Path $app 'setup.ps1')) 'Payload removed despite changed shortcut.'
Pass 'changed-shortcut-refuses-before-removal'

New-Case 'changed-shortcut-target';Install-Test
(Get-BackgroundShortcut (Get-BackgroundShortcutPath 'Startup')).TargetPath='C:\unowned.exe'
Assert-Refused {Remove-Test} 'Shortcut target changed'
Assert-Test (Test-Path -LiteralPath (Join-Path $app 'setup.ps1')) 'Payload removed despite changed target.'
Pass 'shortcut-target-cross-check'

New-Case 'partial-shortcuts';$script:failMenu=$true
Assert-Refused {Install-Test} 'Injected shortcut failure'
Assert-Test ((Test-Path -LiteralPath (Join-Path $base 'installation.json')) -and !(Test-Path -LiteralPath (Join-Path $base 'installation-complete.json'))) 'Partial install lost prepared ownership.'
Assert-Refused {Remove-Test} 'lacks an ownership receipt'
Assert-Test (Test-Path -LiteralPath (Join-Path $app 'SCX4200-Printer.exe')) 'Partial install removed unreceipted state.'
Pass 'partial-registration-retained-and-conservatively-refused'

New-Case 'prepared-before-shortcuts';Install-Test
Remove-Item -LiteralPath (Join-Path $base 'installation-complete.json')
foreach($kind in @('Startup','Programs')){Remove-Item -LiteralPath (Get-BackgroundShortcutPath $kind)}
Remove-Test
Assert-Test (!(Test-Path -LiteralPath $app)) 'Prepared payload was not removable.'
Pass 'prepared-with-no-registration-removable'

New-Case 'prepared-stage';Install-Test
$prepared=Get-Content -LiteralPath (Join-Path $base 'installation.json') -Raw|ConvertFrom-Json
Remove-Item -LiteralPath (Join-Path $base 'installation-complete.json')
foreach($kind in @('Startup','Programs')){Remove-Item -LiteralPath (Get-BackgroundShortcutPath $kind)}
[IO.Directory]::Move($app,$prepared.stage)
Remove-Test
Assert-Test (!(Test-Path -LiteralPath $prepared.stage)) 'Prepared staged payload was not removable.'
Pass 'prepared-stage-removal'

New-Case 'record-conflict';Install-Test
$commit=Get-Content -LiteralPath (Join-Path $base 'installation-complete.json') -Raw|ConvertFrom-Json
$commit.transaction_id='00000000000000000000000000000000'
[IO.File]::WriteAllText((Join-Path $base 'installation-complete.json'),($commit|ConvertTo-Json -Depth 12))
Assert-Refused {Remove-Test} 'records disagree'
Assert-Test (Test-Path -LiteralPath (Get-BackgroundShortcutPath 'Startup')) 'Conflicting record caused mutation.'
Pass 'ownership-record-conflict-refusal'

New-Case 'bad-hash'
[IO.File]::AppendAllText((Join-Path $source 'setup.ps1'),'corrupt')
Assert-Refused {Install-Test} 'integrity check failed'
Assert-Test (!(Test-Path -LiteralPath $base)) 'Integrity refusal created install state.'
Pass 'bad-hash-before-mutation'

New-Case 'unknown-endpoint';$script:urls=@()
Install-Test
$commit=Get-Content -LiteralPath (Join-Path $base 'installation-complete.json') -Raw|ConvertFrom-Json
Assert-Test (!$commit.queue.endpoint_verified -and $commit.queue.verification_method -eq 'ExistingQueueNameDriverPort_EndpointNotExposed' -and !$commit.queue.owned) 'Unavailable endpoint was falsely verified or queue adopted.'
Assert-Test ($commit.queue.port -eq 'preserved-port' -and $commit.queue.driver -eq 'Microsoft IPP Class Driver') 'Existing identity changed.'
Assert-Test ($script:BackgroundQueueDiagnostic.property_names.Count -eq 1 -and $script:BackgroundQueueDiagnostic.property_names[0] -eq 'FormTrayTable' -and !$script:BackgroundQueueDiagnostic.endpoint_verified) 'Target FormTrayTable-only diagnostic was not reproduced.'
Remove-Test
Pass 'target-formtraytable-only-install-and-removal-preserve-queue'

New-Case 'unknown-endpoint-pending-job';$script:urls=@();$script:queueJobs=@([pscustomobject]@{ID=42;JobStatus='Error'})
Assert-Refused {Install-Test} 'Finish or cancel existing print jobs'
Assert-Test (!(Test-Path -LiteralPath $base)) 'Unavailable endpoint bypassed pending-job protection.'
Pass 'unavailable-endpoint-still-requires-empty-queue'

New-Case 'blank-endpoint';$script:urls=@('')
Install-Test
$commit=Get-Content -LiteralPath (Join-Path $base 'installation-complete.json') -Raw|ConvertFrom-Json
Assert-Test (!$commit.queue.endpoint_verified) 'Blank endpoint was falsely verified.'
Pass 'blank-url-is-unavailable-not-conflicting'

foreach($kind in @('wrong-driver','missing-port')){
 New-Case ('queue-'+$kind)
 if($kind -eq 'missing'){$script:queueMissing=$true}elseif($kind -eq 'wrong-driver'){$script:queueDriver='Unrelated driver'}else{$script:queuePort=''}
 Assert-Refused {Install-Test} 'requires Microsoft IPP'
 Assert-Test (!(Test-Path -LiteralPath $base)) 'Invalid queue created installation state.'
 Pass ('queue-'+$kind+'-refusal')
}

New-Case 'new-friendly-printer';$script:queueMissing=$true
Install-Test
$commit=Get-Content -LiteralPath (Join-Path $base 'installation-complete.json') -Raw|ConvertFrom-Json
Assert-Test ($script:createQueueCalls -eq 1 -and $commit.queue.name -ceq 'Samsung SCX-4200') 'New queue name was not recorded.'
Remove-Test
Pass 'new-friendly-queue-recorded-and-uninstall-preserves-printer'
New-Case 'new-printer-permission-denied';$script:queueMissing=$true;$script:createQueueFail=$true
Assert-Refused {Install-Test} 'Printer setup did not complete'
Assert-Test (!(Test-Path -LiteralPath $base)) 'Failed queue creation created installation state.'
Pass 'fresh-queue-permission-denied-no-app-install'
New-Case 'existing-friendly-printer';$script:queueName='Samsung SCX-4200'
Install-Test
Assert-Test ($script:createQueueCalls -eq 0) 'Existing friendly queue was recreated.'
Pass 'existing-friendly-queue-reused-without-mutation'

New-Case 'foreign-only-endpoint';$script:urls=@('http://192.0.2.1/ipp/print')
Assert-Refused {Install-Test} 'endpoint conflicts'
Assert-Test (!(Test-Path -LiteralPath $base)) 'Foreign-only endpoint created installation state.'
Pass 'foreign-only-endpoint-refusal'

New-Case 'conflicting-endpoint';$script:urls+=@('http://192.0.2.1/ipp/print')
Assert-Refused {Install-Test} 'endpoint conflicts'
Assert-Test (!(Test-Path -LiteralPath $base)) 'Conflicting queue mutated install.'
Pass 'conflicting-endpoint-refusal'
$reportPath=Write-BackgroundSetupResult -Folder $source -Success $false -ErrorMessage 'Synthetic endpoint refusal'
$report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
Assert-Test (!$report.success -and $report.outcome -eq 'Failed' -and $report.stage -eq 'QueueVerification') 'Failure report lacks outcome or stage.'
Assert-Test (@($report.queue_diagnostic.recognized_endpoints|Where-Object classification -eq 'Expected').Count -eq 1 -and @($report.queue_diagnostic.recognized_endpoints|Where-Object classification -eq 'Other').Count -eq 1) 'Endpoint classifications missing.'
Assert-Test ((Get-Content -LiteralPath $reportPath -Raw) -notmatch '192\.0\.2\.1') 'Report leaked an unrelated endpoint.'
$successPath=Write-BackgroundSetupResult -Folder $source -Success $true -ErrorMessage ''
Assert-Test ($successPath -ne $reportPath -and (Get-Content -LiteralPath $successPath -Raw|ConvertFrom-Json).success) 'Success report missing or overwrote previous report.'
Pass 'timestamped-result-report-and-private-endpoint-classification'

New-Case 'unknown-shortcut'
[IO.File]::WriteAllText((Get-BackgroundShortcutPath 'Startup'),'unknown registration')
Assert-Refused {Install-Test} 'shortcut already exists'
Assert-Test (!(Test-Path -LiteralPath $base)) 'Unknown shortcut refusal created install state.'
Pass 'unknown-registration-preserved'

$sourceHashes=@{};foreach($name in @('setup.ps1','uninstall.ps1','INSTALL.cmd','UNINSTALL.cmd','test-setup.ps1')){$sourceHashes[$name]=Get-BackgroundHash (Join-Path $PSScriptRoot $name)}
Write-BackgroundJson (Join-Path $OutputRoot 'results.json') @{status='PASS';groups=$results;source_sha256=$sourceHashes;powershell_version=$PSVersionTable.PSVersion.ToString();hardware_actions=$false;system_registration=$false;limits=@('Synthetic ARM64 headers; not executable validation','Queue endpoint and shortcut COM are mocked','Partial shortcut failure deliberately preserves state and requires diagnosis')}
Write-Host ('PASS: '+$results.Count+' isolated groups. '+(Join-Path $OutputRoot 'results.json'))
