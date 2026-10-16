# SPDX-License-Identifier: Apache-2.0
param(
  [Parameter(Mandatory=$true)][string]$PapplSource,
  [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath $PapplSource).Path
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if ($outputRoot.StartsWith($sourceRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $outputRoot -eq $sourceRoot) {
  throw 'Generated capture sources must be outside the pinned upstream source tree.'
}

function Read-PinnedSource([string]$Name, [string]$Hash) {
  $path = Join-Path (Join-Path $sourceRoot 'pappl') $Name
  if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Hash) {
    throw "Pinned PAPPL 1.4.10 source hash mismatch: $Name"
  }
  return [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
}
function Replace-Once([string]$Text, [string]$Old, [string]$New) {
  $at = $Text.IndexOf($Old, [StringComparison]::Ordinal)
  if ($at -lt 0 -or $Text.IndexOf($Old, $at + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
    throw "Expected exactly one source anchor: $($Old.Substring(0,[Math]::Min(90,$Old.Length)))"
  }
  return $Text.Substring(0,$at) + $New + $Text.Substring($at+$Old.Length)
}

$ipp = Read-PinnedSource 'job-ipp.c' '81AC11D4CE5AED93D38DDA5E4095EFB012B5416D1F90F6DDB4BD8DA409DB9C6D'
$process = Read-PinnedSource 'job-process.c' 'FE9B9744ECDAE994F52BD3917DBEF96254F431A5F36416D0DD6AA98246DF30C1'
$anchor = '  // If we have a PWG or Apple raster file, process it directly or return'
$guard = @'
  /* SCX capture build: reject non-raster input before the disk spool loop.
   * MIME detection has already occurred in the framework request handler.
   * abort_job uses the existing IPP error, job-state, and request cleanup. */
  if (!job->format || (strcmp(job->format, "image/pwg-raster") && strcmp(job->format, "image/urf")))
  {
    papplClientRespondIPP(client, IPP_STATUS_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED,
                         "Capture endpoint accepts only PWG/Apple raster.");
    goto abort_job;
  }

'@
$ipp = Replace-Once $ipp $anchor ($guard + $anchor)

# Confine adaptations to the streaming raster function, leaving generic
# framework filters and all IPP parsing, cancellation and job management intact.
$startMarker = "void`n_papplJobProcessRaster("
$endMarker = "`n`n//`n// 'papplJobResume()'"
$start = $process.IndexOf($startMarker, [StringComparison]::Ordinal)
$end = $process.IndexOf($endMarker, $start, [StringComparison]::Ordinal)
if ($start -lt 0 -or $end -le $start) { throw 'Cannot identify raster processing function.' }
$body = $process.Substring($start, $end-$start)

$helper = @'
typedef struct { http_t *http; size_t bytes; bool failed; } scx_input_t;
static ssize_t scx_read(void *ctx, unsigned char *buffer, size_t length)
{
  scx_input_t *input = ctx;
  const size_t limit = 32u * 1024u * 1024u;
  if (input->bytes >= limit)
  {
    input->failed = true;
    shutdown(httpGetFd(input->http), SD_RECEIVE);
    return -1;
  }
  if (length > limit - input->bytes) length = limit - input->bytes;
  ssize_t n = httpRead(input->http, (char *)buffer, length);
  if (n > 0) input->bytes += (size_t)n;
  else if (n < 0) input->failed = true;
  return n;
}

/* Restricted SCX capture build. This validates before PAPPL allocations;
 * CUPS decoder allocations inside ReadHeader still need their own guard. */
static bool scx_capture_header_valid(const cups_page_header_t *h)
{
  return h->cupsWidth > 0 && h->cupsWidth <= 3600 &&
         h->cupsHeight > 0 && h->cupsHeight <= 3600 &&
         h->HWResolution[0] == 300 && h->HWResolution[1] == 300 &&
         h->cupsBitsPerColor == 8 && h->cupsBitsPerPixel == 8 &&
         h->cupsNumColors == 1 && h->cupsColorOrder == CUPS_ORDER_CHUNKED &&
         (h->cupsColorSpace == CUPS_CSPACE_SW || h->cupsColorSpace == CUPS_CSPACE_K) &&
         h->cupsBytesPerLine == h->cupsWidth;
}

'@

$firstAnchor = '  if ((job_pages_per_set = ippGetInteger(ippFindAttribute(job->attrs, "job-pages-per-set", IPP_TAG_INTEGER), 0)) > 0)'
$firstGuard = @'
  if (!scx_capture_header_valid(&header))
  {
    papplJobSetReasons(job, PAPPL_JREASON_DOCUMENT_FORMAT_ERROR, PAPPL_JREASON_NONE);
    job->state = IPP_JSTATE_ABORTED;
    goto complete_job;
  }

'@
$body = Replace-Once $body $firstAnchor ($firstGuard + $firstAnchor)
$pageAnchor = '    papplJobSetImpressionsCompleted(job, 1);'
$pageGuard = @'
    if (page >= 10 || !scx_capture_header_valid(&header))
    {
      papplJobSetReasons(job, PAPPL_JREASON_DOCUMENT_FORMAT_ERROR, PAPPL_JREASON_NONE);
      job->state = IPP_JSTATE_ABORTED;
      break;
    }

'@
$body = Replace-Once $body $pageAnchor ($pageGuard + $pageAnchor)

# Replace the general dither/pad/discard loop with a strict one-to-one grayscale
# loop. All accepted input is 8-bit mono and options->header equals its header.
$loopStart = '    if (options->header.cupsBytesPerLine > header.cupsBytesPerLine)'
$loopEnd = "    free(pixels);`n    free(line);"
$a = $body.IndexOf($loopStart, [StringComparison]::Ordinal)
$b = $body.IndexOf($loopEnd, $a, [StringComparison]::Ordinal)
if ($a -lt 0 -or $b -lt $a) { throw 'Cannot identify exact raster allocation/row loop.' }
$oldLoop = $body.Substring($a, $b + $loopEnd.Length - $a)
$strictLoop = @'
    pixels = malloc(header.cupsBytesPerLine);
    if (!pixels)
    {
      job->state = IPP_JSTATE_ABORTED;
      break;
    }

    for (y = 0; !job->is_canceled && y < header.cupsHeight; y ++)
    {
      if (cupsRasterReadPixels(ras, pixels, header.cupsBytesPerLine) != header.cupsBytesPerLine ||
          !(printer->driver_data.rwriteline_cb)(job, options, job->printer->device, y, pixels))
      {
        papplJobSetReasons(job, PAPPL_JREASON_DOCUMENT_FORMAT_ERROR, PAPPL_JREASON_NONE);
        job->state = IPP_JSTATE_ABORTED;
        break;
      }
    }
    free(pixels);
    if (job->is_canceled || job->state == IPP_JSTATE_ABORTED || y != header.cupsHeight)
      break;
'@
$body = Replace-Once $body $oldLoop $strictLoop

# Remove unused general-renderer locals after the strict-loop substitution.
$declStart = "  const unsigned char`t*dither;"
$declEnd = "  int`t`t`tjob_pages_per_set;"
$a = $body.IndexOf($declStart, [StringComparison]::Ordinal)
$b = $body.IndexOf($declEnd, $a, [StringComparison]::Ordinal)
if ($a -lt 0 -or $b -lt $a) { throw 'Cannot identify raster local declarations.' }
$oldDecl = $body.Substring($a,$b-$a)
$body = Replace-Once $body $oldDecl "  unsigned char *pixels;`n  unsigned page = 0, y;`n"
$body = Replace-Once $body '  unsigned char *pixels;' "  scx_input_t input = { client->http, 0, false };`n  unsigned char *pixels;"
$body = Replace-Once $body 'cupsRasterOpenIO((cups_raster_cb_t)httpRead, client->http, CUPS_RASTER_READ)' 'cupsRasterOpenIO(scx_read, &input, CUPS_RASTER_READ)'
$body = Replace-Once $body '  while (cupsRasterReadHeader(ras, &header));' @'
  while (cupsRasterReadHeader(ras, &header));
  if (input.failed || (cupsRasterErrorString() && *cupsRasterErrorString()))
    job->state = IPP_JSTATE_ABORTED;
'@
$body = Replace-Once $body 'while (httpRead(client->http, buffer, sizeof(buffer)) > 0)' 'while (scx_read(&input, (unsigned char *)buffer, sizeof(buffer)) > 0)'
$process = $process.Substring(0,$start) + $helper + $body + $process.Substring($end)

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
[IO.File]::WriteAllText((Join-Path $outputRoot 'job-ipp.c'), $ipp, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $outputRoot 'job-process.c'), $process, [Text.UTF8Encoding]::new($false))
Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $outputRoot 'job-ipp.c'), (Join-Path $outputRoot 'job-process.c')
