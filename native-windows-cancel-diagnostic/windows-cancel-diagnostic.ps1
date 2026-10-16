# SPDX-License-Identifier: Apache-2.0
# Windows PowerShell 5.1. The only mutation is one exact Remove-PrintJob.
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'cancel-current-job.ps1'
if (!(Test-Path -LiteralPath $helper)) { $helper = Join-Path $PSScriptRoot '../native-reliable-bridge/cancel-current-job.ps1' }
. $helper
. (Join-Path $PSScriptRoot 'spooler-identity.ps1')

function Get-DiagnosticTime { return [DateTime]::UtcNow }
function Wait-DiagnosticTick { Start-Sleep -Milliseconds 250 }
function Get-DiagnosticQueue {
    try {
        $q = Get-Printer -Name 'SCX-4200 Capture Test' -ErrorAction Stop
        if ($q.Name -ne 'SCX-4200 Capture Test' -or $q.DriverName -ne 'Microsoft IPP Class Driver') { throw 'Wrong queue' }
        $p = Get-PrinterPort -Name $q.PortName -ErrorAction Stop
        $d = Get-PrinterDriver -Name $q.DriverName -ErrorAction Stop
        $portIdentity=@($p.Name,$p.Description,$p.PrinterHostAddress,$p.PortNumber,$p.Protocol) | ConvertTo-Json -Compress
        $hasher=[Security.Cryptography.SHA256]::Create()
        try { $portHash=([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($portIdentity)))).Replace('-','').ToLowerInvariant() }
        finally { $hasher.Dispose() }
        $portUri=$null; $loopback=$null
        if ([Uri]::TryCreate([string]$q.PortName,[UriKind]::Absolute,[ref]$portUri) -and $portUri.Scheme -in 'http','https','ipp','ipps') {
            $loopback=$portUri.Host -in '127.0.0.1','localhost','[::1]','::1'
        }
        # Raw port names/URLs are identity checks in memory only, never report data.
        $identity = @($q.Name, $q.DriverName, $q.PortName, $q.Type, $q.KeepPrintedJobs, $p.Name, $p.Description,
            $p.PrinterHostAddress, $p.PortNumber, $p.Protocol, $d.Name, $d.MajorVersion,
            $d.PrinterEnvironment) | ConvertTo-Json -Compress
        return @{ Key=$identity; Public=@{queue='SCX-4200 Capture Test'; driver='Microsoft IPP Class Driver';
            port_kind='Windows printer port (name/address omitted)'; port_number=$p.PortNumber;
            port_identity_sha256=$portHash; port_uri_known_loopback=$loopback; keep_printed_jobs=$q.KeepPrintedJobs;
            driver_major_version=$d.MajorVersion; driver_environment=[string]$d.PrinterEnvironment} }
    } catch { throw 'Queue identity unavailable or wrong queue/driver' }
}
function Get-DiagnosticSpooler {
    $script:LastSpoolerProbe=Get-ScxSpoolerIdentity
    if (!$script:LastSpoolerProbe.success) { throw 'Spooler identity unavailable or stopped' }
    return [string]$script:LastSpoolerProbe.identity
}
function Get-DiagnosticWindowsJobs {
    try { return @(Get-PrintJob -PrinterName 'SCX-4200 Capture Test' -ErrorAction Stop) }
    catch { throw 'Windows job query failed' }
}
function Get-DiagnosticJobView($job) {
    $submitted = $null
    if ($null -ne $job.SubmittedTime) {
        try { $dt = [DateTime]$job.SubmittedTime; if ($dt -gt [DateTime]'2000-01-01') { $submitted=$dt.ToUniversalTime().Ticks } } catch { }
    }
    $number = $null
    try { $number = [Convert]::ToInt64($job.JobStatus) } catch { }
    $status = [string]$job.JobStatus
    if (($null -ne $number) -and (($number -band (-bnot 32767)) -ne 0)) { throw 'Unknown Windows job status flags' }
    if ($null -eq $number -and $status -notmatch '^(Normal|Paused|Error|Deleting|Spooling|Printing|Offline|PaperOut|Printed|Deleted|Blocked|UserIntervention|Restarted|Complete|Retained|RenderingLocally)(,\s*(Normal|Paused|Error|Deleting|Spooling|Printing|Offline|PaperOut|Printed|Deleted|Blocked|UserIntervention|Restarted|Complete|Retained|RenderingLocally))*$') { throw 'Unknown Windows job status flags' }
    if (($null -ne $number) -and (($number -band 2048) -ne 0)) { throw 'Windows job restarted' }
    if ($status -match '(?i)Restarted') { throw 'Windows job restarted' }
    # CIM JobStatus is a flags enum; textual fallbacks are also checked fail-closed.
    $terminal = (($null -ne $number) -and (($number -band (4 -bor 128 -bor 256 -bor 4096)) -ne 0)) -or
        ($status -match '(?i)(Deleting|Deleted|Printed|Complete)')
    return @{id=[int]$job.ID; submitted_ticks=$submitted; status_numeric=$number; status_text=$status;
        terminal=[bool]$terminal; retained_handoff=($null -ne $number -and $number -eq 12288)}
}
function Test-DiagnosticWindowsCandidate($view,[DateTime]$monitorAt) {
    if ($null -eq $view) { return $false }
    if (!$view.terminal) { return $true }
    # Target evidence: this exact Complete|Retained combination is set after
    # submission, while the corresponding bridge job is still processing.
    # Only a freshly observed job from this empty-baseline run is eligible.
    return $view.retained_handoff -and $null -ne $view.submitted_ticks -and
        $view.submitted_ticks -ge $monitorAt.ToUniversalTime().AddSeconds(-2).Ticks
}
function Get-DiagnosticRemoteJobs {
    $reply=Invoke-Ipp 10
    $jobs=@()
    foreach ($group in $reply.Groups) {
        if ($group.Tag -ne 2) { continue }
        $ids=@($group.Attributes['job-id']); $states=@($group.Attributes['job-state'])
        if ($ids.Count -ne 1 -or $states.Count -ne 1 -or $ids[0] -le 0 -or $states[0] -notin 3,4,5,6,7,8,9) { throw 'Invalid IPP job record' }
        if ($states[0] -in 3,4,5,6) { $jobs+=@{id=[int]$ids[0]; state=[int]$states[0]} }
    }
    return $jobs
}
function Get-DiagnosticRemoteState([int]$jobId) {
    $reply=Invoke-Ipp 9 $jobId
    $jobs=@($reply.Groups | Where-Object {$_.Tag -eq 2})
    if ($jobs.Count -ne 1) { throw 'Invalid selected IPP response' }
    $ids=@($jobs[0].Attributes['job-id']); $states=@($jobs[0].Attributes['job-state'])
    if ($ids.Count -ne 1 -or $ids[0] -ne $jobId -or $states.Count -ne 1 -or $states[0] -notin 3,4,5,6,7,8,9) { throw 'Selected IPP identity changed' }
    return [int]$states[0]
}
function Assert-DiagnosticIdentities($bridge,$queue,$spooler) {
    Assert-SameBridge $bridge
    if ((Get-DiagnosticQueue).Key -ne $queue.Key) { throw 'Queue identity changed' }
    if ((Get-DiagnosticSpooler) -ne $spooler) { throw 'Spooler restarted' }
}
function Assert-DiagnosticSelected($jobs,$selected) {
    if (@($jobs).Count -gt 1) { throw 'Multiple Windows jobs observed' }
    if (@($jobs).Count -eq 0) { return $null }
    $view=Get-DiagnosticJobView $jobs[0]
    if ($view.id -ne $selected.id -or $null -eq $view.submitted_ticks -or $view.submitted_ticks -ne $selected.submitted_ticks) { throw 'Selected Windows job changed or ID reused' }
    return $view
}
function Remove-DiagnosticWindowsJob([int]$jobId) {
    try { Remove-PrintJob -PrinterName 'SCX-4200 Capture Test' -ID $jobId -ErrorAction Stop }
    catch { throw 'Remove-PrintJob failed; no retry made' }
}
function Write-DiagnosticEvent($writer,$record) {
    if ($null -ne $writer) { $writer.WriteLine(($record | ConvertTo-Json -Depth 8 -Compress)); $writer.Flush() }
}
function Invoke-WindowsCancelDiagnostic($writer=$null) {
    $script:LastSpoolerProbe=$null
    $start=Get-DiagnosticTime
    $report=[ordered]@{schema_version=1; started_utc=$start.ToString('o'); finished_utc=$null;
        outcome='Refused'; queue=$null; windows_job_id=$null; ipp_job_id=$null;
        monitor_ready_utc=$null; monitor_wait_limit_seconds=600;
        remove_attempts=0; remove_requested_utc=$null; remove_returned_utc=$null;
        before_remove=$null; after_remove=@(); last_windows_job=$null; last_ipp_state=$null;
        remote_cancelled_observed=$false; retained_handoff_used=$false; spooler_probe=$null; error=$null}
    try {
        $bridge=Get-BridgeIdentity; if ($null -eq $bridge) { throw 'No bridge running in this folder' }
        $queue=Get-DiagnosticQueue; $report.queue=$queue.Public; $spooler=Get-DiagnosticSpooler
        if (@(Get-DiagnosticWindowsJobs).Count -ne 0) { throw 'Windows queue is not empty at baseline' }
        if (@(Get-DiagnosticRemoteJobs).Count -ne 0) { throw 'Bridge queue is not empty at baseline' }
        Assert-DiagnosticIdentities $bridge $queue $spooler
        Write-DiagnosticEvent $writer @{utc=(Get-DiagnosticTime).ToString('o'); event='EmptyBaseline'; queue=$queue.Public}
        $monitorAt=Get-DiagnosticTime; $report.monitor_ready_utc=$monitorAt.ToString('o')
        Write-Host 'Monitor ready. Keep the paper tray EMPTY. Print TWO-PAGE-SAMPLE.pdf ONCE now.'
        Write-Host 'Waiting up to 10 minutes for the job. Do not print after the final Result message.'
        Write-Host 'This diagnostic will cancel that one Windows job automatically. Do not click Cancel yourself.'
        $selected=$null; $remoteId=$null; $remoteState=$null; $processingAt=$null
        $nextRemote=$start; $nextIdentity=$start; $lastLocal=''; $lastRemote=''; $removeAt=$null
        $nextReminder=$monitorAt.AddSeconds(60)
        while ($true) {
            $now=Get-DiagnosticTime
            if (($now-$monitorAt).TotalSeconds -ge 660) { $report.outcome='TimedOutNoRetry'; break }
            if ($null -eq $selected -and $null -eq $remoteId -and $now -ge $nextReminder) {
                Write-Host 'Monitor is still waiting. If you already clicked Print, do not click it again.'
                Write-DiagnosticEvent $writer @{utc=$now.ToString('o');event='WaitingForJob';elapsed_seconds=[int]($now-$monitorAt).TotalSeconds}
                $nextReminder=$now.AddSeconds(60)
            }
            if ($now -ge $nextIdentity) { Assert-DiagnosticIdentities $bridge $queue $spooler; $nextIdentity=$now.AddSeconds(1) }
            $local=@(Get-DiagnosticWindowsJobs)
            if ($local.Count -gt 1) { throw 'Multiple Windows jobs observed' }
            $view=$null
            if ($null -eq $selected -and $local.Count -eq 1) {
                $selected=Get-DiagnosticJobView $local[0]
                if ($null -eq $selected.submitted_ticks -or $selected.id -le 0) { throw 'Windows job has no usable ID/submission fingerprint' }
                $report.windows_job_id=$selected.id
            }
            if ($null -ne $selected) { $view=Assert-DiagnosticSelected $local $selected }
            $report.last_windows_job=$view
            $localKey=if ($null -eq $view) {'absent'} else {$view | ConvertTo-Json -Compress}
            if ($localKey -ne $lastLocal) {
                $event=@{utc=$now.ToString('o'); event='WindowsJob'; job=$view}
                Write-DiagnosticEvent $writer $event
                if ($null -ne $removeAt) { $report.after_remove+=@($event) }; $lastLocal=$localKey
            }
            if ($now -ge $nextRemote) {
                $active=@(Get-DiagnosticRemoteJobs)
                if ($active.Count -gt 1) { throw 'Multiple active bridge jobs observed' }
                if ($null -eq $remoteId -and $active.Count -eq 1) { $remoteId=$active[0].id; $report.ipp_job_id=$remoteId }
                if ($null -ne $remoteId) {
                    if ($active.Count -eq 1 -and $active[0].id -ne $remoteId) { throw 'Selected bridge job changed' }
                    $remoteState=Get-DiagnosticRemoteState $remoteId
                    $report.last_ipp_state=$remoteState
                    if ($remoteState -eq 7) { $report.remote_cancelled_observed=$true }
                    if ([string]$remoteState -ne $lastRemote) {
                        $event=@{utc=$now.ToString('o'); event='BridgeJob'; id=$remoteId; state=$remoteState}
                        Write-DiagnosticEvent $writer $event
                        if ($null -ne $removeAt) { $report.after_remove+=@($event) }; $lastRemote=[string]$remoteState
                    }
                    if ($remoteState -eq 5 -and $null -eq $processingAt) { $processingAt=$now }
                }
                $nextRemote=$now.AddSeconds(1)
            }
            if ($null -eq $removeAt) {
                if ($null -ne $selected -and !(Test-DiagnosticWindowsCandidate $view $monitorAt)) {
                    $report.outcome='NoActiveWindowsJob'; break
                }
                if ($null -ne $remoteState -and $remoteState -in 7,8,9) { $report.outcome='BridgeJobEndedBeforeCancel'; break }
                if ($null -ne $view -and $remoteState -eq 5 -and ($now-$processingAt).TotalSeconds -ge 10) {
                    # Requery every identity and both queues immediately before the sole mutation.
                    Assert-DiagnosticIdentities $bridge $queue $spooler
                    $view=Assert-DiagnosticSelected @(Get-DiagnosticWindowsJobs) $selected
                    if (!(Test-DiagnosticWindowsCandidate $view $monitorAt)) { $report.outcome='NoActiveWindowsJob'; break }
                    $active=@(Get-DiagnosticRemoteJobs)
                    if ($active.Count -ne 1 -or $active[0].id -ne $remoteId -or $active[0].state -ne 5) { throw 'Bridge processing job changed before Windows cancellation' }
                    Assert-DiagnosticIdentities $bridge $queue $spooler
                    $view=Assert-DiagnosticSelected @(Get-DiagnosticWindowsJobs) $selected
                    if (!(Test-DiagnosticWindowsCandidate $view $monitorAt)) { $report.outcome='NoActiveWindowsJob'; break }
                    $report.retained_handoff_used=[bool]$view.retained_handoff
                    $report.before_remove=@{utc=(Get-DiagnosticTime).ToString('o'); windows=$view; ipp_id=$remoteId; ipp_state=5}
                    Write-DiagnosticEvent $writer @{event='BeforeRemovePrintJob'; detail=$report.before_remove}
                    $report.remove_requested_utc=(Get-DiagnosticTime).ToString('o'); $report.remove_attempts=1
                    Remove-DiagnosticWindowsJob $selected.id
                    $report.remove_returned_utc=(Get-DiagnosticTime).ToString('o'); $removeAt=Get-DiagnosticTime
                    Write-DiagnosticEvent $writer @{utc=$report.remove_returned_utc; event='RemovePrintJobReturned'; windows_id=$selected.id}
                    Write-Host 'Windows cancellation requested once for the recorded job ID. Observing for 20 seconds...'
                }
                if (($now-$monitorAt).TotalSeconds -ge 600 -and $null -eq $removeAt -and $null -eq $selected -and $null -eq $remoteId) { $report.outcome='TimedOutBeforeCancel'; break }
            } elseif (($now-$removeAt).TotalSeconds -ge 20) {
                $report.outcome=if ($report.remote_cancelled_observed) {'WindowsCancelRemoteState7Observed'} else {'WindowsCancelIssuedRemoteCancelNotObserved'}
                break
            }
            Wait-DiagnosticTick
        }
    } catch {
        # Only controlled messages enter the report; exceptions can contain private paths.
        $safe=@('No bridge running in this folder','Queue identity unavailable or wrong queue/driver','Spooler identity unavailable or stopped',
            'Windows job query failed','Windows queue is not empty at baseline','Bridge queue is not empty at baseline',
            'Queue identity changed','Spooler restarted','Multiple Windows jobs observed','Selected Windows job changed or ID reused',
            'Windows job has no usable ID/submission fingerprint','Multiple active bridge jobs observed','Selected bridge job changed',
            'Bridge processing job changed before Windows cancellation','Remove-PrintJob failed; no retry made','Invalid IPP job record',
            'Invalid selected IPP response','Selected IPP identity changed','Bridge changed before cancellation',
            'Unknown Windows job status flags','Windows job restarted')
        $report.error=if ($_.Exception.Message -in $safe) {$_.Exception.Message} else {'Diagnostic query/control failed ('+$_.Exception.GetType().Name+')'}
        $report.outcome=if ($report.remove_attempts -gt 0) {'ObservationOrRemoveFailedNoRetry'} else {'Refused'}
    }
    $report.spooler_probe=$script:LastSpoolerProbe
    $report.finished_utc=(Get-DiagnosticTime).ToString('o')
    Write-DiagnosticEvent $writer @{event='Finished'; report=$report}
    Write-Host ('Result: '+$report.outcome)
    if ($report.error) { Write-Host $report.error }
    if ($report.spooler_probe -and !$report.spooler_probe.success) {
        Write-Host ('Spooler check stage: '+$report.spooler_probe.stage+'; Windows error: '+$report.spooler_probe.win32_error)
    }
    Write-Host 'Keep the tray empty. Stop the bridge with Ctrl+C, then collect results. Do not refill or retry.'
    return $report
}
if ($MyInvocation.InvocationName -ne '.') {
    $stem=Join-Path $PSScriptRoot ('control-windows-cancel-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+$PID)
    $trace=New-Object IO.StreamWriter(($stem+'.jsonl'),$false,(New-Object Text.UTF8Encoding($false)))
    $trace.AutoFlush=$true
    try { $result=Invoke-WindowsCancelDiagnostic $trace } finally { $trace.Dispose() }
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath ($stem+'.json') -Encoding UTF8
    Write-Host ('Report: '+[IO.Path]::GetFileName($stem+'.json'))
    if ($result.outcome -in 'Refused','ObservationOrRemoveFailedNoRetry') { exit 1 }
}
