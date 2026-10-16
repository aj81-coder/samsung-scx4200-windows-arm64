# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
function Write-U16($s,[int]$n){$s.WriteByte([byte](($n -shr 8)-band 255));$s.WriteByte([byte]($n-band 255))}
function Write-U32($s,[int]$n){foreach($shift in 24,16,8,0){$s.WriteByte([byte](($n -shr $shift)-band 255))}}
function Write-Attribute($s,[byte]$tag,[string]$name,$value){
 $s.WriteByte($tag);$b=[Text.Encoding]::UTF8.GetBytes($name);Write-U16 $s $b.Length;$s.Write($b,0,$b.Length)
 if($value -is [int]){$v=New-Object IO.MemoryStream;Write-U32 $v $value;$b=$v.ToArray();$v.Dispose()}else{$b=[Text.Encoding]::UTF8.GetBytes([string]$value)}
 Write-U16 $s $b.Length;$s.Write($b,0,$b.Length)
}
function Read-U16([byte[]]$b,[ref]$p){if($p.Value+2-gt$b.Length){throw 'Truncated IPP length'};$n=([int]$b[$p.Value]*256)+$b[$p.Value+1];$p.Value+=2;return $n}
function Read-U32([byte[]]$b,[ref]$p){if($p.Value+4-gt$b.Length){throw 'Truncated IPP integer'};[long]$n=0;for($k=0;$k-lt 4;$k++){$n=$n*256+$b[$p.Value];$p.Value++};return $n}
function Read-IppResponse([byte[]]$b,[int]$requestId){
 if($b.Length-lt 9-or$b.Length-gt 65536){throw 'Invalid IPP response size'}
 if($b[0]-notin 1,2){throw 'Unsupported IPP version'}
 $p=2;$status=Read-U16 $b ([ref]$p);$id=Read-U32 $b ([ref]$p);if($id-ne$requestId){throw 'IPP request ID mismatch'}
 $groups=New-Object Collections.ArrayList;$group=$null;$name=$null;$ended=$false
 while($p-lt$b.Length){
  $tag=[int]$b[$p];$p++
  if($tag-eq 3){$ended=$true;break}
  if($tag-lt 16){if($tag-notin 1,2,4,5,6,7,9){throw 'Invalid IPP group'};$group=@{Tag=$tag;Attributes=@{}};[void]$groups.Add($group);$name=$null;continue}
  if($null-eq$group){throw 'Attribute outside group'}
  $n=Read-U16 $b ([ref]$p);if($p+$n-gt$b.Length){throw 'Truncated attribute name'}
  if($n){$name=[Text.Encoding]::UTF8.GetString($b,$p,$n)}elseif($null-eq$name){throw 'Orphan attribute continuation'};$p+=$n
  $n=Read-U16 $b ([ref]$p);if($p+$n-gt$b.Length){throw 'Truncated attribute value'}
  if($name-in 'job-id','job-state'){
   $expected=if($name-eq'job-id'){0x21}else{0x23}
   if($tag-ne$expected-or$n-ne 4){throw 'Invalid job integer encoding'}
   $q=$p;$value=Read-U32 $b ([ref]$q)
   if($value-gt 2147483647){throw 'Invalid job integer'}
   if(!$group.Attributes.ContainsKey($name)){$group.Attributes[$name]=@()};$group.Attributes[$name]=@($group.Attributes[$name])+@([int]$value)
  }
  $p+=$n
 }
 if(!$ended-or$p-ne$b.Length){throw 'Missing IPP end or unexpected payload'}
 return @{Status=$status;Groups=@($groups.ToArray())}
}
function Invoke-Ipp([int]$operation,[int]$jobId=0){
 $rid=Get-Random -Minimum 1 -Maximum 2147483647;$s=New-Object IO.MemoryStream
 try{
 $s.WriteByte(2);$s.WriteByte(0);Write-U16 $s $operation;Write-U32 $s $rid;$s.WriteByte(1)
 Write-Attribute $s 0x47 'attributes-charset' 'utf-8';Write-Attribute $s 0x48 'attributes-natural-language' 'en'
 Write-Attribute $s 0x45 'printer-uri' 'ipp://127.0.0.1:8631/ipp/print'
 Write-Attribute $s 0x42 'requesting-user-name' ([Environment]::UserName)
 if($operation-eq 10){Write-Attribute $s 0x44 'which-jobs' 'not-completed';Write-Attribute $s 0x44 'requested-attributes' 'job-id';Write-Attribute $s 0x44 '' 'job-state'}else{Write-Attribute $s 0x21 'job-id' $jobId}
 $s.WriteByte(3);$body=$s.ToArray()
 }finally{$s.Dispose()}
 $req=[Net.HttpWebRequest]::Create('http://127.0.0.1:8631/ipp/print');$req.Proxy=$null;$req.AllowAutoRedirect=$false;$req.Method='POST';$req.ContentType='application/ipp';$req.Timeout=5000;$req.ReadWriteTimeout=5000;$req.ContentLength=$body.Length
 try{
  $stream=$req.GetRequestStream();try{$stream.Write($body,0,$body.Length)}finally{$stream.Dispose()}
  $response=$req.GetResponse();try{
   if([int]$response.StatusCode-ne 200){throw 'Unexpected HTTP status'}
   $input=$response.GetResponseStream();$out=New-Object IO.MemoryStream
   try{$buf=New-Object byte[] 4096;while(($n=$input.Read($buf,0,$buf.Length))-gt 0){if($out.Length+$n-gt 65536){throw 'IPP response too large'};$out.Write($buf,0,$n)};$bytes=$out.ToArray()}finally{$input.Dispose();$out.Dispose()}
  }finally{$response.Dispose()}
 }finally{$req.Abort()}
 $parsed=Read-IppResponse $bytes $rid;if($parsed.Status-ge 0x400){throw ('IPP operation rejected: 0x{0:X4}'-f$parsed.Status)};return $parsed
}
function Get-BridgeIdentity {
 $expected=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'SCX4200-Reliable-Bridge.exe'))
 $matches=@(Get-Process -Name 'SCX4200-Reliable-Bridge' -ErrorAction SilentlyContinue | Where-Object {[string]::Equals($_.Path,$expected,[StringComparison]::OrdinalIgnoreCase)})
 if($matches.Count-eq 0){return $null};if($matches.Count-ne 1){throw 'Multiple bridge processes in this folder'}
 $proc=$matches[0];$listeners=@(Get-NetTCPConnection -State Listen -LocalPort 8631 -ErrorAction Stop)
 if($listeners.Count-ne 1-or$listeners[0].LocalAddress-ne '127.0.0.1'-or$listeners[0].OwningProcess-ne$proc.Id){throw 'Loopback listener does not belong exclusively to this bridge'}
 return @{Id=$proc.Id;Start=$proc.StartTime.ToUniversalTime().Ticks;Path=$expected}
}
function Assert-SameBridge($identity){$now=Get-BridgeIdentity;if($null-eq$now-or$now.Id-ne$identity.Id-or$now.Start-ne$identity.Start-or![string]::Equals($now.Path,$identity.Path,[StringComparison]::OrdinalIgnoreCase)){throw 'Bridge changed before cancellation'}}
function Invoke-CurrentJobCancellation {
 $report=[ordered]@{schema_version=1;utc=[DateTime]::UtcNow.ToString('o');outcome='Failed';candidate_jobs=@();cancelled_job_id=$null;error=$null}
 try{
  $identity=Get-BridgeIdentity
  if($null-eq$identity){$report.outcome='NoBridgeProcess';Write-Host 'No running bridge in this folder. No cancellation sent.';return $report}
  $response=Invoke-Ipp 10;$processing=@()
  foreach($group in $response.Groups){if($group.Tag-ne 2){continue};$ids=@($group.Attributes['job-id']);$states=@($group.Attributes['job-state']);if($ids.Count-ne 1-or$states.Count-ne 1-or$ids[0]-le 0-or$states[0]-notin 3,4,5,6,7,8,9){throw 'Ambiguous or invalid job record'}
   $report.candidate_jobs+=@{id=$ids[0];state=$states[0]};if($states[0]-eq 5){$processing+= $ids[0]}
  }
  if($processing.Count-eq 0){$report.outcome='NoProcessingJob';Write-Host 'No processing job. No cancellation sent.';return $report}
  if($processing.Count-ne 1){throw 'Multiple processing jobs; refusing cancellation'}
  Assert-SameBridge $identity
  $null=Invoke-Ipp 8 $processing[0];$report.cancelled_job_id=$processing[0];$report.outcome='CancelAccepted'
  Write-Host 'The bridge accepted cancellation. Printer-buffered data may remain; this does not reset the printer.'
 }catch{$report.error=$_.Exception.Message;Write-Host ('Cancellation failed: '+$report.error)}
 return $report
}
if($MyInvocation.InvocationName-ne '.'){
 $result=Invoke-CurrentJobCancellation
 $file=Join-Path $PSScriptRoot ('control-cancel-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+$PID+'.json')
 $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding UTF8
 Write-Host ('Report: '+[IO.Path]::GetFileName($file))
 if($result.outcome-eq 'Failed'){exit 1}
}

