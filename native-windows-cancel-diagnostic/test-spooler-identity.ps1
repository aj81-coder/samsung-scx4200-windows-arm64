# SPDX-License-Identifier: Apache-2.0
# Run with Windows PowerShell 5.1: -NoProfile -ExecutionPolicy Bypass -File ...
$ErrorActionPreference='Stop'
$helper=Join-Path $PSScriptRoot 'spooler-identity.ps1'
$source=[IO.File]::ReadAllText($helper)
# Compile the exact production C# with an injected test boundary in one assembly.
# No mock calls service/process APIs; only the two explicit native probes below do.
$match=[regex]::Match($source,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (!$match.Success) { throw 'Production C# source block missing' }
$mock=@'
namespace Scx4200Identity {
    public sealed class MockApi : IApi {
        public string mode;
        public int calls, opened, closed, statusCalls;
        public bool badClose;
        private System.Collections.Generic.HashSet<System.IntPtr> live = new System.Collections.Generic.HashSet<System.IntPtr>();
        public MockApi(string value) { mode=value; }
        System.IntPtr Open(int value,string stage,out int error) {
            calls++; error=mode==stage?5:0;
            if(error!=0) return System.IntPtr.Zero;
            System.IntPtr h=new System.IntPtr(value); live.Add(h); opened++; return h;
        }
        public System.IntPtr Manager(out int error) { return Open(1,"OpenSCManager",out error); }
        public System.IntPtr Service(System.IntPtr manager,out int error) { return Open(2,"OpenService",out error); }
        public bool Status(System.IntPtr service,out ServiceStatus status,out int error) {
            calls++; statusCalls++; status=new ServiceStatus();
            status.state=mode=="ServiceNotRunning"?1u:4u;
            status.pid=mode=="ZeroPid"?0u:123u;
            if(statusCalls==2 && mode=="ServiceIdentityChanged") status.pid=124;
            if(statusCalls==2 && mode=="ServiceStoppedDuringProbe") status.state=1;
            error=(statusCalls==1 && mode=="QueryServiceStatusEx") || (statusCalls==2 && mode=="RecheckServiceStatus")?5:0;
            return error==0;
        }
        public System.IntPtr Process(uint pid,out int error) { return Open(3,"OpenProcess",out error); }
        public bool Creation(System.IntPtr process,out ulong creation,out int error) {
            calls++; creation=mode=="InvalidCreationTime"?0ul:456ul;
            error=mode=="GetProcessTimes"?5:0; return error==0;
        }
        void Close(System.IntPtr h) { if(!live.Remove(h)) badClose=true; closed++; }
        public void CloseService(System.IntPtr h) { Close(h); }
        public void CloseProcess(System.IntPtr h) { Close(h); }
    }
}
'@
if ('Scx4200Identity.Probe' -as [type]) { throw 'Run this test in a fresh PowerShell process' }
Add-Type -TypeDefinition ($match.Groups[1].Value + [Environment]::NewLine + $mock)
. $helper
$cases=@()
foreach($mode in @('Success','OpenSCManager','OpenService','QueryServiceStatusEx','ServiceNotRunning','ZeroPid','OpenProcess','GetProcessTimes','InvalidCreationTime','RecheckServiceStatus','ServiceIdentityChanged','ServiceStoppedDuringProbe')) {
    $api=New-Object Scx4200Identity.MockApi($mode)
    $r=[Scx4200Identity.Probe]::Spooler($api)
    $expectedStage=switch($mode) {
        'Success' {'Verified'}
        'ZeroPid' {'ServiceNotRunning'}
        'ServiceStoppedDuringProbe' {'ServiceIdentityChanged'}
        default {$mode}
    }
    if($r.stage -ne $expectedStage -or $r.success -ne ($mode -eq 'Success')) { throw "Wrong result for $mode" }
    if($api.opened -ne $api.closed -or $api.badClose) { throw "Handle cleanup failure for $mode" }
    if($mode -eq 'Success' -and $r.identity -ne '123:456') { throw 'Identity missing creation time' }
    if($mode -ne 'Success' -and $r.identity) { throw 'Failure returned usable identity' }
    if($mode -in 'OpenSCManager','OpenService','QueryServiceStatusEx','OpenProcess','GetProcessTimes','RecheckServiceStatus' -and $r.win32_error -ne 5) { throw "Missing denial code for $mode" }
    $cases+=@{name=$mode;result='PASS';stage=$r.stage;win32_error=$r.win32_error;handles_opened=$api.opened;handles_closed=$api.closed}
}
$one=Get-ScxCurrentProcessIdentity
$two=Get-ScxCurrentProcessIdentity
if(!$one.success -or !$two.success -or $one.identity -ne $two.identity -or $one.process_id -ne $PID -or [uint64]$one.creation_filetime -le 0) { throw 'Native current process fingerprint failed' }
$cases+=@{name='NativeCurrentProcessStableFingerprint';result='PASS';method=$one.method}
# Loading twice must reuse its existing type without recompiling it.
. $helper
if((Get-ScxCurrentProcessIdentity).identity -ne $one.identity) { throw 'Repeat dot-source changed identity' }
$cases+=@{name='RepeatDotSource';result='PASS'}
$initializer=${function:Initialize-ScxIdentityNative}
function Initialize-ScxIdentityNative { throw 'PRIVATE SOURCE PATH MUST NOT APPEAR' }
$failed=Get-ScxSpoolerIdentity
if($failed.success -or $failed.stage -ne 'InitializeNativeProbe' -or ($failed | ConvertTo-Json) -match 'PRIVATE') { throw 'Unsafe initialization failure' }
Set-Item Function:Initialize-ScxIdentityNative $initializer
$cases+=@{name='InitializationFailureSanitized';result='PASS'}
$converter=${function:ConvertTo-ScxIdentityResult}
function ConvertTo-ScxIdentityResult($value) { throw 'PRIVATE NATIVE EXCEPTION DETAILS' }
$failed=Get-ScxCurrentProcessIdentity
if($failed.success -or $failed.stage -ne 'NativeProbeException' -or ($failed | ConvertTo-Json) -match 'PRIVATE') { throw 'Unsafe native exception failure' }
Set-Item Function:ConvertTo-ScxIdentityResult $converter
$cases+=@{name='NativeExceptionSanitized';result='PASS'}
$statusFunction=${function:Get-ScxNativeSpoolerStatus}
function Get-CimInstance {
    param($ClassName,$Filter,$Property,$OperationTimeoutSec,$ErrorAction)
    if($ClassName -ne 'Win32_Process' -or $Filter -ne 'ProcessId=123' -or $OperationTimeoutSec -ne 5) { throw 'Wrong WMI query scope' }
    $script:wmiReads++
    if($script:wmiMode -eq 'denied') { throw 'PRIVATE WMI ERROR DETAILS' }
    $creation=[DateTime]'2026-01-01T00:00:00Z'
    if($script:wmiMode -eq 'creation-change' -and $script:wmiReads -eq 2) { $creation=$creation.AddSeconds(1) }
    if($script:wmiMode -eq 'null') { $creation=$null }
    if($script:wmiMode -eq 'invalid-date') { $creation=[DateTime]'1601-01-01' }
    $id=if($script:wmiMode -eq 'wrong-pid') {124} else {123}
    $row=[pscustomobject]@{ProcessId=$id;CreationDate=$creation}
    if($script:wmiMode -eq 'multiple') { return @($row,$row) }
    return $row
}
function Get-ScxNativeSpoolerStatus {
    return [pscustomobject]@{
        success=($script:wmiMode -ne 'service-denied' -and $script:wmiMode -ne 'service-stopped')
        service_state=$(if($script:wmiMode -eq 'service-stopped') {1} else {4})
        process_id=$(if($script:wmiMode -eq 'service-pid-change') {124} else {123})
        win32_error=$(if($script:wmiMode -eq 'service-denied') {5} else {0})
    }
}
foreach($mode in @('success','denied','null','invalid-date','wrong-pid','multiple','creation-change','service-denied','service-stopped','service-pid-change')) {
    $script:wmiMode=$mode; $script:wmiReads=0
    $fallback=Get-ScxWmiSpoolerIdentity ([pscustomobject]@{process_id=123;service_state=4;stage='OpenProcess';win32_error=5})
    if($fallback.success -ne ($mode -eq 'success')) { throw "Wrong WMI result for $mode" }
    if($mode -eq 'success' -and (!$fallback.identity -or [uint64]$fallback.creation_filetime -le 0 -or $script:wmiReads -ne 2)) { throw 'Missing WMI creation fingerprint/recheck' }
    if($mode -ne 'success' -and $fallback.identity) { throw "WMI failure returned usable identity: $mode" }
    if(($fallback | ConvertTo-Json) -match 'PRIVATE') { throw 'WMI exception leaked' }
    if($mode -eq 'denied' -and (!$fallback.query_exception_type -or $null -eq $fallback.query_hresult -or $fallback.query_exception_type -match '[\\/]')) { throw 'Missing safe WMI error metadata' }
    $cases+=@{name=('WmiFallback-'+$mode);result='PASS';stage=$fallback.stage}
}
Remove-Item Function:Get-CimInstance
Set-Item Function:Get-ScxNativeSpoolerStatus $statusFunction
foreach($mode in @('Success','OpenSCManager','OpenService','QueryServiceStatusEx','ServiceNotRunning')) {
    $api=New-Object Scx4200Identity.MockApi($mode)
    $status=[Scx4200Identity.Probe]::StatusOnly($api)
    if($status.success -ne ($mode -eq 'Success') -or $api.opened -ne $api.closed -or $api.badClose) { throw "Status-only probe failure: $mode" }
    $cases+=@{name=('NativeStatusOnly-'+$mode);result='PASS';handles_opened=$api.opened;handles_closed=$api.closed}
}
$native=Get-ScxSpoolerIdentity
if($native.success) {
    if($native.service_state -ne 4 -or !$native.identity -or [uint64]$native.creation_filetime -le 0) { throw 'Invalid native service fingerprint' }
} elseif($native.stage -notin 'OpenSCManager','OpenService','QueryServiceStatusEx','ServiceNotRunning','OpenProcess','GetProcessTimes','InvalidCreationTime','RecheckServiceStatus','ServiceIdentityChanged') { throw 'Unclassified native failure' }
$cases+=@{name='NativeSpoolerReadOnlyProbe';result='PASS';probe=$native;note='Classified failure is allowed on development host; target service permission still requires testing.'}
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path $root 'build/windows-cancel-diagnostic/spooler-identity-tests.json'
New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent) | Out-Null
$report=@{result='PASS';cases=$cases;count=$cases.Count;helper_sha256=(Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant();powershell_version=$PSVersionTable.PSVersion.ToString();no_service_mutations=$true}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $out -Encoding UTF8
Write-Output ("PASS: {0} checks. Evidence: {1}" -f $cases.Count,$out)
