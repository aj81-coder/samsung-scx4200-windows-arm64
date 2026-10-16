# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'cancel-current-job.ps1')
$script:passed=0
function Require($ok,$message){if(!$ok){throw $message};$script:passed++}
function Response($groups){$s=New-Object IO.MemoryStream;$s.WriteByte(2);$s.WriteByte(0);Write-U16 $s 0;Write-U32 $s 42;foreach($g in $groups){$s.WriteByte(2);Write-Attribute $s 0x21 'job-id' ([int]$g[0]);Write-Attribute $s 0x23 'job-state' ([int]$g[1])};$s.WriteByte(3);return ,$s.ToArray()}
$b=Response @(@(11,3),@(22,5));$r=Read-IppResponse $b 42
Require ($r.Groups.Count-eq 2-and$r.Groups[0].Attributes['job-id'][0]-eq 11-and$r.Groups[1].Attributes['job-state'][0]-eq 5) 'Job groups collapsed'
foreach($bad in @($b[0..($b.Length-2)],($b+@(0)),[byte[]]@(2,0,0,0,0,0,0,42,0x21,0,0,0,0,3))){$rejected=$false;try{$null=Read-IppResponse $bad 42}catch{$rejected=$true};Require $rejected 'Malformed IPP accepted'}
$rejected=$false;try{$null=Read-IppResponse $b 43}catch{$rejected=$true};Require $rejected 'Wrong ID accepted'
function Get-BridgeIdentity {if($script:noProcess){return $null};return @{Id=99;Start=123;Path='mock'}}
function Assert-SameBridge($identity){if($script:changed){throw 'Changed bridge'}}
function Invoke-Ipp([int]$operation,[int]$jobId=0){if($operation-eq 8){$script:calls+= $jobId;return @{Status=0;Groups=@()}};return $script:response}
$script:calls=@();$script:response=$r
$result=Invoke-CurrentJobCancellation;Require ($result.outcome-eq 'CancelAccepted'-and$script:calls.Count-eq 1-and$script:calls[0]-eq 22) 'Wrong job cancelled'
$script:calls=@();$script:response=Read-IppResponse (Response @(@(11,5),@(22,5))) 42
$result=Invoke-CurrentJobCancellation;Require ($result.outcome-eq 'Failed'-and$script:calls.Count-eq 0) 'Multiple processing jobs accepted'
$script:response=Read-IppResponse (Response (, @(11,3))) 42
$result=Invoke-CurrentJobCancellation;Require ($result.outcome-eq 'NoProcessingJob'-and$script:calls.Count-eq 0) 'Pending job cancelled'
$script:noProcess=$true;$result=Invoke-CurrentJobCancellation;Require ($result.outcome-eq 'NoBridgeProcess'-and$script:calls.Count-eq 0) 'No process cancelled';$script:noProcess=$false
$script:response=$r;$script:changed=$true;$result=Invoke-CurrentJobCancellation;Require ($result.outcome-eq 'Failed'-and$script:calls.Count-eq 0) 'Changed bridge cancelled'
$script:changed=$false;$script:response=@{Groups=@(@{Tag=2;Attributes=@{'job-id'=@(2,3);'job-state'=@(5)}})};$result=Invoke-CurrentJobCancellation;Require ($result.outcome-eq 'Failed'-and$script:calls.Count-eq 0) 'Duplicate job IDs accepted'
Write-Host ('PASS: '+$script:passed+' parser and control checks; no network or USB used.')

