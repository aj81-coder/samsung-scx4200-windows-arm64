# SPDX-License-Identifier: Apache-2.0
param([string]$CupsSource,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$path=Join-Path $CupsSource 'cups/raster-stream.c'
if((Get-FileHash $path).Hash -ne '65E82B5409F7F35E2F55CC8151BE6061FBC32C1CC48C92EC61E552CB037B9E93'){throw 'Unexpected CUPS raster source'}
$s=[IO.File]::ReadAllText($path).Replace("`r`n","`n")
$anchor='  if (!cups_raster_update(r))'
if(($s.Split($anchor).Count-1) -ne 2){throw 'Unexpected raster update anchors'}
$guard=@'
  /* SCX capture build: bound decoder allocation before cups_raster_update.
   * Deliberately restricted to the advertised 300dpi 8-bit mono input. */
  if (!r->header.cupsWidth || r->header.cupsWidth > 3600 ||
      !r->header.cupsHeight || r->header.cupsHeight > 3600 ||
      r->header.HWResolution[0] != 300 || r->header.HWResolution[1] != 300 ||
      r->header.cupsBitsPerColor != 8 || r->header.cupsBitsPerPixel != 8 ||
      r->header.cupsColorOrder != CUPS_ORDER_CHUNKED ||
      (r->header.cupsColorSpace != CUPS_CSPACE_SW && r->header.cupsColorSpace != CUPS_CSPACE_K) ||
      r->header.cupsBytesPerLine != r->header.cupsWidth)
  {
    _cupsRasterAddError("Capture raster geometry/layout rejected.\n");
    return 0;
  }

'@
$at=$s.IndexOf($anchor)
$s=$s.Substring(0,$at)+$guard+$s.Substring($at)
# Preserve the distinction between clean EOF and a partial subsequent header.
# The read helper otherwise returns zero for both cases.
foreach($variable in @('remaining','count')){
  $old="`tif ($variable <= 0)`n`t  return (0);"
  $new="`tif ($variable <= 0) {`n`t  if (total > 0) _cupsRasterAddError(`"Truncated raster read.\n`");`n`t  return (0);`n`t}"
  if(($s.Split($old).Count-1) -ne 1){throw "Unexpected $variable read anchor"}
  $s=$s.Replace($old,$new)
}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'raster-stream.c'),$s,[Text.UTF8Encoding]::new($false))
