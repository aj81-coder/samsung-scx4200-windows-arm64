# SPDX-License-Identifier: Apache-2.0
param([switch]$NoLaunch)
$ErrorActionPreference='Stop'
$script:BackgroundSetupStage='NotStarted'
$script:BackgroundQueueDiagnostic=$null
function Write-BackgroundSetupResult([string]$Folder,[bool]$Success,[string]$ErrorMessage){
 $path=Join-Path $Folder ('setup-result-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N')+'.json')
 Write-BackgroundJson $path ([ordered]@{schema_version=1;success=$Success;outcome=$(if($Success){'Installed'}else{'Failed'});stage=$script:BackgroundSetupStage;error=$ErrorMessage;queue_diagnostic=$script:BackgroundQueueDiagnostic;created_utc=[DateTime]::UtcNow.ToString('o')})
 Write-Host ('Setup report: '+$path)
 return $path
}
function Assert-BackgroundSafePath([string]$Path) {
 $full=[IO.Path]::GetFullPath($Path)
 if($full -notmatch '^[A-Za-z]:\\' -or $full.Length -le 3 -or $full.Substring(3).Contains(':')){throw 'A local absolute path is required.'}
 $cursor=$full
 while($cursor){
  if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked folders are not supported.'}}
  $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
 }
 return $full
}
function Assert-BackgroundPlatform {
 if([Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE','Machine') -ine 'ARM64'){throw 'This package requires Windows on ARM64. No installation was attempted.'}
}
function Assert-BackgroundArm64Binary([string]$Path){
 $stream=[IO.File]::OpenRead($Path);$reader=New-Object IO.BinaryReader($stream)
 try{if($reader.ReadUInt16() -ne 0x5a4d){throw 'Invalid executable header.'};$stream.Position=60;$offset=$reader.ReadUInt32();if($offset -gt $stream.Length-6){throw 'Invalid executable offset.'};$stream.Position=$offset;if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0xaa64){throw 'The package requires native ARM64 executable files.'}}finally{$reader.Dispose();$stream.Dispose()}
}
function Get-BackgroundHash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Assert-BackgroundStopped([string]$Data) {
 if(@(Get-Process -Name 'SCX4200-Printer','SCX4200-Reliable-Bridge' -ErrorAction SilentlyContinue).Count){throw 'Exit the printer application and stop the old bridge first.'}
 if(@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -eq 8631).Count){throw 'Port 8631 is in use. Stop the existing bridge first.'}
 if(Test-Path -LiteralPath (Join-Path $Data 'SESSION-ACTIVE.lock')){throw 'A stopped session needs deliberate recovery. Preserve results and recover it before installing or removing the application.'}
}
function New-BackgroundQueue([string]$Source){
 . (Join-Path $PSScriptRoot 'queue-setup.ps1')
 return Invoke-QueueSetup -Action Install -Root $Source
}
function Get-BackgroundQueue {
 $script:BackgroundQueueDiagnostic=[ordered]@{property_names=@();recognized_endpoints=@();queue_verified=$false;endpoint_verified=$false;verification_method=$null}
 $all=@(Get-Printer -ErrorAction Stop)
 $friendly=@($all | Where-Object Name -eq 'Samsung SCX-4200')
 $legacy=@($all | Where-Object Name -eq 'SCX-4200 Capture Test')
 if($friendly.Count){$selected='Samsung SCX-4200';$queues=$friendly}
 elseif($legacy.Count){$selected='SCX-4200 Capture Test';$queues=$legacy}
 else{
  $result=New-BackgroundQueue $script:BackgroundPackageSource
  if(!$result.success){throw ('Printer setup did not complete: '+$result.error)}
  $selected='Samsung SCX-4200';$queues=@(Get-Printer -ErrorAction Stop | Where-Object Name -eq $selected)
 }
 if($queues.Count -ne 1 -or $queues[0].Name -cne $selected -or $queues[0].DriverName -cne 'Microsoft IPP Class Driver' -or [string]::IsNullOrWhiteSpace([string]$queues[0].PortName)){throw 'The selected printer requires Microsoft IPP Class Driver and a recorded port. No existing printer was changed.'}
 $queue=$queues[0];$urls=@()
 foreach($property in @(Get-PrinterProperty -PrinterName $queue.Name -ErrorAction Stop)){
  $script:BackgroundQueueDiagnostic.property_names+=@([string]$property.PropertyName)
  if($property.PropertyName -match '(?i)(DeviceURL|PrinterURL|IppURI|IppURL)$'){
   $urls+=@($property.Value)
   foreach($value in @($property.Value)){$script:BackgroundQueueDiagnostic.recognized_endpoints+=@{source='PrinterProperty';name=[string]$property.PropertyName;classification=$(if([string]$value -ceq 'http://127.0.0.1:8631/ipp/print'){'Expected'}else{'Other'})}}
  }
 }
 $key='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Print\Printers\'+$queue.Name
 if(Test-Path -LiteralPath $key){$values=Get-ItemProperty -LiteralPath $key;foreach($name in @('DeviceURL','PrinterURL','IppURI','IppURL')){if($values.PSObject.Properties[$name]){$urls+=@($values.$name);foreach($value in @($values.$name)){$script:BackgroundQueueDiagnostic.recognized_endpoints+=@{source='PrinterRegistry';name=$name;classification=$(if([string]$value -ceq 'http://127.0.0.1:8631/ipp/print'){'Expected'}else{'Other'})}}}}}
 $matching=@($urls | Where-Object {[string]$_ -ceq 'http://127.0.0.1:8631/ipp/print'})
 $conflicting=@($urls | Where-Object {![string]::IsNullOrWhiteSpace([string]$_) -and [string]$_ -cne 'http://127.0.0.1:8631/ipp/print'})
 if($conflicting.Count){throw 'The reported printer endpoint conflicts with http://127.0.0.1:8631/ipp/print. No printer or installation changes were made.'}
 # Installing the per-user application does not adopt, edit or remove this
 # existing queue. Windows may expose only FormTrayTable, with no URL property.
 # Record that distinction rather than invent endpoint verification or block
 # an already working queue solely because its URL is not exposed.
 $endpointVerified=$matching.Count -gt 0
 $method=if($endpointVerified){'ReportedExpectedEndpoint'}else{'ExistingQueueNameDriverPort_EndpointNotExposed'}
 $script:BackgroundQueueDiagnostic.queue_verified=$true
 $script:BackgroundQueueDiagnostic.endpoint_verified=$endpointVerified
 $script:BackgroundQueueDiagnostic.verification_method=$method
 if(@(Get-PrintJob -PrinterName $queue.Name -ErrorAction Stop).Count){throw 'Finish or cancel existing print jobs and complete any old bridge recovery before installing.'}
 return [ordered]@{name=[string]$queue.Name;driver=[string]$queue.DriverName;port=[string]$queue.PortName;uri='http://127.0.0.1:8631/ipp/print';uri_role='ExpectedLocalBridgeEndpoint';endpoint_verified=$endpointVerified;verification_method=$method;owned=$false}
}
function Write-BackgroundJson([string]$Path,$Value){
 $bytes=[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 12));$stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Get-BackgroundShortcutPath([string]$Kind){return Join-Path ([Environment]::GetFolderPath($Kind)) 'Samsung SCX-4200.lnk'}
function Get-BackgroundShortcut([string]$Path){$shell=New-Object -ComObject WScript.Shell;return $shell.CreateShortcut($Path)}
function Invoke-BackgroundInstall([string]$Source=$PSScriptRoot,[string]$LocalRoot=$env:LOCALAPPDATA,[switch]$SkipLaunch){
 $script:BackgroundSetupStage='Platform';$script:BackgroundQueueDiagnostic=$null
 Assert-BackgroundPlatform
 $script:BackgroundSetupStage='Preflight'
 $source=Assert-BackgroundSafePath $Source;$base=Assert-BackgroundSafePath (Join-Path $LocalRoot 'SCX4200');$app=Join-Path $base 'app';$data=Join-Path $base 'data';$recordPath=Join-Path $base 'installation.json'
 foreach($path in @($source,$base,$app,$data)){ $null=Assert-BackgroundSafePath $path }
 if(Test-Path -LiteralPath $app){throw 'An application folder already exists. This prototype will not overwrite or adopt it.'}
 if(Test-Path -LiteralPath $recordPath){throw 'An installation record already exists. Remove that owned installation first.'}
 Assert-BackgroundStopped $data
 $script:BackgroundPackageSource=$source
 $script:BackgroundSetupStage='QueueVerification';$queue=Get-BackgroundQueue
 $script:BackgroundSetupStage='PackageVerification'
 $manifest=Get-Content -LiteralPath (Join-Path $source 'background-package-manifest.json') -Raw | ConvertFrom-Json
 if($manifest.schema_version -ne 1 -or !@($manifest.files).Count){throw 'Invalid package manifest.'}
 $required=@('SCX4200-Printer.exe','SCX4200-Reliable-Bridge.exe','SCX4200-Render.exe','SCX4200-Bridge-Sender.exe','cups.dll','setup.ps1','uninstall.ps1','INSTALL.cmd','UNINSTALL.cmd','housekeeping.ps1','controls.ps1','control-ipp.ps1','queue-setup.ps1');$seen=@{};$files=@()
 foreach($file in $manifest.files){
  $relative=[string]$file.path
  if(!$relative -or $relative -match '(^[\\/]|:|(^|[\\/])\.\.?([\\/]|$))' -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid manifest file path or hash.'}
  $relative=$relative.Replace('/','\');if($seen.ContainsKey($relative)){throw 'Duplicate manifest path.'};$seen[$relative]=$true
  $input=Assert-BackgroundSafePath (Join-Path $source $relative)
  if(!(Test-Path -LiteralPath $input -PathType Leaf) -or (Get-BackgroundHash $input) -cne ([string]$file.sha256).ToLowerInvariant()){throw ('Package integrity check failed: '+$relative)}
  $files+=@{path=$relative;sha256=([string]$file.sha256).ToLowerInvariant()}
 }
 foreach($name in $required){if(!$seen.ContainsKey($name)){throw ('Required package file missing: '+$name)}}
 foreach($name in @('SCX4200-Printer.exe','SCX4200-Reliable-Bridge.exe','SCX4200-Render.exe','SCX4200-Bridge-Sender.exe','cups.dll')){Assert-BackgroundArm64Binary (Join-Path $source $name)}
 # The complete candidate is checked before any registration is created.
 $startup=Assert-BackgroundSafePath (Get-BackgroundShortcutPath 'Startup')
 $menu=Assert-BackgroundSafePath (Get-BackgroundShortcutPath 'Programs')
 foreach($path in @($startup,$menu)){if(Test-Path -LiteralPath $path){throw 'A shortcut already exists; refusing to overwrite an unknown registration.'}}
 $script:BackgroundSetupStage='Staging'
 $null=New-Item -ItemType Directory -Path $base -Force
 $stage=Join-Path $base ('stage-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $stage
 foreach($file in $files){$to=Join-Path $stage $file.path;$null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($to)) -Force;Copy-Item -LiteralPath (Join-Path $source $file.path) -Destination $to;if((Get-BackgroundHash $to) -cne $file.sha256){throw 'Staged package verification failed; no registration was created.'}}
 $target=Join-Path $app 'SCX4200-Printer.exe';$arguments='--data-dir "'+$data+'"'
 $record=[ordered]@{schema_version=1;state='Prepared';transaction_id=[guid]::NewGuid().ToString('N');app=$app;data=$data;stage=$stage;queue=$queue;files=$files;shortcuts=@(@{path=$startup;target=$target;arguments=$arguments},@{path=$menu;target=$target;arguments=$arguments});created_utc=[DateTime]::UtcNow.ToString('o')}
 $script:BackgroundSetupStage='PreparedOwnership';Write-BackgroundJson $recordPath $record
 # The durable Prepared record allows conservative uninstall after partial failure.
 [IO.Directory]::Move($stage,$app)
 $null=New-Item -ItemType Directory -Path $data -Force
 $script:BackgroundSetupStage='ShortcutRegistration'
 foreach($entry in $record.shortcuts){if(Test-Path -LiteralPath $entry.path){throw 'Shortcut appeared during installation; refusing to overwrite it.'};$shortcut=Get-BackgroundShortcut $entry.path;$shortcut.TargetPath=$target;$shortcut.Arguments=$arguments;$shortcut.WorkingDirectory=$app;$shortcut.Description='Samsung SCX-4200 printer';$shortcut.Save();$entry.sha256=Get-BackgroundHash $entry.path}
 # Commit without discarding the durable first transaction record.
 $script:BackgroundSetupStage='Commit';$record.state='Installed';$commit=Join-Path $base 'installation-complete.json';Write-BackgroundJson $commit $record
 $script:BackgroundSetupStage='Launch'
 if(!$SkipLaunch){Start-Process -FilePath $target -ArgumentList $arguments -WorkingDirectory $app -WindowStyle Hidden}
 Write-Host 'Installed. The printer application starts when you sign in. Print using the printer name recorded above from your normal applications.'
 Write-Host ('Printer: '+$queue.name)
 $script:BackgroundSetupStage='Complete'
}
if($MyInvocation.InvocationName -ne '.') {
 $setupSucceeded=$false;$setupError=''
 try{Invoke-BackgroundInstall -SkipLaunch:$NoLaunch;$setupSucceeded=$true}catch{$setupError=$_.Exception.Message;Write-Host ('Installation did not complete: '+$setupError)}
 try{$null=Write-BackgroundSetupResult -Folder $PSScriptRoot -Success $setupSucceeded -ErrorMessage $setupError}catch{Write-Host ('Could not save setup report: '+$_.Exception.Message)}
 if(!$setupSucceeded){exit 1}
}


