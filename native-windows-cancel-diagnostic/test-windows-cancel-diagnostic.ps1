# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'windows-cancel-diagnostic.ps1')
$script:realQueueFunction=${function:Get-DiagnosticQueue}
$script:realSpoolerFunction=${function:Get-DiagnosticSpooler}
$script:passed=0
$script:cases=@()
function Require($ok,$message) { if (!$ok) { throw $message }; $script:passed++ }
function Get-DiagnosticTime { return ([DateTime]'2026-10-14T00:00:00Z').AddSeconds($script:seconds) }
function Wait-DiagnosticTick { $script:seconds+=0.25 }
function Get-BridgeIdentity { return @{Id=100; Start=555; Path='mock-only'} }
function Assert-SameBridge($identity) { if ($script:mode -eq 'bridge-restart' -and $script:seconds -ge 5) { throw 'Bridge changed before cancellation' } }
function Get-DiagnosticQueue {
    $key=if ($script:mode -eq 'queue-change' -and $script:seconds -ge 5) {'changed'} else {'stable'}
    return @{Key=$key; Public=@{queue='SCX-4200 Capture Test';driver='Microsoft IPP Class Driver'}}
}
function Get-DiagnosticSpooler {
    if ($script:mode -eq 'native-probe-failure') { return (& $script:realSpoolerFunction) }
    if ($script:mode -eq 'spooler-restart' -and $script:seconds -ge 5) {return 'changed'}
    return 'stable'
}
function Get-ScxSpoolerIdentity {
    return [pscustomobject]@{success=$false;stage='OpenProcess';win32_error=5;service_state=4;process_id=123;creation_filetime=$null;identity=$null;method='MockNativeQuery'}
}
function MockJob($id=42,$status=16,$offset=0) {
    return [pscustomobject]@{ID=$id;JobStatus=$status;SubmittedTime=([DateTime]'2026-10-14T00:00:01Z').AddSeconds($offset);DocumentName='PRIVATE TITLE MUST NOT APPEAR';UserName='PRIVATE USER'}
}
function Get-DiagnosticWindowsJobs {
    if ($script:seconds -ge 11) { $script:finalWindowsReads++ }
    if ($script:mode -eq 'pending-baseline') { return @(MockJob) }
    if ($script:mode -eq 'retained-baseline') { return @(MockJob 42 12288) }
    if ($script:seconds -lt 1 -or $script:mode -eq 'no-job' -or ($script:mode -eq 'delayed-job' -and $script:seconds -lt 130)) { return @() }
    if ($script:mode -eq 'multiple-local' -and $script:seconds -ge 2) { return @((MockJob),(MockJob 43)) }
    if ($script:mode -eq 'disappeared' -and $script:seconds -ge 2) { return @() }
    if ($null -ne $script:removeTime) { return @() }
    if ($script:mode -in 'retained-complete','retained-no-forward','retained-backend-ended' -and $script:seconds -ge 2) { return @(MockJob 42 12288) }
    if ($script:finalWindowsReads -ge 2) {
        if ($script:mode -eq 'late-printed') { return @(MockJob 42 128) }
        if ($script:mode -eq 'late-disappeared') { return @() }
        if ($script:mode -eq 'late-id-reuse') { return @(MockJob 42 16 1) }
    }
    if ($script:mode -eq 'printed' -and $script:seconds -ge 2) { return @(MockJob 42 128) }
    if ($script:mode -eq 'deleting' -and $script:seconds -ge 2) { return @(MockJob 42 4) }
    if ($script:mode -eq 'complete' -and $script:seconds -ge 2) { return @(MockJob 42 4096) }
    if ($script:mode -eq 'unknown-status' -and $script:seconds -ge 2) { return @(MockJob 42 32768) }
    if ($script:mode -eq 'restarted-status' -and $script:seconds -ge 2) { return @(MockJob 42 2048) }
    if ($script:mode -eq 'restarted-text' -and $script:seconds -ge 2) { return @(MockJob 42 'Printing, Restarted') }
    if ($script:mode -eq 'id-reuse' -and $script:seconds -ge 5) { return @(MockJob 42 16 1) }
    if ($script:mode -eq 'different-id' -and $script:seconds -ge 5) { return @(MockJob 43) }
    if ($script:mode -eq 'no-fingerprint') { return @([pscustomobject]@{ID=42;JobStatus=16;SubmittedTime=$null}) }
    return @(MockJob)
}
function New-MockIppGroup($id,$state) { return @{Tag=2; Attributes=@{'job-id'=@($id);'job-state'=@($state)}} }
function Invoke-Ipp([int]$operation,[int]$jobId=0) {
    $script:operations+= $operation
    if ($operation -notin 9,10) { throw 'Mutation through IPP is forbidden' }
    if ($operation -eq 10) {
        if ($script:mode -eq 'remote-baseline') { return @{Groups=@((New-MockIppGroup 7 5))} }
        if ($script:seconds -lt 1 -or $script:mode -eq 'no-job' -or ($script:mode -eq 'delayed-job' -and $script:seconds -lt 130)) { return @{Groups=@()} }
        if ($script:mode -eq 'multiple-remote' -and $script:seconds -ge 2) { return @{Groups=@((New-MockIppGroup 7 5),(New-MockIppGroup 8 5))} }
        if ($script:mode -eq 'remote-change' -and $script:seconds -ge 5) { return @{Groups=@((New-MockIppGroup 8 5))} }
        if ($script:mode -eq 'retained-backend-ended' -and $script:seconds -ge 3) { return @{Groups=@()} }
        if ($null -ne $script:removeTime -and $script:mode -notin 'cancel-not-forwarded','retained-no-forward') { return @{Groups=@()} }
        $activeState=if ($script:mode -like 'retained-*' -and $script:seconds -lt 3) {4} else {5}
        return @{Groups=@((New-MockIppGroup 7 $activeState))}
    }
    if ($jobId -ne 7) { throw 'Incorrect selected remote ID' }
    $state=if ($script:mode -eq 'retained-backend-ended' -and $script:seconds -ge 3) {9} elseif ($null -ne $script:removeTime -and $script:mode -notin 'cancel-not-forwarded','retained-no-forward') {7} elseif ($script:mode -like 'retained-*' -and $script:seconds -lt 3) {4} else {5}
    return @{Groups=@((New-MockIppGroup 7 $state))}
}
function Remove-DiagnosticWindowsJob([int]$jobId) {
    $script:removes+= $jobId
    if ($script:mode -eq 'remove-failure') { throw 'Remove-PrintJob failed; no retry made' }
    $script:removeTime=$script:seconds
}
function RunCase($mode,$outcome,$calls) {
    $script:mode=$mode; $script:seconds=0; $script:removeTime=$null; $script:removes=@(); $script:operations=@(); $script:finalWindowsReads=0
    $memory=New-Object IO.MemoryStream; $writer=New-Object IO.StreamWriter($memory); $writer.AutoFlush=$true
    $result=Invoke-WindowsCancelDiagnostic $writer
    $writer.Flush(); $trace=[Text.Encoding]::UTF8.GetString($memory.ToArray()); $writer.Dispose(); $memory.Dispose()
    Require ($result.outcome -eq $outcome) ($mode+': unexpected outcome '+$result.outcome+' '+$result.error)
    Require ($script:removes.Count -eq $calls -and $result.remove_attempts -eq $calls) ($mode+': wrong mutation count')
    Require (@($script:operations | Where-Object {$_ -notin 9,10}).Count -eq 0) ($mode+': IPP mutation attempted')
    Require ($trace -notmatch 'PRIVATE TITLE|PRIVATE USER|mock-only') ($mode+': private values in trace')
    if ($calls) {
        Require ($script:removes[0] -eq 42 -and $result.windows_job_id -eq 42 -and $result.ipp_job_id -eq 7) ($mode+': confused Windows/IPP IDs')
        Require ($script:seconds -ge 11) ($mode+': canceled before 10-second processing wait')
    }
    $script:cases+=@{name=$mode;outcome=$result.outcome;remove_calls=$script:removes.Count;result='PASS'}
    return $result
}
$null=RunCase 'success' 'WindowsCancelRemoteState7Observed' 1
$r=RunCase 'retained-complete' 'WindowsCancelRemoteState7Observed' 1
Require ($r.retained_handoff_used -and $script:seconds -ge 33) 'Retained submission record was not checked against processing bridge job'
$r=RunCase 'retained-no-forward' 'WindowsCancelIssuedRemoteCancelNotObserved' 1
Require ($r.retained_handoff_used -and !$r.remote_cancelled_observed) 'Local retained-record deletion falsely proved remote cancellation'
$null=RunCase 'retained-backend-ended' 'BridgeJobEndedBeforeCancel' 0
$null=RunCase 'retained-baseline' 'Refused' 0
$recent=Get-DiagnosticJobView (MockJob 42 12288)
Require (Test-DiagnosticWindowsCandidate $recent ([DateTime]'2026-10-14T00:00:00Z')) 'Fresh Complete Retained record rejected'
Require (!(Test-DiagnosticWindowsCandidate $recent ([DateTime]'2026-10-14T00:01:00Z'))) 'Old retained record allowed'
$badRetained=Get-DiagnosticJobView (MockJob 42 12290)
Require (!(Test-DiagnosticWindowsCandidate $badRetained ([DateTime]'2026-10-14T00:00:00Z'))) 'Unproved retained/error status combination allowed'
$r=RunCase 'cancel-not-forwarded' 'WindowsCancelIssuedRemoteCancelNotObserved' 1
Require (!$r.remote_cancelled_observed) 'Local disappearance was treated as remote cancel'
$null=RunCase 'remove-failure' 'ObservationOrRemoveFailedNoRetry' 1
foreach ($mode in 'pending-baseline','remote-baseline','multiple-local','multiple-remote','remote-change',
    'bridge-restart','queue-change','spooler-restart','id-reuse','different-id','no-fingerprint','unknown-status','restarted-status','restarted-text','late-id-reuse') {
    $null=RunCase $mode 'Refused' 0
}
foreach ($mode in 'printed','deleting','complete','disappeared','late-printed','late-disappeared') { $null=RunCase $mode 'NoActiveWindowsJob' 0 }
$null=RunCase 'no-job' 'TimedOutBeforeCancel' 0
Require ($script:seconds -ge 600) 'Monitor timed out before the full ten-minute acquisition period'
$r=RunCase 'delayed-job' 'WindowsCancelRemoteState7Observed' 1
Require (([DateTime]$r.remove_requested_utc-[DateTime]'2026-10-14T00:00:00Z').TotalSeconds -ge 140) 'Job arriving after old deadline was not observed for ten seconds'
$r=RunCase 'native-probe-failure' 'Refused' 0
Require ($r.spooler_probe.stage -eq 'OpenProcess' -and $r.spooler_probe.win32_error -eq 5) 'Native spooler failure details lost'
# Textual status fallback, not just enum/numeric statuses.
$v=Get-DiagnosticJobView ([pscustomobject]@{ID=4;JobStatus='Printing, Printed'; SubmittedTime=[DateTime]'2026-10-14'})
Require $v.terminal 'Textual Printed status was not terminal'
$v=Get-DiagnosticJobView ([pscustomobject]@{ID=4;JobStatus=80; SubmittedTime=[DateTime]'2026-10-14'})
Require (!$v.terminal) 'Printing + PaperOut incorrectly considered terminal'
$rejected=$false
try { $null=Get-DiagnosticJobView ([pscustomobject]@{ID=4;JobStatus='UnrecognizedValue';SubmittedTime=[DateTime]'2026-10-14'}) } catch {$rejected=$true}
Require $rejected 'Unknown textual status was accepted'
# Exercise the real queue snapshot function against cmdlet mocks, including privacy.
function Get-Printer { return [pscustomobject]@{Name='SCX-4200 Capture Test';DriverName='Microsoft IPP Class Driver';PortName=$script:mockPort;Type='Local';KeepPrintedJobs=$true} }
function Get-PrinterPort { return [pscustomobject]@{Name=$script:mockPort;Description='PRIVATE port description';PrinterHostAddress='PRIVATE host';PortNumber=8631;Protocol=1} }
function Get-PrinterDriver { return [pscustomobject]@{Name='Microsoft IPP Class Driver';MajorVersion=4;PrinterEnvironment='Windows ARM64'} }
$script:mockPort='http://127.0.0.1:8631/ipp/print'
$q=& $script:realQueueFunction
Require ($q.Public.port_uri_known_loopback -eq $true -and $q.Public.keep_printed_jobs -eq $true) 'Queue metadata lost loopback/retained-jobs state'
Require (($q.Public | ConvertTo-Json -Compress) -notmatch 'PRIVATE|http://') 'Raw port metadata leaked'
Require ($q.Public.port_identity_sha256 -match '^[0-9a-f]{64}$') 'Port identity hash missing'
$script:mockPort='WSD-PRIVATE-ID'
$q2=& $script:realQueueFunction
Require ($null -eq $q2.Public.port_uri_known_loopback -and $q2.Public.port_identity_sha256 -ne $q.Public.port_identity_sha256) 'Opaque port identity/unknown loopback mishandled'
$out=Join-Path $PSScriptRoot '../build/windows-cancel-diagnostic'
New-Item -ItemType Directory -Force -Path $out | Out-Null
@{result='PASS';script_sha256=(Get-FileHash (Join-Path $PSScriptRoot 'windows-cancel-diagnostic.ps1') -Algorithm SHA256).Hash;
    assertions=$script:passed; scenarios=$script:cases; powershell=$PSVersionTable.PSVersion.ToString(); utc=[DateTime]::UtcNow.ToString('o');
    real_queue_network_or_usb_access=$false} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $out 'test-results.json') -Encoding UTF8
Write-Host ('PASS: '+$script:passed+' assertions across '+$script:cases.Count+' diagnostic scenarios and status parsing. No real queue/network/USB calls.')
