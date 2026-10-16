/* SCX-4200 decoded raster capture prototype. SPDX-License-Identifier: Apache-2.0
 * Uses PAPPL for HTTP/IPP and raster decoding; never opens a USB device.
 * See CAPTURE-NOTES.md for framework limits still requiring validation.
 */
#include <pappl/pappl.h>
#include <windows.h>
#include <bcrypt.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#define CAPTURE_VERSION "0.3.1-dev"
#define MAX_PAGES 10u
#define MAX_WIDTH 3600u
#define MAX_HEIGHT 3600u
#define MAX_RUN_BYTES (128ull * 1024ull * 1024ull)
#if CUPS_VERSION_MAJOR == 2
typedef cups_page_header2_t capture_header_t;
#else
typedef cups_page_header_t capture_header_t;
#endif
#if defined(__aarch64__) || defined(_M_ARM64)
#define CAPTURE_ARCH "ARM64"
#else
#define CAPTURE_ARCH "x64"
#endif

/* One printer processes one raster job at a time. Persistent counters bound
 * all decoded output, including partial/failed jobs, over the whole run. */
static struct {
  char directory[1024];
  FILE *page;
  BCRYPT_ALG_HANDLE algorithm;
  BCRYPT_HASH_HANDLE hash;
  unsigned pages, rows;
  unsigned long long total_bytes, page_bytes;
  bool failed;
} capture;

static void close_page(void)
{
  if (capture.page) { fclose(capture.page); capture.page = NULL; }
  if (capture.hash) { BCryptDestroyHash(capture.hash); capture.hash = NULL; }
  if (capture.algorithm) { BCryptCloseAlgorithmProvider(capture.algorithm, 0); capture.algorithm = NULL; }
}

static bool failure(pappl_job_t *job, const char *message)
{
  capture.failed = true;
  fprintf(stderr, "Capture failed: %s. Please collect the results.\n", message);
  papplJobSetMessage(job, "Capture failed: %s; no physical printing", message);
  papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Capture failed: %s", message);
  return false;
}

static bool device_open(pappl_device_t *device, const char *uri, const char *name)
{
  (void)device; (void)name;
  return !strcmp(uri, "scxcapture://local");
}

static void device_close(pappl_device_t *device)
{
  (void)device;
  close_page();
}

static ssize_t device_write(pappl_device_t *device, const void *data, size_t size)
{
  (void)device; (void)data; (void)size;
  errno = ENOTSUP;
  return -1; /* No physical transport exists in this application. */
}

static bool start_job(pappl_job_t *job, pappl_pr_options_t *options, pappl_device_t *device)
{
  const char *format = papplJobGetFormat(job);
  (void)options; (void)device;
  close_page();
  capture.pages = capture.rows = 0;
  capture.failed = false;
  if (!format || (strcmp(format, "image/pwg-raster") && strcmp(format, "image/urf")))
    return failure(job, "only PWG/Apple raster is accepted by the capture callbacks");
  if (capture.total_bytes >= MAX_RUN_BYTES)
    return failure(job, "run capture quota exhausted; restart into a fresh directory");
  papplJobSetMessage(job, "Receiving decoded raster into local files; no physical printing");
  return true;
}

static bool start_page(pappl_job_t *job, pappl_pr_options_t *options,
                       pappl_device_t *device, unsigned page)
{
  const capture_header_t *h = &options->header;
  char path[1200];
  unsigned long long bytes;
  (void)device;
  if (capture.failed || capture.page || papplJobIsCanceled(job)) return false;
  if (page != capture.pages || page >= MAX_PAGES || !h->cupsWidth || !h->cupsHeight ||
      h->cupsWidth > MAX_WIDTH || h->cupsHeight > MAX_HEIGHT ||
      h->HWResolution[0] != 300 || h->HWResolution[1] != 300 ||
      h->cupsBitsPerColor != 8 || h->cupsBitsPerPixel != 8 ||
      h->cupsNumColors != 1 || h->cupsColorOrder != CUPS_ORDER_CHUNKED ||
      (h->cupsColorSpace != CUPS_CSPACE_SW && h->cupsColorSpace != CUPS_CSPACE_K) ||
      h->cupsBytesPerLine != h->cupsWidth)
    return failure(job, "unsupported page geometry or decoded pixel layout");
  bytes = (unsigned long long)h->cupsBytesPerLine * h->cupsHeight;
  if (bytes > MAX_RUN_BYTES - capture.total_bytes)
    return failure(job, "page exceeds remaining decoded capture quota");
  snprintf(path, sizeof(path), "%s/job-%06d-page-%02u.rows.partial", capture.directory,
           papplJobGetID(job), page + 1);
  capture.page = fopen(path, "wbx");
  if (!capture.page) return failure(job, "cannot create fresh page file");
  if (BCryptOpenAlgorithmProvider(&capture.algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0 ||
      BCryptCreateHash(capture.algorithm, &capture.hash, NULL, 0, NULL, 0, 0) < 0) {
    close_page();
    return failure(job, "cannot initialize SHA-256");
  }
  capture.rows = 0;
  capture.page_bytes = 0;
  return true;
}

static bool write_line(pappl_job_t *job, pappl_pr_options_t *options,
                       pappl_device_t *device, unsigned y, const unsigned char *line)
{
  size_t size = options->header.cupsBytesPerLine;
  (void)device;
  if (capture.failed || papplJobIsCanceled(job)) return false;
  if (!capture.page || y != capture.rows || y >= options->header.cupsHeight ||
      size > MAX_WIDTH || size > MAX_RUN_BYTES - capture.total_bytes)
    return failure(job, "invalid row sequence or quota reached");
  /* Count attempted bytes too: disk failures must never regain quota. */
  capture.total_bytes += size;
  if (fwrite(line, 1, size, capture.page) != size ||
      BCryptHashData(capture.hash, (PUCHAR)line, (ULONG)size, 0) < 0)
    return failure(job, "row write or hash failed");
  capture.page_bytes += size;
  capture.rows++;
  return true;
}

static bool end_page(pappl_job_t *job, pappl_pr_options_t *options,
                     pappl_device_t *device, unsigned page)
{
  const capture_header_t *h = &options->header;
  char partial[1200], final[1200], meta[1200], hex[65];
  unsigned char digest[32];
  FILE *report;
  int written, closed;
  (void)device;
  if (capture.failed || papplJobIsCanceled(job) || !capture.page || capture.rows != h->cupsHeight) {
    close_page();
    return failure(job, "page incomplete or canceled");
  }
  if (BCryptFinishHash(capture.hash, digest, sizeof(digest), 0) < 0) {
    close_page(); return failure(job, "cannot finish SHA-256");
  }
  closed = fclose(capture.page);
  capture.page = NULL;
  close_page();
  if (closed) return failure(job, "cannot flush page file");
  for (unsigned i = 0; i < sizeof(digest); i++) snprintf(hex + 2 * i, 3, "%02x", digest[i]);
  snprintf(partial, sizeof(partial), "%s/job-%06d-page-%02u.rows.partial", capture.directory, papplJobGetID(job), page + 1);
  snprintf(final, sizeof(final), "%s/job-%06d-page-%02u.rows", capture.directory, papplJobGetID(job), page + 1);
  snprintf(meta, sizeof(meta), "%s/job-%06d-page-%02u.json", capture.directory, papplJobGetID(job), page + 1);
  /* MoveFile refuses to replace existing files. */
  if (!MoveFileA(partial, final)) return failure(job, "cannot finalize page file");
  if (!(report = fopen(meta, "wx"))) return failure(job, "cannot create metadata");
  written = fprintf(report,
    "{\n  \"version\": \"%s\", \"architecture\": \"%s\",\n"
    "  \"representation\": \"PAPPL decoded callback rows; not original document bytes\",\n"
    "  \"outcome\": \"PAGE_CALLBACK_COMPLETE_ONLY\", \"physical_printing\": false,\n"
    "  \"job_id\": %d, \"page\": %u, \"document_format\": \"%s\",\n"
    "  \"width\": %u, \"height\": %u, \"bytes_per_line\": %u,\n"
    "  \"bits_per_pixel\": %u, \"color_space\": %u, \"resolution\": [%u, %u],\n"
    "  \"captured_bytes\": %llu, \"sha256\": \"%s\"\n}\n",
    CAPTURE_VERSION, CAPTURE_ARCH, papplJobGetID(job), page + 1,
    papplJobGetFormat(job), h->cupsWidth, h->cupsHeight, h->cupsBytesPerLine,
    h->cupsBitsPerPixel, (unsigned)h->cupsColorSpace, h->HWResolution[0], h->HWResolution[1],
    capture.page_bytes, hex);
  closed = fclose(report);
  if (written < 0 || closed) return failure(job, "cannot write metadata");
  capture.pages++;
  printf("Saved page %u (%ux%u). No physical printing.\n", page + 1, h->cupsWidth, h->cupsHeight);
  fflush(stdout);
  papplLogJob(job, PAPPL_LOGLEVEL_INFO, "Captured page %u: %ux%u, %llu decoded bytes; no physical printing",
              page + 1, h->cupsWidth, h->cupsHeight, capture.page_bytes);
  return true;
}

static bool end_job(pappl_job_t *job, pappl_pr_options_t *options, pappl_device_t *device)
{
  (void)options; (void)device;
  close_page();
  if (capture.failed || !capture.pages || papplJobIsCanceled(job) ||
      papplJobGetState(job) == IPP_JSTATE_ABORTED) return false;
  papplJobSetMessage(job, "Captured %u page callback(s); no physical printing", capture.pages);
  return true;
}

static bool driver(pappl_system_t *system, const char *name, const char *uri,
                   const char *id, pappl_pr_driver_data_t *d, ipp_t **attrs, void *data)
{
  (void)system; (void)id; (void)attrs; (void)data;
  if (strcmp(name, "scx-capture") || strcmp(uri, "scxcapture://local")) return false;
  d->rstartjob_cb = start_job; d->rstartpage_cb = start_page;
  d->rwriteline_cb = write_line; d->rendpage_cb = end_page; d->rendjob_cb = end_job;
  /* No native raw format or file callback: never accept a printer-ready job. */
  d->format = NULL;
  papplCopyString(d->make_and_model, "SCX-4200 Capture Test", sizeof(d->make_and_model));
  d->kind = PAPPL_KIND_DOCUMENT;
  d->ppm = 1;
  d->raster_types = PAPPL_PWG_RASTER_TYPE_SGRAY_8;
  d->force_raster_type = PAPPL_PWG_RASTER_TYPE_SGRAY_8;
  d->color_supported = d->color_default = PAPPL_COLOR_MODE_MONOCHROME;
  d->num_resolution = 1;
  d->x_resolution[0] = d->y_resolution[0] = d->x_default = d->y_default = 300;
  d->orient_default = IPP_ORIENT_NONE;
  d->quality_default = IPP_QUALITY_NORMAL;
  d->sides_supported = d->sides_default = PAPPL_SIDES_ONE_SIDED;
  d->num_media = 1; d->media[0] = "iso_a4_210x297mm";
  d->num_source = 1; d->source[0] = "main";
  d->num_type = 1; d->type[0] = "stationery";
  d->left_right = 380; d->bottom_top = 530;
  papplCopyString(d->media_default.size_name, d->media[0], sizeof(d->media_default.size_name));
  papplCopyString(d->media_default.source, "main", sizeof(d->media_default.source));
  papplCopyString(d->media_default.type, "stationery", sizeof(d->media_default.type));
  d->media_default.size_width = 21000; d->media_default.size_length = 29700;
  d->media_default.left_margin = d->media_default.right_margin = d->left_right;
  d->media_default.top_margin = d->media_default.bottom_margin = d->bottom_top;
  d->media_ready[0] = d->media_default;
  return true;
}

int main(int argc, char **argv)
{
  pappl_system_t *system;
  pappl_printer_t *printer;
  pappl_pr_driver_t drivers[] = {{ "scx-capture", "SCX-4200 Capture Test", NULL, NULL }};
  SYSTEMTIME now;
  char spool[1200], log[1200];
  (void)argv;
  if (argc != 1) { fputs("Usage: SCX4200-IPP-Capture.exe\n", stderr); return 64; }
  GetSystemTime(&now);
  snprintf(capture.directory, sizeof(capture.directory), "capture-%04u%02u%02u-%02u%02u%02u-%03u-%lu",
           now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
           (unsigned long)GetCurrentProcessId());
  if (!CreateDirectoryA(capture.directory, NULL)) { fputs("Cannot create fresh capture directory.\n", stderr); return 1; }
  snprintf(spool, sizeof(spool), "%s/spool", capture.directory);
  snprintf(log, sizeof(log), "%s/framework.log", capture.directory);
  if (!CreateDirectoryA(spool, NULL)) return 1;
  system = papplSystemCreate(PAPPL_SOPTIONS_NO_TLS, "SCX-4200 Capture Test", 8631, NULL,
                             spool, log, PAPPL_LOGLEVEL_DEBUG, NULL, false);
  if (!system) return 1;
  papplSystemSetHostName(system, "localhost");
  papplSystemSetDNSSDName(system, NULL);
  papplSystemSetMaxClients(system, 4);
  papplSystemSetMaxImageSize(system, 16 * 1024 * 1024, MAX_WIDTH, MAX_HEIGHT);
  papplSystemSetMaxLogSize(system, 1024 * 1024);
  papplSystemSetPrinterDrivers(system, 1, drivers, NULL, NULL, driver, NULL);
  papplDeviceAddScheme("scxcapture", PAPPL_DEVTYPE_CUSTOM_LOCAL, NULL, device_open,
                       device_close, NULL, device_write, NULL, NULL);
  if (!papplSystemAddListeners(system, "127.0.0.1")) { papplSystemDelete(system); return 1; }
  printer = papplPrinterCreate(system, 1, "SCX-4200 Capture Test", "scx-capture", NULL, "scxcapture://local");
  if (!printer) { papplSystemDelete(system); return 1; }
  papplPrinterSetDNSSDName(printer, NULL);
  papplPrinterSetMaxActiveJobs(printer, 1);
  papplPrinterSetMaxCompletedJobs(printer, 10);
  papplPrinterSetMaxPreservedJobs(printer, 0);
  printf("SCX-4200 development capture %s (%s)\nLocal endpoint: http://127.0.0.1:8631/ipp/print\n"
         "Captures: %s\nNo physical printing. Keep this console open during the test.\n",
         CAPTURE_VERSION, CAPTURE_ARCH, capture.directory);
  fflush(stdout);
  papplSystemRun(system);
  papplSystemDelete(system);
  close_page();
  return 0;
}
