# SPDX-License-Identifier: Apache-2.0
param([Parameter(Mandatory=$true)][string]$PapplSource,[Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
# Keep the already audited streaming implementation as an unreachable fallback.
& (Join-Path $root 'native-ipp-capture/prepare-capture-guards.ps1') -PapplSource $PapplSource -OutputDirectory $OutputDirectory | Out-Null
function Replace-Once([string]$Text,[string]$Old,[string]$New) {
  $at=$Text.IndexOf($Old,[StringComparison]::Ordinal)
  if($at -lt 0 -or $Text.IndexOf($Old,$at+$Old.Length,[StringComparison]::Ordinal) -ge 0){throw "Ambiguous PAPPL anchor: $Old"}
  $Text.Substring(0,$at)+$New+$Text.Substring($at+$Old.Length)
}
$ippPath=Join-Path $OutputDirectory 'job-ipp.c'
$ipp=[IO.File]::ReadAllText($ippPath).Replace("`r`n","`n")
$start=$ipp.IndexOf('  /* SCX capture build:')
$end=$ipp.IndexOf('  // Create a file for the request data...',$start)
if($start -lt 0 -or $end -lt $start){throw 'Missing receive-path anchors'}
$guard=@'
  /* SCX asynchronous path: only fully received, committed PWG files can be
   * submitted. httpRead returns decompressed bytes, including gzip bodies. */
  if (!job->format || strcmp(job->format, "image/pwg-raster"))
  {
    papplClientRespondIPP(client, IPP_STATUS_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED, "Only PWG raster is accepted.");
    goto abort_job;
  }

'@
$ipp=$ipp.Substring(0,$start)+$guard+$ipp.Substring($end)
$ipp=Replace-Once $ipp '  while ((bytes = httpRead(client->http, buffer, sizeof(buffer))) > 0)' "  /* Bound stalled/incomplete local uploads, including cancellation mid-read. */`n  httpSetTimeout(client->http, 5.0, NULL, NULL);`n  while ((bytes = httpRead(client->http, buffer, sizeof(buffer))) > 0)"
$ipp=Replace-Once $ipp '    if (write(job->fd, buffer, (size_t)bytes) < bytes)' @'
    if (papplJobIsCanceled(job) || total > (32 * 1024 * 1024) - bytes)
    {
      close(job->fd);
      job->fd = -1;
      unlink(filename);
      papplClientRespondIPP(client, IPP_STATUS_ERROR_DOCUMENT_FORMAT_ERROR, "Canceled or document exceeds 32 MiB decompressed limit.");
      goto abort_job;
    }
    if (write(job->fd, buffer, (size_t)bytes) < bytes)
'@
$ipp=Replace-Once $ipp '  if (bytes < 0)' '  if (bytes < 0 || total == 0 || papplJobIsCanceled(job) || httpGetState(client->http) == HTTP_STATE_POST_RECV)'
$ipp=Replace-Once $ipp '  if (close(job->fd))' @'
  /* File durability is required before an acceptance response or worker. */
  if (_commit(job->fd))
  {
    close(job->fd);
    job->fd = -1;
    unlink(filename);
    papplClientRespondIPP(client, IPP_STATUS_ERROR_INTERNAL, "Unable to commit document.");
    goto abort_job;
  }
  if (close(job->fd))
'@
$ipp=Replace-Once $ipp "  // Submit the job for processing...`n  _papplJobSubmitFile(job, filename);`n`n  complete_job:" @'
  /* Advertise pending, but leave the file unattached to the scheduler until
   * the complete Send-Document response has actually been flushed. */
  _papplRWLockWrite(job);
  if (!job->is_canceled && job->state < IPP_JSTATE_CANCELED)
    job->state = IPP_JSTATE_PENDING;
  _papplRWUnlock(job);
'@
$ipp=Replace-Once $ipp "  cupsArrayDelete(ra);`n  return;" @'
  cupsArrayDelete(ra);
  if (!papplClientRespond(client, HTTP_STATUS_OK, NULL, "application/ipp", 0, ippGetLength(client->response)) || httpFlushWrite(client->http) < 0)
  {
    unlink(filename);
    shutdown(httpGetFd(client->http), SD_BOTH);
    goto abort_job;
  }
  papplLogJob(job, PAPPL_LOGLEVEL_INFO, "SCX document acceptance response flushed before worker submission.");
  _papplJobSubmitFile(job, filename);
  return;
'@
# Never drain arbitrary rejected data, including a compressed expansion bomb.
$ipp=Replace-Once $ipp "  papplLogJob(job, PAPPL_LOGLEVEL_INFO, `"Aborting job.`");`n`n  _papplClientFlushDocumentData(client);" "  papplLogJob(job, PAPPL_LOGLEVEL_INFO, `"Aborting job.`");`n`n  shutdown(httpGetFd(client->http), SD_RECEIVE);"
$ipp=Replace-Once $ipp '  job->state     = IPP_JSTATE_ABORTED;' '  job->state     = (job->is_canceled || job->state == IPP_JSTATE_CANCELED) ? IPP_JSTATE_CANCELED : IPP_JSTATE_ABORTED;'
$ipp=Replace-Once $ipp '  cupsArrayAdd(client->printer->completed_jobs, job);' "  if (!cupsArrayFind(client->printer->completed_jobs, job))`n    cupsArrayAdd(client->printer->completed_jobs, job);"
$jobPath=Join-Path (Join-Path $PapplSource 'pappl') 'job.c'
if((Get-FileHash -LiteralPath $jobPath).Hash -ne '2702E0AC48EBCCFD5E937CA657C58850AE80768E38BAD2813620A5419029A791'){throw 'Pinned job.c source mismatch'}
$job=[IO.File]::ReadAllText($jobPath).Replace("`r`n","`n")
$marker="_papplJobSubmitFile(`n"
$at=$job.IndexOf($marker)
$head=$job.Substring(0,$at)
$body=$job.Substring($at)
$body=Replace-Once $body '  // Save the print file information...' @'
  /* Cancellation may arrive after the acceptance response and before this
   * lock. Do not resurrect that canceled job or launch a worker for it. */
  if (job->is_canceled || job->state >= IPP_JSTATE_CANCELED)
  {
    bool finish_cancel = job->is_canceled && job->state < IPP_JSTATE_CANCELED;
    _papplRWUnlock(job);
    if (finish_cancel)
      papplJobCancel(job);
    unlink(filename);
    return;
  }

  // Save the print file information...
'@
$job=$head+$body
$job=Replace-Once $job '    if (job->state == IPP_JSTATE_PENDING)' '    if (job->state == IPP_JSTATE_PENDING && job->filename != NULL)'
$utf8=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($ippPath,$ipp,$utf8)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'job.c'),$job,$utf8)
Get-FileHash -LiteralPath $ippPath,(Join-Path $OutputDirectory 'job.c'),(Join-Path $OutputDirectory 'job-process.c')
