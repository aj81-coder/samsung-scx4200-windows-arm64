# SPDX-License-Identifier: Apache-2.0
param([Parameter(Mandatory=$true)][string]$CupsSource,[Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$source=Join-Path (Join-Path $CupsSource 'cups') 'http.c'
if((Get-FileHash -LiteralPath $source).Hash -ne 'CFDD510255869975BB490CBD7A12BCFB9B2E310C1B14F600CA118AC72A7482ED'){throw 'Pinned CUPS 2.4.11 HTTP source mismatch'}
$sourceRoot=[IO.Path]::GetFullPath($CupsSource).TrimEnd('\','/')
$outputRoot=[IO.Path]::GetFullPath($OutputDirectory)
if($outputRoot -eq $sourceRoot -or $outputRoot.StartsWith($sourceRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Generated HTTP source must be outside upstream tree'}
$text=[IO.File]::ReadAllText($source).Replace("`r`n","`n")
$old=@'
    if (http->coding >= _HTTP_CODING_GUNZIP)
      http_content_coding_finish(http);
#endif /* HAVE_LIBZ */

    if (http->state == HTTP_STATE_POST_RECV)
'@
$new=@'
    if (http->coding >= _HTTP_CODING_GUNZIP)
    {
      /* SCX asynchronous spool guard: HTTP content-length/chunk EOF does not
       * prove gzip/deflate completion. Require the inflater's terminal state,
       * which includes gzip trailer length and CRC verification. No additional
       * output may be silently discarded by content_coding_finish. */
      z_stream *stream = (z_stream *)http->stream;
      Bytef scratch;
      Bytef *saved_next = stream->next_out;
      uInt saved_avail = stream->avail_out;
      int result;
      stream->next_out = &scratch;
      stream->avail_out = 1;
      result = inflate(stream, Z_FINISH);
      if (result != Z_STREAM_END || stream->avail_out != 1)
      {
        stream->next_out = saved_next;
        stream->avail_out = saved_avail;
        http->error = EIO;
        return (-1);
      }
      stream->next_out = saved_next;
      stream->avail_out = saved_avail;
      http_content_coding_finish(http);
    }
#endif /* HAVE_LIBZ */

    if (http->state == HTTP_STATE_POST_RECV)
'@
$at=$text.IndexOf($old,[StringComparison]::Ordinal)
if($at -lt 0 -or $text.IndexOf($old,$at+$old.Length,[StringComparison]::Ordinal) -ge 0){throw 'Ambiguous HTTP EOF source anchor'}
$text=$text.Substring(0,$at)+$new+$text.Substring($at+$old.Length)
New-Item -ItemType Directory -Force $outputRoot | Out-Null
[IO.File]::WriteAllText((Join-Path $outputRoot 'http.c'),$text,[Text.UTF8Encoding]::new($false))
