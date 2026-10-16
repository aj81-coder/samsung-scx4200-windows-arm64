/* Native IPP multipage bridge. SPDX-License-Identifier: Apache-2.0
 * Independent renderer process consumes PGM; transport requires inherited permit.
 */

#include <pappl/pappl.h>
#include <windows.h>
#include <bcrypt.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "../native-render-print/job_validator.h"
#define CAPTURE_VERSION "0.7.0-dev"
#ifdef RELIABLE_TEST_SENDER
/* Compile-only test boundary: production has no runtime sender override. */
#define SENDER_NAME L"SCX4200-Test-Sender.exe"
#else
#define SENDER_NAME L"SCX4200-Bridge-Sender.exe"
#endif
#define MAX_WIDTH 2480u
#define MAX_HEIGHT 3509u
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
static struct {
 char directory[1024],run_directory[1024]; wchar_t executable[32768];
 FILE *page; unsigned pages,rows,height; bool failed,armed,mock,mock_fail;
 size_t acknowledged,qpdl_bytes,bundle_bytes,decoded_bytes; unsigned accepted_jobs,completed_jobs,completed_pages,accepted_pages; int job_id; char row_hash[65],qpdl_hash[65];
 unsigned heights[10]; char row_hashes[10][65],page_hashes[10][65]; size_t page_bytes[10]; bool blocked;
 BCRYPT_ALG_HANDLE algorithm; BCRYPT_HASH_HANDLE hash;
} bridge;
static volatile LONG stopping,monitor_done;
/* Valid until after the monitor and framework workers stop. There is one sender
 * per process, so its cancellation event is retained until process shutdown. */
static HANDLE child_job,retained_cancel[20]; static unsigned cancel_count;
static PVOID volatile transport_cancel; static volatile LONG active_job;
static bool session_result(const char *state);
static BOOL WINAPI console_stop(DWORD type) {
 if(type!=CTRL_C_EVENT && type!=CTRL_BREAK_EVENT && type!=CTRL_CLOSE_EVENT && type!=CTRL_SHUTDOWN_EVENT)return FALSE;
 InterlockedExchange(&stopping,1);HANDLE cancel=(HANDLE)InterlockedCompareExchangePointer(&transport_cancel,NULL,NULL);if(cancel)SetEvent(cancel);
 if(type==CTRL_CLOSE_EVENT || type==CTRL_SHUTDOWN_EVENT){ULONGLONG deadline=GetTickCount64()+4000;while(!monitor_done && GetTickCount64()<deadline)Sleep(50);}
 return TRUE;
}
static DWORD WINAPI shutdown_monitor(void *context) {
 while(!monitor_done){
#ifdef RELIABLE_TEST_SENDER
  if(GetFileAttributesW(L"test-stop.request")!=INVALID_FILE_ATTRIBUTES){InterlockedExchange(&stopping,1);HANDLE cancel=(HANDLE)InterlockedCompareExchangePointer(&transport_cancel,NULL,NULL);if(cancel)SetEvent(cancel);}
#endif
  if(stopping){papplSystemShutdown(context);return 0;}Sleep(100);}return 0;
}
static void close_page(void) {
 if(bridge.page){fclose(bridge.page);bridge.page=NULL;}
 if(bridge.hash){BCryptDestroyHash(bridge.hash);bridge.hash=NULL;}
 if(bridge.algorithm){BCryptCloseAlgorithmProvider(bridge.algorithm,0);bridge.algorithm=NULL;}
}
static bool result(const char *state,bool success) {
 char path[1200]; snprintf(path,sizeof(path),"%s/bridge-result.json",bridge.directory);
 HANDLE f=CreateFileA(path,GENERIC_WRITE,0,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,NULL);if(f==INVALID_HANDLE_VALUE)return false;
 char data[1024];int n=snprintf(data,sizeof(data),"{\"version\":\"%s\",\"architecture\":\"%s\",\"job_id\":%d,\"result\":\"%s\",\"success\":%s,\"mock_transport\":%s,\"bundle_sha256\":\"%s\",\"job_bytes\":%zu,\"usb_bytes\":%zu,\"acknowledged_bytes\":%zu,\"rows_sha256\":\"%s\",\"document_pages\":%u,\"bundle_bytes\":%zu,\"automatic_retry\":false}\n",CAPTURE_VERSION,CAPTURE_ARCH,bridge.job_id,state,success?"true":"false",bridge.mock?"true":"false",bridge.qpdl_hash,bridge.qpdl_bytes,bridge.qpdl_bytes,bridge.acknowledged,bridge.row_hash,bridge.pages,bridge.bundle_bytes);DWORD wrote=0;
 bool ok=n>0 && n<(int)sizeof(data) && WriteFile(f,data,(DWORD)n,&wrote,NULL) && wrote==(DWORD)n && FlushFileBuffers(f);CloseHandle(f);return ok;
}
static bool failure(pappl_job_t *job,const char *message) {
 bridge.failed=true; bridge.blocked=true; bridge.armed=false; close_page(); result(message,false);session_result(message);
 papplJobSetMessage(job,"Bridge stopped: %s; do not retry without reviewing results",message);
 papplLogJob(job,PAPPL_LOGLEVEL_ERROR,"Bridge stopped: %s",message);
 fprintf(stderr,"Bridge stopped: %s. Collect results; do not resend.\n",message); return false;
}
static bool device_open(pappl_device_t *d,const char *uri,const char *name){(void)d;(void)name;return !strcmp(uri,"scxcapture://local");}
static void device_close(pappl_device_t *d){(void)d;close_page();}
static ssize_t device_write(pappl_device_t *d,const void *p,size_t n){(void)d;(void)p;(void)n;errno=ENOTSUP;return -1;}
static bool session_result(const char *state) {
 char path[1200],data[1024];snprintf(path,sizeof(path),"%s/session-result.json",bridge.run_directory);
 HANDLE f=CreateFileA(path,GENERIC_WRITE,0,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,NULL);if(f==INVALID_HANDLE_VALUE)return false;
 int n=snprintf(data,sizeof(data),"{\"version\":\"%s\",\"state\":\"%s\",\"mock_transport\":%s,\"accepted_jobs\":%u,\"completed_jobs\":%u,\"accepted_pages\":%u,\"completed_pages\":%u,\"decoded_bytes\":%zu,\"maximum_document_pages\":10,\"maximum_session_pages\":20,\"blocked\":%s,\"automatic_retry\":false}\n",CAPTURE_VERSION,state,bridge.mock?"true":"false",bridge.accepted_jobs,bridge.completed_jobs,bridge.accepted_pages,bridge.completed_pages,bridge.decoded_bytes,bridge.blocked?"true":"false");DWORD wrote=0;
 bool ok=n>0 && n<(int)sizeof(data) && WriteFile(f,data,(DWORD)n,&wrote,NULL) && wrote==(DWORD)n && FlushFileBuffers(f);CloseHandle(f);return ok;
}
static bool start_job(pappl_job_t *job,pappl_pr_options_t *o,pappl_device_t *d) {
 (void)d; const char *format=papplJobGetFormat(job);
 if(!bridge.armed || bridge.blocked || bridge.accepted_pages>=20) {papplJobSetMessage(job,"Session stopped or page allowance consumed; collect results");return false;}
 bridge.armed=false;InterlockedExchange(&active_job,1);bridge.job_id=papplJobGetID(job);close_page();bridge.pages=bridge.rows=0;bridge.failed=false;
 bridge.acknowledged=bridge.qpdl_bytes=bridge.bundle_bytes=0;bridge.row_hash[0]=bridge.qpdl_hash[0]=0;bridge.accepted_jobs++;
 snprintf(bridge.directory,sizeof(bridge.directory),"%s/job-%06d",bridge.run_directory,bridge.job_id);
 if(!CreateDirectoryA(bridge.directory,NULL))return failure(job,"JOB_DIRECTORY_FAILED_NO_USB");
 if(stopping)return failure(job,"BRIDGE_STOPPING_NO_USB");
 if(!format || strcmp(format,"image/pwg-raster"))return failure(job,"UNSUPPORTED_FORMAT");
 if(o->copies!=1 || o->sides!=PAPPL_SIDES_ONE_SIDED)return failure(job,"ONE_COPY_ONE_SIDED_REQUIRED");
 if(!session_result("RECEIVING") || !result("RECEIVING",false))return failure(job,"REPORT_CREATE_FAILED_NO_USB");return true;
}
static bool start_page(pappl_job_t *job,pappl_pr_options_t *o,pappl_device_t *d,unsigned page) {
 (void)d; const capture_header_t *h=&o->header; char path[1200];
 if(bridge.failed || papplJobIsCanceled(job))return failure(job,"CANCELED_BEFORE_PAGE");
 if(page!=bridge.pages || bridge.pages>=10 || bridge.page || bridge.accepted_pages>=20)return failure(job,"PAGE_LIMIT_OR_SEQUENCE_REJECTED_NO_USB");
 if(h->cupsWidth!=2480 || (h->cupsHeight!=3507 && h->cupsHeight!=3509) || h->HWResolution[0]!=300 || h->HWResolution[1]!=300 || h->cupsBitsPerColor!=8 || h->cupsBitsPerPixel!=8 || h->cupsNumColors!=1 || h->cupsColorOrder!=CUPS_ORDER_CHUNKED || h->cupsColorSpace!=CUPS_CSPACE_SW || h->cupsBytesPerLine!=2480 || h->Duplex || h->NumCopies>1)return failure(job,"UNSUPPORTED_RASTER_GEOMETRY");
 bridge.height=h->cupsHeight;bridge.rows=0;bridge.heights[bridge.pages]=bridge.height;bridge.accepted_pages++;snprintf(path,sizeof(path),"%s/page-%02u.pgm.partial",bridge.directory,bridge.pages+1);
 bridge.page=fopen(path,"wbx");if(!bridge.page)return failure(job,"PGM_CREATE_FAILED");
 if(fprintf(bridge.page,"P5\n2480 %u\n255\n",bridge.height)<0 || BCryptOpenAlgorithmProvider(&bridge.algorithm,BCRYPT_SHA256_ALGORITHM,NULL,0)<0 || BCryptCreateHash(bridge.algorithm,&bridge.hash,NULL,0,NULL,0,0)<0)return failure(job,"HASH_INITIALIZATION_FAILED");
 return true;
}
static bool write_line(pappl_job_t *job,pappl_pr_options_t *o,pappl_device_t *d,unsigned y,const unsigned char *line) {
 (void)d;(void)o;
 if(bridge.failed || papplJobIsCanceled(job))return failure(job,"CANCELED_RECEIVING");
 if(!bridge.page || y!=bridge.rows || y>=bridge.height)return failure(job,"INVALID_ROW_SEQUENCE");
 if(fwrite(line,1,2480,bridge.page)!=2480 || BCryptHashData(bridge.hash,(PUCHAR)line,2480,0)<0)return failure(job,"ROW_WRITE_FAILED");
 bridge.rows++;bridge.decoded_bytes+=2480;if(bridge.decoded_bytes>180u*1024u*1024u)return failure(job,"SESSION_DECODED_BUDGET_EXCEEDED");return true;
}
static bool end_page(pappl_job_t *job,pappl_pr_options_t *o,pappl_device_t *d,unsigned page) {
 (void)o;(void)d;(void)page;unsigned char hash[32];char from[1200],to[1200];
 if(bridge.failed || papplJobIsCanceled(job) || !bridge.page || bridge.rows!=bridge.height)return failure(job,"INCOMPLETE_PAGE");
 if(BCryptFinishHash(bridge.hash,hash,32,0)<0)return failure(job,"ROW_HASH_FAILED");
 for(unsigned i=0;i<32;i++)snprintf(bridge.row_hash+i*2,3,"%02x",hash[i]);
 int rc=fclose(bridge.page);bridge.page=NULL;close_page();if(rc)return failure(job,"PGM_FLUSH_FAILED");
 snprintf(from,sizeof(from),"%s/page-%02u.pgm.partial",bridge.directory,bridge.pages+1);snprintf(to,sizeof(to),"%s/page-%02u.pgm",bridge.directory,bridge.pages+1);
 if(!MoveFileA(from,to))return failure(job,"PGM_FINALIZE_FAILED");
 snprintf(to,sizeof(to),"%s/page-%02u.json",bridge.directory,bridge.pages+1);
 HANDLE meta=CreateFileA(to,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,NULL);if(meta==INVALID_HANDLE_VALUE)return failure(job,"PAGE_METADATA_FAILED");
 char data[512];int n=snprintf(data,sizeof(data),"{\"page\":%u,\"width\":2480,\"height\":%u,\"rows_sha256\":\"%s\",\"captured_bytes\":%zu}\n",bridge.pages+1,bridge.height,bridge.row_hash,2480*(size_t)bridge.height);DWORD wrote=0;
 bool ok=n>0 && n<(int)sizeof(data) && WriteFile(meta,data,(DWORD)n,&wrote,NULL) && wrote==(DWORD)n && FlushFileBuffers(meta);CloseHandle(meta);if(!ok)return failure(job,"PAGE_METADATA_FLUSH_FAILED");
 strcpy(bridge.row_hashes[bridge.pages],bridge.row_hash);bridge.pages++;return true;
}
/* All child arguments come from generated paths, never IPP document attributes. */
static bool path_w(const char *leaf,wchar_t *out,size_t capacity) {
 char path[1200];wchar_t rel[1200];snprintf(path,sizeof(path),"%s/%s",bridge.directory,leaf);
 if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,rel,1200))return false;
 DWORD n=GetFullPathNameW(rel,(DWORD)capacity,out,NULL);return n && n<capacity;
}
/* Sender progress is advisory: completion still requires the full final report.
 * A generated per-job pathname and bundle hash prevent stale status attribution.
 * Missing, partial, or malformed progress never permits another write/retry. */
static void sender_progress(pappl_job_t *job,const wchar_t *path,char previous[32]) {
 HANDLE f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
 if(f==INVALID_HANDLE_VALUE)return;char data[2049];DWORD n=0;LARGE_INTEGER size;
 bool complete=GetFileSizeEx(f,&size) && size.QuadPart>0 && size.QuadPart<=2048 && ReadFile(f,data,2048,&n,NULL) && n==(DWORD)size.QuadPart;
 CloseHandle(f);data[n]=0;if(!complete)return;
 char needle[128];snprintf(needle,sizeof(needle),"\"job_sha256\":\"%s\"",bridge.qpdl_hash);
 if(!strstr(data,needle))return;
 const char *stage=NULL,*message=NULL;
 if(strstr(data,"\"stage\":\"WAITING_PAPER\"")){stage="WAITING_PAPER";message="Load paper in the printer; this job will continue when ready. Do not print it again.";}
 else if(strstr(data,"\"stage\":\"WAITING_PRINTER\"")){stage="WAITING_PRINTER";message="Waiting for printer readiness. Check paper and printer; do not print again.";}
 else if(strstr(data,"\"stage\":\"SENDING\"")){stage="SENDING";message="Sending this document to the printer.";}
 if(!stage || !strcmp(stage,previous))return;
 strcpy(previous,stage);papplJobSetMessage(job,"%s",message);
 papplPrinterSetReasons(papplJobGetPrinter(job),!strcmp(stage,"WAITING_PAPER")?PAPPL_PREASON_MEDIA_EMPTY:PAPPL_PREASON_NONE,!strcmp(stage,"WAITING_PAPER")?PAPPL_PREASON_NONE:PAPPL_PREASON_MEDIA_EMPTY);
 printf("%s\n",message);fflush(stdout);
}
static bool run_child(pappl_job_t *job,const wchar_t *exe,wchar_t *args,HANDLE permit,HANDLE cancel,DWORD timeout) {
 STARTUPINFOEXW si;PROCESS_INFORMATION pi;memset(&si,0,sizeof(si));memset(&pi,0,sizeof(pi));si.StartupInfo.cb=permit?sizeof(si):sizeof(STARTUPINFOW);
 DWORD flags=CREATE_NO_WINDOW|CREATE_SUSPENDED;bool inherit=permit!=NULL;SIZE_T bytes=0;
 if(inherit){InitializeProcThreadAttributeList(NULL,1,0,&bytes);si.lpAttributeList=HeapAlloc(GetProcessHeap(),0,bytes);
  if(!si.lpAttributeList || !InitializeProcThreadAttributeList(si.lpAttributeList,1,0,&bytes)){if(si.lpAttributeList)HeapFree(GetProcessHeap(),0,si.lpAttributeList);return false;}
  HANDLE handles[2]={permit,cancel};if(!UpdateProcThreadAttribute(si.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,handles,sizeof(handles),NULL,NULL)){DeleteProcThreadAttributeList(si.lpAttributeList);HeapFree(GetProcessHeap(),0,si.lpAttributeList);return false;} flags|=EXTENDED_STARTUPINFO_PRESENT;
 }
 BOOL made=!stopping && !papplJobIsCanceled(job) && CreateProcessW(exe,args,NULL,NULL,inherit,flags,NULL,NULL,&si.StartupInfo,&pi);
 if(si.lpAttributeList){DeleteProcThreadAttributeList(si.lpAttributeList);HeapFree(GetProcessHeap(),0,si.lpAttributeList);}if(!made)return false;
 if(!AssignProcessToJobObject(child_job,pi.hProcess) || ResumeThread(pi.hThread)==(DWORD)-1){TerminateProcess(pi.hProcess,126);WaitForSingleObject(pi.hProcess,4000);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);return false;}
 CloseHandle(pi.hThread);ULONGLONG until=GetTickCount64()+timeout;bool canceled=false;DWORD exit_code=1;
 DWORD wait_status;wchar_t progress[32768];char previous[32]={0};bool track=permit && path_w("sender-progress.json",progress,32768);
 while((wait_status=WaitForSingleObject(pi.hProcess,100))==WAIT_TIMEOUT){
  if(track)sender_progress(job,progress,previous);
  if(stopping || papplJobIsCanceled(job) || GetTickCount64()>=until){canceled=true;if(cancel)SetEvent(cancel);
   if(WaitForSingleObject(pi.hProcess,4000)!=WAIT_OBJECT_0){TerminateJobObject(child_job,125);WaitForSingleObject(pi.hProcess,4000);}break;}
 }
 if(wait_status==WAIT_FAILED){canceled=true;if(cancel)SetEvent(cancel);TerminateJobObject(child_job,127);WaitForSingleObject(pi.hProcess,4000);}
 bool ok=!canceled && GetExitCodeProcess(pi.hProcess,&exit_code) && exit_code==0;CloseHandle(pi.hProcess);return ok;
}
static bool load_qpdl(unsigned page) {
 char path[1200];snprintf(path,sizeof(path),"%s/page-%02u.qpdl",bridge.directory,page+1);FILE *f=fopen(path,"rb");if(!f)return false;
 if(fseek(f,0,SEEK_END)){fclose(f);return false;}long n=ftell(f);if(n<=0 || n>4*1024*1024){fclose(f);return false;}rewind(f);
 unsigned char *data=malloc((size_t)n);bool ok=data && fread(data,1,(size_t)n,f)==(size_t)n && fgetc(f)==EOF;fclose(f);
 if(ok)ok=validate_job(data,(size_t)n);
 BCRYPT_ALG_HANDLE alg=NULL;BCRYPT_HASH_HANDLE h=NULL;unsigned char digest[32];
 if(ok)ok=BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0)>=0 && BCryptCreateHash(alg,&h,NULL,0,NULL,0,0)>=0 && BCryptHashData(h,data,(ULONG)n,0)>=0 && BCryptFinishHash(h,digest,32,0)>=0;
 if(h)BCryptDestroyHash(h);if(alg)BCryptCloseAlgorithmProvider(alg,0);free(data);
 if(ok){bridge.page_bytes[page]=(size_t)n;bridge.qpdl_bytes+=(size_t)n;for(unsigned i=0;i<32;i++)snprintf(bridge.page_hashes[page]+2*i,3,"%02x",digest[i]);}return ok;
}
static bool journal(void) {
 wchar_t path[32768];if(!path_w("SEND_STARTED.json",path,32768))return false;
 HANDLE f=CreateFileW(path,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,NULL);if(f==INVALID_HANDLE_VALUE)return false;
 char data[512];int n=snprintf(data,sizeof(data),"{\"state\":\"SEND_STARTED\",\"bundle_sha256\":\"%s\",\"usb_bytes\":%zu,\"document_pages\":%u,\"bundle_bytes\":%zu,\"mock\":%s,\"retry\":false}\n",bridge.qpdl_hash,bridge.qpdl_bytes,bridge.pages,bridge.bundle_bytes,bridge.mock?"true":"false");DWORD wrote=0;
 bool ok=WriteFile(f,data,(DWORD)n,&wrote,NULL) && wrote==(DWORD)n && FlushFileBuffers(f);CloseHandle(f);return ok;
}
/* Re-read the persisted PGM and require its header, length, and captured-row hash
 * before giving the renderer a filename. No partial page can cross the boundary. */
static bool verify_pgm(unsigned page) {
 char path[1200],header[80],expected[80],hex[65];unsigned char block[16384],digest[32];
 snprintf(path,sizeof(path),"%s/page-%02u.pgm",bridge.directory,page+1);FILE *f=fopen(path,"rb");if(!f)return false;
 int n=snprintf(expected,sizeof(expected),"P5\n2480 %u\n255\n",bridge.heights[page]);
 bool ok=n>0 && fread(header,1,(size_t)n,f)==(size_t)n && !memcmp(header,expected,(size_t)n);
 BCRYPT_ALG_HANDLE alg=NULL;BCRYPT_HASH_HANDLE hash=NULL;
 if(ok)ok=BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0)>=0 && BCryptCreateHash(alg,&hash,NULL,0,NULL,0,0)>=0;
 size_t remaining=2480*(size_t)bridge.heights[page];
 while(ok && remaining){size_t wanted=remaining<sizeof(block)?remaining:sizeof(block);size_t got=fread(block,1,wanted,f);ok=got==wanted && BCryptHashData(hash,block,(ULONG)got,0)>=0;remaining-=got;}
 if(ok)ok=fgetc(f)==EOF && !ferror(f) && BCryptFinishHash(hash,digest,32,0)>=0;
 fclose(f);if(hash)BCryptDestroyHash(hash);if(alg)BCryptCloseAlgorithmProvider(alg,0);
 if(ok){for(unsigned i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",digest[i]);ok=!strcmp(hex,bridge.row_hashes[page]);}return ok;
}
static bool report_number_matches(const char *text,const char *field,size_t expected) {
 char needle[80];snprintf(needle,sizeof(needle),"\"%s\":",field);const char *p=strstr(text,needle);if(!p)return false;p+=strlen(needle);
 if(*p<'0' || *p>'9')return false;char *end=NULL;errno=0;unsigned long long value=strtoull(p,&end,10);
 return !errno && value==(unsigned long long)expected && (*end==',' || *end=='}') && !strstr(end,needle);
}
static bool report_boolean_matches(const char *text,const char *field,bool expected) {
 char needle[80];snprintf(needle,sizeof(needle),"\"%s\":",field);const char *p=strstr(text,needle);if(!p)return false;p+=strlen(needle);
 const char *value=expected?"true":"false";size_t n=strlen(value);return !strncmp(p,value,n) && (p[n]==',' || p[n]=='}') && !strstr(p+n,needle);
}
static bool transfer_report(const char *text,char *out,size_t capacity) {
 const char *p=strstr(text,"\"transfer\":{");if(!p)return false;p+=strlen("\"transfer\":");const char *end=strchr(p,'}');
 if(!end || memchr(p,'{',(size_t)(end-p))!=p || memchr(p+1,'{',(size_t)(end-p-1)) || strstr(end,"\"transfer\":"))return false;
 size_t n=(size_t)(end-p)+1;if(n>=capacity)return false;memcpy(out,p,n);out[n]=0;return true;
}
static bool make_bundle(void) {
 char path[1200];snprintf(path,sizeof(path),"%s/document.scxjob",bridge.directory);FILE *out=fopen(path,"wbx");if(!out)return false;
 BCRYPT_ALG_HANDLE alg=NULL;BCRYPT_HASH_HANDLE hash=NULL;unsigned char digest[32],block[16384];bool ok=true;
 if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0)<0 || BCryptCreateHash(alg,&hash,NULL,0,NULL,0,0)<0)ok=false;
 unsigned char header[12]={'S','C','X','J','O','B','0','6',0,0,0,(unsigned char)bridge.pages};
 if(ok)ok=fwrite(header,1,12,out)==12 && BCryptHashData(hash,header,12,0)>=0;bridge.bundle_bytes=12;
 for(unsigned p=0;ok && p<bridge.pages;p++){
  size_t n=bridge.page_bytes[p];unsigned char ph[36];for(unsigned i=0;i<4;i++)ph[i]=(unsigned char)(n>>(24-8*i));
  for(unsigned i=0;i<32;i++){unsigned v=0;if(sscanf(bridge.page_hashes[p]+2*i,"%2x",&v)!=1){ok=false;break;}ph[4+i]=(unsigned char)v;}
  if(!ok)break;ok=fwrite(ph,1,36,out)==36 && BCryptHashData(hash,ph,36,0)>=0;bridge.bundle_bytes+=36;
  snprintf(path,sizeof(path),"%s/page-%02u.qpdl",bridge.directory,p+1);FILE *f=fopen(path,"rb");if(!f){ok=false;break;}
  size_t remaining=n;while(ok && remaining){size_t wanted=remaining<sizeof(block)?remaining:sizeof(block);size_t got=fread(block,1,wanted,f);ok=got==wanted && fwrite(block,1,got,out)==got && BCryptHashData(hash,block,(ULONG)got,0)>=0;remaining-=got;bridge.bundle_bytes+=got;}
  if(ok)ok=fgetc(f)==EOF && !ferror(f);fclose(f);
 }
 if(ok)ok=BCryptFinishHash(hash,digest,32,0)>=0 && bridge.bundle_bytes<=40u*1024u*1024u+4096u;
 if(hash)BCryptDestroyHash(hash);if(alg)BCryptCloseAlgorithmProvider(alg,0);if(fclose(out))ok=false;
 if(ok)for(unsigned i=0;i<32;i++)snprintf(bridge.qpdl_hash+2*i,3,"%02x",digest[i]);return ok;
}
static bool end_job(pappl_job_t *job,pappl_pr_options_t *o,pappl_device_t *d) {
 (void)o;(void)d;close_page();
 if(bridge.failed || !bridge.pages || papplJobIsCanceled(job) || papplJobGetState(job)==IPP_JSTATE_ABORTED)return failure(job,"RECEIVE_FAILED_NO_USB");
 wchar_t pgm[32768],qpdl[32768],exe[32768],args[65536],report[32768],progress[32768];char leaf[80];
 if(!path_w("sender-report.json",report,32768))return failure(job,"PATH_FAILED");
 if(!path_w("sender-progress.json",progress,32768))return failure(job,"PATH_FAILED");
 wcscpy(exe,bridge.executable);wchar_t *slash=wcsrchr(exe,L'\\');if(!slash)return failure(job,"EXECUTABLE_PATH_FAILED");wcscpy(slash+1,L"SCX4200-Render.exe");
 for(unsigned p=0;p<bridge.pages;p++){
  if(!verify_pgm(p))return failure(job,"PGM_VERIFY_FAILED_NO_USB");
  snprintf(leaf,sizeof(leaf),"page-%02u.pgm",p+1);if(!path_w(leaf,pgm,32768))return failure(job,"PATH_FAILED");
  snprintf(leaf,sizeof(leaf),"page-%02u.qpdl",p+1);if(!path_w(leaf,qpdl,32768))return failure(job,"PATH_FAILED");
  if(swprintf(args,65536,L"\"%ls\" \"%ls\" \"%ls\"",exe,pgm,qpdl)<0 || !run_child(job,exe,args,NULL,NULL,60000))return failure(job,"RENDER_FAILED_NO_USB");
  if(stopping || papplJobIsCanceled(job) || !load_qpdl(p))return failure(job,"QPDL_VALIDATION_FAILED_NO_USB");
 }
 if(!make_bundle() || !path_w("document.scxjob",qpdl,32768))return failure(job,"BUNDLE_FAILED_NO_USB");
 wcscpy(slash+1,SENDER_NAME);
 if(swprintf(args,65536,L"\"%ls\" --jobbundle \"%ls\" --sha256 %hs --validate-only",exe,qpdl,bridge.qpdl_hash)<0 || !run_child(job,exe,args,NULL,NULL,60000))return failure(job,"BUNDLE_VALIDATION_FAILED_NO_USB");
 if(stopping || papplJobIsCanceled(job))return failure(job,"CANCELED_BEFORE_SEND_NO_USB");
 if(!journal())return failure(job,"JOURNAL_FAILED_NO_USB");
 if(bridge.mock){char path[1200];snprintf(path,sizeof(path),"%s/mock-transport.json",bridge.directory);FILE *f=fopen(path,"wx");if(!f)return failure(job,"MOCK_REPORT_FAILED");
  fprintf(f,"{\"mock\":true,\"usb_opened\":false,\"job_sha256\":\"%s\",\"job_bytes\":%zu,\"calls\":1}\n",bridge.qpdl_hash,bridge.qpdl_bytes);fclose(f);
  if(bridge.mock_fail)return failure(job,"MOCK_TRANSPORT_FAILED");bridge.acknowledged=bridge.qpdl_bytes;
 }else{
  SECURITY_ATTRIBUTES sa={sizeof(sa),NULL,TRUE};HANDLE permit=CreateEventW(&sa,TRUE,TRUE,NULL),cancel=CreateEventW(&sa,TRUE,FALSE,NULL);
  if(!permit || !cancel){if(permit)CloseHandle(permit);if(cancel)CloseHandle(cancel);return failure(job,"PERMIT_FAILED");}
  if(cancel_count>=20){CloseHandle(permit);CloseHandle(cancel);return failure(job,"CANCEL_EVENT_LIMIT");}retained_cancel[cancel_count++]=cancel;InterlockedExchangePointer(&transport_cancel,cancel);if(stopping || papplJobIsCanceled(job))SetEvent(cancel);
  wcscpy(slash+1,SENDER_NAME);
  int n=swprintf(args,65536,L"\"%ls\" --jobbundle \"%ls\" --sha256 %hs --permit-handle %llu --cancel-handle %llu --report \"%ls\" --progress \"%ls\"",exe,qpdl,bridge.qpdl_hash,(unsigned long long)(uintptr_t)permit,(unsigned long long)(uintptr_t)cancel,report,progress);
  bool ok=n>=0 && run_child(job,exe,args,permit,cancel,bridge.pages*60000u+300000u+20000u);CloseHandle(permit);
  if(!ok)return failure(job,"SEND_FAILED_OR_UNCERTAIN_NO_RETRY");
  FILE *f=_wfopen(report,L"rb");char data[16385];size_t got=f?fread(data,1,16384,f):0;bool complete=f && fgetc(f)==EOF && !ferror(f);if(f)fclose(f);data[got]=0;
  char hashneedle[128];snprintf(hashneedle,sizeof(hashneedle),"\"job_sha256\":\"%s\"",bridge.qpdl_hash);
  char transfer[2048];
  if(!complete || !strstr(data,hashneedle) || !transfer_report(data,transfer,sizeof(transfer)) || !report_number_matches(data,"document_pages",bridge.pages) || !report_number_matches(transfer,"pages_data_completed",bridge.pages) || !report_number_matches(transfer,"win32_error",0) || !report_number_matches(data,"bundle_bytes",bridge.bundle_bytes) || !report_number_matches(data,"job_bytes",bridge.qpdl_bytes) || !report_number_matches(transfer,"acknowledged_bytes",bridge.qpdl_bytes) || !report_boolean_matches(transfer,"delivery_uncertain",false) || !report_boolean_matches(transfer,"timed_out",false) || !report_boolean_matches(transfer,"cancellation_pending",false) || !report_boolean_matches(data,"bridge_permit_consumed",true) || !report_boolean_matches(data,"job_hash_verified",true) || !report_boolean_matches(data,"check_only",false) || !report_boolean_matches(data,"exclusive_read_write_open",true) || !strstr(data,"\"result\":\"USB_WRITE_COMPLETED_PHYSICAL_OUTPUT_UNCONFIRMED\""))return failure(job,"SEND_REPORT_UNCONFIRMED_NO_RETRY");
  bridge.acknowledged=bridge.qpdl_bytes;
 }
 papplPrinterSetReasons(papplJobGetPrinter(job),PAPPL_PREASON_NONE,PAPPL_PREASON_MEDIA_EMPTY);
 if(!result(bridge.mock?"MOCK_COMPLETED_NO_USB":"USB_WRITE_COMPLETED_PHYSICAL_OUTPUT_UNCONFIRMED",true))return failure(job,"FINAL_REPORT_FAILED_NO_RETRY");
 papplJobSetMessage(job,bridge.mock?"Mock transport complete; no USB":"USB write complete; verify the physical page");bridge.completed_jobs++;bridge.completed_pages+=bridge.pages;if(!session_result("JOB_COMPLETED"))return failure(job,"FINAL_SESSION_REPORT_FAILED_NO_RETRY");InterlockedExchangePointer(&transport_cancel,NULL);InterlockedExchange(&active_job,0);bridge.armed=bridge.accepted_pages<20 && !stopping;printf("Job completed (%u pages). Session total %u/20 pages. %s\n",bridge.pages,bridge.completed_pages,bridge.armed?"Ready for next document.":"Session allowance consumed; collect results.");fflush(stdout);return true;
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

int main(int argc,char **argv) {
 pappl_system_t *system;pappl_printer_t *printer;
 pappl_pr_driver_t drivers[]={{"scx-capture","SCX-4200 Capture Test",NULL,NULL}};
 SYSTEMTIME now;char spool[1200],log[1200];
 if(argc==2 && (!strcmp(argv[1],"--mock-transport") || !strcmp(argv[1],"--mock-transport=fail"))){bridge.mock=true;bridge.mock_fail=strchr(argv[1],'=')!=NULL;}
 else if(argc!=1){fputs("Usage: SCX4200-Reliable-Bridge.exe [--mock-transport|--mock-transport=fail]\n",stderr);return 64;}
 if(!GetModuleFileNameW(NULL,bridge.executable,32768))return 1;
 if(!bridge.mock){char line[32];printf("This development bridge will automatically print A4 documents (up to 10 pages each, 20 pages per session) to the connected SCX-4200.\nType ARM to allow the next supported Windows print job: ");fflush(stdout);
  if(!fgets(line,sizeof(line),stdin) || (strcmp(line,"ARM\n") && strcmp(line,"ARM\r\n"))){fputs("Not armed; no listener started.\n",stderr);return 1;}}
 else printf("TEST MODE: mock transport; NO USB access.\n");
 if(!bridge.mock){HANDLE lock=CreateFileW(L"SESSION-ACTIVE.lock",GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,NULL);if(lock==INVALID_HANDLE_VALUE){fputs("This package is already armed or cannot create its durable lock. Collect results; do not restart.\n",stderr);return 1;}
  const char marker[]="Active reliable session. Retained after interruption or failure; collect results and use reviewed recovery instructions.\r\n";DWORD wrote=0;bool ok=WriteFile(lock,marker,sizeof(marker)-1,&wrote,NULL) && wrote==sizeof(marker)-1 && FlushFileBuffers(lock);CloseHandle(lock);if(!ok)return 1;}
 bridge.armed=true;GetSystemTime(&now);
 snprintf(bridge.run_directory,sizeof(bridge.run_directory),"bridge-%04u%02u%02u-%02u%02u%02u-%03u-%lu",now.wYear,now.wMonth,now.wDay,now.wHour,now.wMinute,now.wSecond,now.wMilliseconds,(unsigned long)GetCurrentProcessId());
 if(!CreateDirectoryA(bridge.run_directory,NULL))return 1;strcpy(bridge.directory,bridge.run_directory);
 snprintf(spool,sizeof(spool),"%s/spool",bridge.directory);snprintf(log,sizeof(log),"%s/framework.log",bridge.directory);
 if(!CreateDirectoryA(spool,NULL))return 1;
 if(!session_result("ARMED_WAITING"))return 1;
 system=papplSystemCreate(PAPPL_SOPTIONS_NO_TLS,"SCX-4200 Capture Test",8631,NULL,spool,log,PAPPL_LOGLEVEL_DEBUG,NULL,false);if(!system)return 1;
 papplSystemSetHostName(system,"localhost");papplSystemSetDNSSDName(system,NULL);papplSystemSetMaxClients(system,4);
 papplSystemSetMaxImageSize(system,16*1024*1024,MAX_WIDTH,MAX_HEIGHT);papplSystemSetMaxLogSize(system,1024*1024);
 papplSystemSetPrinterDrivers(system,1,drivers,NULL,NULL,driver,NULL);
 papplDeviceAddScheme("scxcapture",PAPPL_DEVTYPE_CUSTOM_LOCAL,NULL,device_open,device_close,NULL,device_write,NULL,NULL);
 if(!papplSystemAddListeners(system,"127.0.0.1")){papplSystemDelete(system);return 1;}
 printer=papplPrinterCreate(system,1,"SCX-4200 Capture Test","scx-capture",NULL,"scxcapture://local");if(!printer){papplSystemDelete(system);return 1;}
 papplPrinterSetDNSSDName(printer,NULL);papplPrinterSetMaxActiveJobs(printer,1);papplPrinterSetMaxCompletedJobs(printer,10);papplPrinterSetMaxPreservedJobs(printer,0);
 printf("SCX-4200 automatic development bridge %s (%s)\nLocal endpoint: http://127.0.0.1:8631/ipp/print\nResults: %s\nReady for one-copy A4 documents: maximum 10 pages per document and 20 per session. Keep this window open.\n",CAPTURE_VERSION,CAPTURE_ARCH,bridge.directory);fflush(stdout);
 child_job=CreateJobObjectW(NULL,NULL);JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;memset(&limits,0,sizeof(limits));limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
 if(!child_job || !SetInformationJobObject(child_job,JobObjectExtendedLimitInformation,&limits,sizeof(limits))){if(child_job)CloseHandle(child_job);papplSystemDelete(system);return 1;}
 if(!SetConsoleCtrlHandler(console_stop,TRUE)){CloseHandle(child_job);papplSystemDelete(system);return 1;}
 HANDLE monitor=CreateThread(NULL,0,shutdown_monitor,system,0,NULL);
 if(!monitor){SetConsoleCtrlHandler(console_stop,FALSE);CloseHandle(child_job);papplSystemDelete(system);return 1;}
 papplSystemRun(system);InterlockedExchange(&monitor_done,1);WaitForSingleObject(monitor,INFINITE);CloseHandle(monitor);
 /* PAPPL may return after its shutdown grace period while an input worker is
  * still blocked. Avoid freeing its job/printer storage underneath that worker.
  * The OS releases allocations and closing this owned job stops any child. */
 if(stopping){bool clean=!InterlockedCompareExchange(&active_job,0,0) && !bridge.blocked;bool saved=session_result(clean?"CLEAN_SHUTDOWN":"INTERRUPTED_OR_FAILED_NO_RETRY");if(clean && saved && !bridge.mock)DeleteFileW(L"SESSION-ACTIVE.lock");CloseHandle(child_job);ExitProcess(clean && saved?0:1);}
 SetConsoleCtrlHandler(console_stop,FALSE);papplSystemDelete(system);for(unsigned i=0;i<cancel_count;i++)CloseHandle(retained_cancel[i]);CloseHandle(child_job);close_page();return 0;
}


