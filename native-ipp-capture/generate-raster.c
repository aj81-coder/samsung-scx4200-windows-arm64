/* Deterministic integration fixture, SPDX-License-Identifier: Apache-2.0. */
#include <cups/cups.h>
#include <cups/raster.h>
#include <cups/pwg.h>
#include <stdio.h>
#include <stdlib.h>

static ssize_t write_bytes(void *context, unsigned char *buffer, size_t length)
{
  size_t n = fwrite(buffer, 1, length, (FILE *)context);
  return n == length ? (ssize_t)n : -1;
}

int main(int argc, char **argv)
{
  cups_page_header2_t header;
  cups_raster_t *raster;
  FILE *file;
  unsigned char row[3600];
  int good = 1;
  if (argc != 2) { fputs("Usage: generate-raster.exe NEW-FIXTURE.pwg\n", stderr); return 64; }
  if (!cupsRasterInitPWGHeader(&header, pwgMediaForPWG("iso_a4_210x297mm"),
                               "sgray_8", 300, 300, "one-sided", NULL)) return 1;
  if (!header.cupsWidth || header.cupsWidth > sizeof(row) || header.cupsBytesPerLine != header.cupsWidth) return 1;
  header.cupsInteger[CUPS_RASTER_PWG_TotalPageCount] = 1;
  header.NumCopies = 1;
  if (!(file = fopen(argv[1], "wbx"))) { perror("create fixture"); return 1; }
  if (!(raster = cupsRasterOpenIO(write_bytes, file, CUPS_RASTER_WRITE_PWG))) { fclose(file); return 1; }
  if (!cupsRasterWriteHeader2(raster, &header)) good = 0;
  for (unsigned y = 0; good && y < header.cupsHeight; y++) {
    for (unsigned x = 0; x < header.cupsWidth; x++) row[x] = (unsigned char)(((x / 31 + y / 29) * 37) & 255);
    if (cupsRasterWritePixels(raster, row, header.cupsBytesPerLine) != header.cupsBytesPerLine) good = 0;
  }
  cupsRasterClose(raster);
  if (fclose(file)) good = 0;
  if (!good) { fputs("Fixture generation failed; do not use partial output.\n", stderr); return 1; }
  printf("{\"width\":%u,\"height\":%u,\"resolution\":[300,300],\"pattern\":\"((x/31+y/29)*37)&255\"}\n", header.cupsWidth, header.cupsHeight);
  return 0;
}
