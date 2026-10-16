// SPDX-License-Identifier: Apache-2.0
/* Bounded document sender. Every page is validated before any device access.
 * No driver installation, queue changes, resets, or vendor IOCTLs.
 */
#include "../native-print-test/usb_read_helpers.h"
#include <bcrypt.h>
#include "../native-render-print/job_validator.h"
#include <io.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
static unsigned char *test_job;
static size_t job_size;
static char job_sha256[65];
static size_t bundle_size, page_ends[10];
static unsigned document_pages;
static HANDLE bundle_file=INVALID_HANDLE_VALUE;
static unsigned streamed_pages;
static BOOL streaming;
static unsigned char *stream_buffer;
#define MAX_BUNDLE (40u*1024u*1024u+4096u)
#define MAX_PAGE (4u*1024u*1024u)

#define SENDER_VERSION "0.12.0"
#define WRITE_CHUNK 16384
#define WRITE_TIMEOUT 300000
#define SEND_TIMEOUT 60000

typedef struct {
    BOOL ok, timed_out, cancellation_pending;
    DWORD error, bytes;
} WriteResult;
typedef WriteResult (*WriteFn)(HANDLE,const unsigned char *,DWORD);
typedef struct {
    size_t acknowledged;
    unsigned calls;
    BOOL attempted, uncertain, timed_out, cancellation_pending;
    DWORD error;
} Transfer;
typedef struct {
    const char *result;
    BOOL check_only, job_verified, opened, confirmed;
    DWORD enum_error, detail_errors, matches, rejected_service, open_error;
    Query id, status;
    Transfer transfer;
} Report;

static HANDLE cancel_event=NULL;
static FILE *report_file=NULL;
static const wchar_t *progress_path=NULL;
static ULONGLONG document_started,document_deadline,paper_wait_ms;
static unsigned status_polls;
static int last_status=-1;
static size_t progress_acknowledged;
static BOOL progress_failed,status_stuck;
static DWORD pending_timeout=WRITE_TIMEOUT;
static int (*test_status_provider)(void)=NULL;
typedef LONG (NTAPI *QueryEventFn)(HANDLE,int,PVOID,ULONG,PULONG);
static BOOL inherited_manual_event(HANDLE h) {
    DWORD flags=0; struct {int type; LONG state;} info={0};
    QueryEventFn query=(QueryEventFn)(void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtQueryEvent");
    return h && h!=INVALID_HANDLE_VALUE && GetHandleInformation(h,&flags) &&
        (flags&HANDLE_FLAG_INHERIT) && query && query(h,0,&info,sizeof(info),NULL)>=0 && info.type==0;
}
static BOOL consume_permit(HANDLE h) {
    return inherited_manual_event(h) && WaitForSingleObject(h,0)==WAIT_OBJECT_0 && ResetEvent(h);
}
static BOOL cancelled(void) {return cancel_event && WaitForSingleObject(cancel_event,0)==WAIT_OBJECT_0;}
static BOOL parse_handle(const wchar_t *s,HANDLE *h) {
    if(!s || !*s) return FALSE;
    for(const wchar_t *p=s;*p;p++) if(*p<L'0'||*p>L'9')return FALSE;
    errno=0; wchar_t *end=NULL; unsigned long long n=wcstoull(s,&end,10);
    if(errno || *end || !n || n>(unsigned long long)(UINT_PTR)-1)return FALSE;
    *h=(HANDLE)(UINT_PTR)n; return TRUE;
}

static BOOL identity_matches(const Identity *id) {
    return !_stricmp(id->manufacturer,"Samsung") &&
        (!_stricmp(id->model,"SCX-4200 Series") || !_stricmp(id->model,"SCX-4200"));
}

static BOOL sha256(const unsigned char *data,size_t size,unsigned char digest[32]) {
    BCRYPT_ALG_HANDLE alg=NULL;
    BCRYPT_HASH_HANDLE hash=NULL;
    DWORD length=0,received=0;
    unsigned char *object=NULL;
    BOOL ok=FALSE;
    if(size==0 || size>MAX_BUNDLE) return FALSE;
    if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0)<0) goto done;
    if(BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,(PUCHAR)&length,sizeof(length),&received,0)<0 || !length) goto done;
    object=(unsigned char *)malloc(length);
    if(!object) goto done;
    if(BCryptCreateHash(alg,&hash,object,length,NULL,0,0)<0) goto done;
    if(BCryptHashData(hash,(PUCHAR)data,(ULONG)size,0)<0) goto done;
    if(BCryptFinishHash(hash,digest,32,0)<0) goto done;
    ok=TRUE;
done:
    if(hash) BCryptDestroyHash(hash);
    if(alg) BCryptCloseAlgorithmProvider(alg,0);
    free(object);
    return ok;
}

/* Validate the complete envelope without altering it, then compact only the
 * validated page payloads in the SAME allocation. No pathname is reopened.
 * Overlap-safe moves make RAM bounded to MAX_BUNDLE, even for ten pages. */
static BOOL validate_bundle(unsigned char *data,size_t size,BOOL compact) {
    unsigned char digest[32];char hex[65];
    size_t starts[10], lengths[10], cursor=12,total=0;
    if(size<12 || size>MAX_BUNDLE || memcmp(data,"SCXJOB06",8))return FALSE;
    unsigned count=(unsigned)be32(data+8);
    if(count<1 || count>10 || !sha256(data,size,digest))return FALSE;
    for(unsigned i=0;i<32;i++)sprintf(hex+2*i,"%02x",digest[i]);
    hex[64]=0;
    if(strcmp(hex,job_sha256))return FALSE;
    for(unsigned i=0;i<count;i++) {
        if(size-cursor<36)return FALSE;
        size_t length=(size_t)be32(data+cursor);cursor+=4;
        const unsigned char *expected=data+cursor;cursor+=32;
        if(!length || length>MAX_PAGE || length>size-cursor || total>40u*1024u*1024u-length)return FALSE;
        if(!sha256(data+cursor,length,digest) || memcmp(expected,digest,32) || !validate_job(data+cursor,length))return FALSE;
        starts[i]=cursor;lengths[i]=length;cursor+=length;total+=length;
    }
    if(cursor!=size)return FALSE;
    if(compact) {
        size_t offset=0;
        for(unsigned i=0;i<count;i++) {
            memmove(data+offset,data+starts[i],lengths[i]);
            offset+=lengths[i];page_ends[i]=offset;
        }
        document_pages=count;job_size=total;
    }
    return TRUE;
}

static unsigned pages_completed(size_t acknowledged) {
    if(streaming)return streamed_pages;
    unsigned count=0;
    while(count<document_pages && acknowledged>=page_ends[count])count++;
    return count;
}

/* Publish only complete, durable snapshots. The pathname was exclusively
 * created by this process before device access; replacement never touches a
 * caller's existing file. Readers should share deletion for atomic replacement. */
static BOOL progress(const char *stage) {
    if(!progress_path)return TRUE; /* no-device self tests */
    size_t n=wcslen(progress_path);wchar_t *temp=calloc(n+10,sizeof(wchar_t));
    if(!temp){progress_failed=TRUE;return FALSE;}
    wcscpy(temp,progress_path);wcscat(temp,L".pending");
    HANDLE f=CreateFileW(temp,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    BOOL created=f!=INVALID_HANDLE_VALUE,ok=created;
    char json[768];char status[24];
    if(last_status<0)strcpy(status,"null");else snprintf(status,sizeof(status),"%d",last_status);
    int length=snprintf(json,sizeof(json),"{\"version\":\"%s\",\"job_sha256\":\"%s\",\"stage\":\"%s\",\"acknowledged_bytes\":%zu,\"pages_data_completed\":%u,\"document_pages\":%u,\"status_byte\":%s,\"elapsed_ms\":%llu,\"paper_wait_ms\":%llu,\"status_polls\":%u}\n",SENDER_VERSION,job_sha256,stage,progress_acknowledged,pages_completed(progress_acknowledged),document_pages,status,(unsigned long long)(GetTickCount64()-document_started),(unsigned long long)paper_wait_ms,status_polls);
    DWORD written=0;
    if(ok)ok=length>0 && (size_t)length<sizeof(json) && WriteFile(f,json,(DWORD)length,&written,NULL) && written==(DWORD)length && FlushFileBuffers(f);
    if(created)CloseHandle(f);
    if(ok)ok=MoveFileExW(temp,progress_path,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);
    if(!ok && created)DeleteFileW(temp);
    free(temp);if(!ok)progress_failed=TRUE;return ok;
}

static const char *status_stage(int status) {
    if(status>=0 && (status&0x20))return "WAITING_PAPER";
    if(status<0 || (status&0x18)!=0x18)return "WAITING_PRINTER";
    return "SENDING";
}

/* Each query owns its OVERLAPPED and output memory. A driver which refuses
 * cancellation retains them until process exit, just like the write buffer. */
static void poll_status(HANDLE h) {
    if(test_status_provider){status_polls++;last_status=test_status_provider();return;}
    Pending *p=calloc(1,sizeof(*p));status_polls++;last_status=-1;
    if(!p)return;
    p->ov.hEvent=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!p->ov.hEvent){free(p);return;}
    BOOL ok=DeviceIoControl(h,GET_STATUS,NULL,0,p->data,sizeof(DWORD),NULL,&p->ov);
    DWORD error=ok?0:GetLastError(),bytes=0;
    if(!ok && error==ERROR_IO_PENDING){
        HANDLE waits[2]={p->ov.hEvent,cancel_event};
        DWORD wait=cancel_event?WaitForMultipleObjects(2,waits,FALSE,1000):WaitForSingleObject(p->ov.hEvent,1000);
        if(wait!=WAIT_OBJECT_0){
            CancelIoEx(h,&p->ov);
            if(WaitForSingleObject(p->ov.hEvent,1000)!=WAIT_OBJECT_0){status_stuck=TRUE;return;}
            CloseHandle(p->ov.hEvent);free(p);return;
        }
        ok=TRUE;
    }
    if(ok && GetOverlappedResult(h,&p->ov,&bytes,FALSE) && bytes>=1 && bytes<=sizeof(DWORD))last_status=p->data[0];
    CloseHandle(p->ov.hEvent);free(p);
}

static BOOL wait_ready(HANDLE h) {
    while(strcmp(status_stage(last_status),"SENDING")){
        ULONGLONG before=GetTickCount64();
        if(cancelled() || status_stuck || before>=document_deadline || !progress(status_stage(last_status)))return FALSE;
        BOOL paper=last_status>=0 && (last_status&0x20);
        if(cancel_event)WaitForSingleObject(cancel_event,250);else Sleep(250);
        if(cancelled()){if(paper)paper_wait_ms+=GetTickCount64()-before;return FALSE;}
        poll_status(h);
        if(paper)paper_wait_ms+=GetTickCount64()-before;
    }
    return progress("SENDING");
}

static WriteResult write_chunk(HANDLE h,const unsigned char *data,DWORD bytes) {
    WriteResult r={0};
    OVERLAPPED *ov=(OVERLAPPED *)calloc(1,sizeof(*ov));
    if(!ov) {r.error=ERROR_NOT_ENOUGH_MEMORY; return r;}
    ov->hEvent=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!ov->hEvent) {r.error=GetLastError(); free(ov); return r;}
    BOOL ok=WriteFile(h,data,bytes,NULL,ov);
    DWORD error=ok ? 0 : GetLastError();
    if(!ok && error==ERROR_IO_PENDING) {
        HANDLE waits[2]={ov->hEvent,cancel_event};
        ULONGLONG started=GetTickCount64(),last_poll=started;
        DWORD wait=WAIT_TIMEOUT;
        for(;;){
            ULONGLONG now=GetTickCount64();
            if(cancelled()){wait=WAIT_OBJECT_0+1;break;}
            if(now-started>=pending_timeout || (document_deadline && now>=document_deadline)){wait=WAIT_TIMEOUT;break;}
            if(progress_failed || status_stuck){wait=WAIT_FAILED;SetLastError(ERROR_WRITE_FAULT);break;}
            ULONGLONG before=now;
            wait=cancel_event ? WaitForMultipleObjects(2,waits,FALSE,250) : WaitForSingleObject(ov->hEvent,250);
            if(last_status>=0 && (last_status&0x20))paper_wait_ms+=GetTickCount64()-before;
            if(wait!=WAIT_TIMEOUT)break;
            if(GetTickCount64()-last_poll>=1000){
                /* No second WriteFile is issued. This exact request and buffer
                 * remain pending while paper is refilled. */
                if(progress_path)poll_status(h);
                last_poll=GetTickCount64();
                const char *stage=status_stage(last_status);
                if(!strcmp(stage,"SENDING"))stage="WAITING_PRINTER";
                progress(stage);
            }
        }
        if(wait!=WAIT_OBJECT_0) {
            r.timed_out=(wait==WAIT_TIMEOUT);
            r.error=r.timed_out ? ERROR_TIMEOUT : (wait==WAIT_OBJECT_0+1 ? ERROR_OPERATION_ABORTED : GetLastError());
            CancelIoEx(h,ov);
            if(WaitForSingleObject(ov->hEvent,2000)!=WAIT_OBJECT_0) {
                r.cancellation_pending=TRUE;
                /* Keep OVERLAPPED/event/handle and heap job bytes alive until exit. */
                return r;
            }
            /* A completion racing cancellation is ambiguous: never retry it. */
            CloseHandle(ov->hEvent); free(ov); return r;
        }
        ok=TRUE;
    }
    if(ok) {
        ok=GetOverlappedResult(h,ov,&r.bytes,FALSE);
        error=ok ? 0 : GetLastError();
    }
    r.ok=ok; r.error=error;
    if(ok && (r.bytes==0 || r.bytes>bytes)) {r.ok=FALSE; r.error=ERROR_INVALID_DATA;}
    CloseHandle(ov->hEvent); free(ov);
    return r;
}

/* Short successful writes advance by the confirmed count. Failed/ambiguous
 * writes STOP. The remaining bytes and the job are never automatically retried. */
static Transfer send_job(HANDLE h,const unsigned char *data,size_t size,WriteFn write_fn) {
    Transfer t={0};
    document_started=GetTickCount64();
    document_deadline=document_started+(ULONGLONG)SEND_TIMEOUT*(document_pages?document_pages:1)+300000;
    while(t.acknowledged<size) {
        if(cancelled()) {t.error=ERROR_OPERATION_ABORTED;t.uncertain=t.attempted;break;}
        if(GetTickCount64()>=document_deadline) {
            t.error=ERROR_TIMEOUT; t.timed_out=TRUE; t.uncertain=t.attempted; break;
        }
        progress_acknowledged=t.acknowledged;
        if(write_fn==write_chunk && progress_path){
            poll_status(h);
            if(!wait_ready(h)){
                t.error=cancelled()?ERROR_OPERATION_ABORTED:(status_stuck || progress_failed?ERROR_WRITE_FAULT:ERROR_TIMEOUT);
                t.timed_out=t.error==ERROR_TIMEOUT;t.uncertain=t.attempted;t.cancellation_pending=status_stuck;break;
            }
        }
        size_t remaining=size-t.acknowledged;
        DWORD request=(DWORD)(remaining>WRITE_CHUNK ? WRITE_CHUNK : remaining);
        t.attempted=TRUE; t.calls++;
        WriteResult r=write_fn(h,data+t.acknowledged,request);
        if(!r.ok || !r.bytes || r.bytes>request) {
            t.error=r.error ? r.error : ERROR_INVALID_DATA;
            t.uncertain=TRUE; t.timed_out=r.timed_out; t.cancellation_pending=r.cancellation_pending || status_stuck;
            break;
        }
        t.acknowledged+=r.bytes;
        progress_acknowledged=t.acknowledged;
        if(!progress("SENDING")){t.error=ERROR_WRITE_FAULT;t.uncertain=TRUE;break;}
    }
    return t;
}


/* The source is opened with read sharing only and retained throughout delivery:
 * Windows rejects existing/future write or delete handles. No pathname reopen,
 * memory mapping, per-page array or whole-document allocation is used. */
static BOOL read_exact(HANDLE f,void *data,DWORD size){
    unsigned char *p=data;
    while(size){DWORD n=0;if(cancelled() || !ReadFile(f,p,size,&n,NULL)||!n)return FALSE;p+=n;size-=n;}
    return TRUE;
}
static BOOL rewind_bundle(void){LARGE_INTEGER zero;zero.QuadPart=0;return SetFilePointerEx(bundle_file,zero,NULL,FILE_BEGIN);}
static BOOL validate_stream(void){
    BCRYPT_ALG_HANDLE alg=NULL;BCRYPT_HASH_HANDLE hash=NULL;
    DWORD object_length=0,received=0;unsigned char *object=NULL,*page=NULL;
    unsigned char digest[32],head[36];char hex[65];BOOL ok=FALSE;
    LARGE_INTEGER length;
    if(!GetFileSizeEx(bundle_file,&length)||length.QuadPart<12 || (ULONGLONG)length.QuadPart>SIZE_MAX)return FALSE;
    bundle_size=(size_t)length.QuadPart;
    if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0)<0 ||
       BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,(PUCHAR)&object_length,sizeof(object_length),&received,0)<0 || !object_length)goto done;
    object=malloc(object_length);page=malloc(MAX_PAGE);
    if(!object || !page || BCryptCreateHash(alg,&hash,object,object_length,NULL,0,0)<0)goto done;
    size_t left=bundle_size;
    while(left){DWORD n=(DWORD)(left>MAX_PAGE?MAX_PAGE:left);if(!read_exact(bundle_file,page,n)||BCryptHashData(hash,page,n,0)<0)goto done;left-=n;}
    if(BCryptFinishHash(hash,digest,32,0)<0)goto done;
    for(unsigned i=0;i<32;i++)sprintf(hex+2*i,"%02x",digest[i]);hex[64]=0;
    if(strcmp(hex,job_sha256)||!rewind_bundle()||!read_exact(bundle_file,head,12)||memcmp(head,"SCXJOB06",8))goto done;
    document_pages=(unsigned)be32(head+8);job_size=0;
    if(!document_pages || (uint64_t)document_pages>(bundle_size-12)/37)goto done;
    uint64_t consumed=12;
    for(uint64_t i=0;i<document_pages;i++){
        if(bundle_size-consumed<36 || !read_exact(bundle_file,head,36))goto done;
        DWORD n=(DWORD)be32(head);consumed+=36;
        if(!n || n>MAX_PAGE || n>bundle_size-consumed || !read_exact(bundle_file,page,n) ||
           !sha256(page,n,digest) || memcmp(digest,head+4,32)||!validate_job(page,n)||job_size>SIZE_MAX-n)goto done;
        consumed+=n;job_size+=n;
    }
    ok=consumed==bundle_size && rewind_bundle();
done:
    if(hash)BCryptDestroyHash(hash);if(alg)BCryptCloseAlgorithmProvider(alg,0);
    free(object);free(page);if(ok){streaming=TRUE;streamed_pages=0;}return ok;
}
/* Every failed/ambiguous request stops; the current heap chunk remains alive
 * until process exit if cancellation does not complete. */
static Transfer send_stream(HANDLE h,WriteFn write_fn){
    Transfer t={0};unsigned char head[36];streaming=TRUE;streamed_pages=0;
    document_started=GetTickCount64();document_deadline=document_started+(ULONGLONG)SEND_TIMEOUT*document_pages+300000;
    if(!read_exact(bundle_file,head,12)){t.error=ERROR_READ_FAULT;return t;}
    for(uint64_t page=0;page<document_pages;page++){
        if(!read_exact(bundle_file,head,36)){t.error=cancelled()?ERROR_OPERATION_ABORTED:ERROR_READ_FAULT;t.uncertain=t.attempted;break;}
        DWORD left=(DWORD)be32(head);
        while(left){
            DWORD count=left>WRITE_CHUNK?WRITE_CHUNK:left;
            if(!read_exact(bundle_file,stream_buffer,count)){t.error=cancelled()?ERROR_OPERATION_ABORTED:ERROR_READ_FAULT;t.uncertain=t.attempted;return t;}
            DWORD offset=0;
            while(offset<count){
                if(cancelled()||GetTickCount64()>=document_deadline){t.error=cancelled()?ERROR_OPERATION_ABORTED:ERROR_TIMEOUT;t.timed_out=t.error==ERROR_TIMEOUT;t.uncertain=t.attempted;return t;}
                progress_acknowledged=t.acknowledged;
                if(write_fn==write_chunk && progress_path){poll_status(h);if(!wait_ready(h)){
                    t.error=cancelled()?ERROR_OPERATION_ABORTED:(status_stuck||progress_failed?ERROR_WRITE_FAULT:ERROR_TIMEOUT);
                    t.timed_out=t.error==ERROR_TIMEOUT;t.uncertain=t.attempted;t.cancellation_pending=status_stuck;return t;}}
                t.attempted=TRUE;t.calls++;WriteResult r=write_fn(h,stream_buffer+offset,count-offset);
                if(!r.ok||!r.bytes||r.bytes>count-offset){t.error=r.error?r.error:ERROR_INVALID_DATA;t.uncertain=TRUE;t.timed_out=r.timed_out;t.cancellation_pending=r.cancellation_pending||status_stuck;return t;}
                offset+=r.bytes;t.acknowledged+=r.bytes;progress_acknowledged=t.acknowledged;
                if(!progress("SENDING")){t.error=ERROR_WRITE_FAULT;t.uncertain=TRUE;return t;}
            }
            left-=count;
        }
        streamed_pages++;
    }
    return t;
}

static BOOL save_report(const wchar_t *path,const Report *r) {
    (void)path; FILE *out=report_file;
    if(!out || fflush(out) || _fseeki64(out,0,SEEK_SET)) return FALSE;
    fprintf(out,"{\n\"version\":\"%s\",\"build_architecture\":\"%s\",\"result\":\"%s\",\n",SENDER_VERSION,build_arch(),r->result);
    fprintf(out,"\"scope\":\"One fully validated disk-spooled A4 document; no application page-count cap. Bytes accepted by Windows do not prove physical printing.\",\n");
    fprintf(out,"\"check_only\":%s,\"job_sha256\":\"%s\",\"job_bytes\":%zu,\"job_hash_verified\":%s,\n",
        r->check_only?"true":"false",job_sha256,job_size,r->job_verified?"true":"false");
    fprintf(out,"\"bundle_bytes\":%zu,\"document_pages\":%u,\n",bundle_size,document_pages);
    fprintf(out,"\"printer_wait\":{\"status_polls\":%u,\"paper_wait_ms\":%llu,\"write_requests_replayed\":0},\n",status_polls,(unsigned long long)paper_wait_ms);
    fprintf(out,"\"enumeration_error\":%lu,\"detail_errors\":%lu,\"matching_devices\":%lu,\"wrong_service\":%lu,\n",
        (unsigned long)r->enum_error,(unsigned long)r->detail_errors,(unsigned long)r->matches,(unsigned long)r->rejected_service);
    fprintf(out,"\"exclusive_read_write_open\":%s,\"open_error\":%lu,\"bridge_permit_consumed\":%s,\n",
        r->opened?"true":"false",(unsigned long)r->open_error,r->confirmed?"true":"false");
    fprintf(out,"\"identity_query\":"); print_query(out,&r->id,TRUE);
    fprintf(out,",\n\"status_query\":"); print_query(out,&r->status,FALSE);
    fprintf(out,",\n\"transfer\":{\"attempted\":%s,\"acknowledged_bytes\":%zu,\"write_calls\":%u,\"win32_error\":%lu,\"delivery_uncertain\":%s,\"timed_out\":%s,\"cancellation_pending\":%s,\"pages_data_completed\":%u},\n",
        r->transfer.attempted?"true":"false",r->transfer.acknowledged,r->transfer.calls,(unsigned long)r->transfer.error,
        r->transfer.uncertain?"true":"false",r->transfer.timed_out?"true":"false",r->transfer.cancellation_pending?"true":"false",pages_completed(r->transfer.acknowledged));
    fprintf(out,"\"physical_output\":\"Awaiting user observation\",\"serial_numbers\":\"omitted\"\n}\n");
    BOOL ok=!ferror(out);
    if(fflush(out) || _chsize_s(_fileno(out),_ftelli64(out)) || !FlushFileBuffers((HANDLE)_get_osfhandle(_fileno(out)))) ok=FALSE;
    return ok;
}

/* In-memory test backend. It never opens a device. */
static unsigned fake_calls,fake_mode;
static const unsigned char *fake_base;
static size_t fake_offset;
static WriteResult fake_write(HANDLE h,const unsigned char *data,DWORD bytes) {
    (void)h;
    WriteResult r={0}; fake_calls++;
    if(data!=fake_base+fake_offset) {r.error=ERROR_INVALID_DATA; return r;}
    if(fake_mode==1 && fake_calls==2) {r.error=ERROR_GEN_FAILURE; return r;}
    if(fake_mode==2) {r.ok=TRUE; r.bytes=0; return r;}
    if(fake_mode==3) {r.ok=TRUE; r.bytes=bytes+1; return r;}
    if(fake_mode==4) {r.error=ERROR_TIMEOUT; r.timed_out=TRUE; r.cancellation_pending=TRUE; return r;}
    r.ok=TRUE; r.bytes=bytes>3 ? 3 : bytes;
    if(fake_mode==5 && fake_calls==1)SetEvent(cancel_event);
    fake_offset+=r.bytes; return r;
}
static DWORD WINAPI signal_cancel_thread(LPVOID unused) {
    (void)unused; Sleep(50); SetEvent(cancel_event);return 0;
}
static DWORD WINAPI disconnect_pipe_thread(LPVOID client){Sleep(50);CloseHandle((HANDLE)client);return 0;}
typedef struct {HANDLE client;DWORD delay;unsigned char bytes[WRITE_CHUNK];DWORD received;BOOL ok;} PipeReader;
static DWORD WINAPI resume_reader(LPVOID context){
    PipeReader *reader=context;Sleep(reader->delay);
    while(reader->received<WRITE_CHUNK){DWORD n=0;
        if(!ReadFile(reader->client,reader->bytes+reader->received,WRITE_CHUNK-reader->received,&n,NULL)||!n)return 0;
        reader->received+=n;
    }
    reader->ok=TRUE;return 0;
}
/* Accelerated old deadline = 250ms; consumer resumes at 600ms. One real
 * pending WriteFile survives that deadline and returns exactly the bytes. */
static BOOL test_pending_resume(void){
    wchar_t name[128];swprintf(name,128,L"\\\\.\\pipe\\scx-resume-test-%lu",(unsigned long)GetCurrentProcessId());
    HANDLE server=CreateNamedPipeW(name,PIPE_ACCESS_OUTBOUND|FILE_FLAG_OVERLAPPED|FILE_FLAG_FIRST_PIPE_INSTANCE,PIPE_TYPE_BYTE|PIPE_WAIT|PIPE_REJECT_REMOTE_CLIENTS,1,1,1,0,NULL);
    if(server==INVALID_HANDLE_VALUE)return FALSE;
    HANDLE client=CreateFileW(name,GENERIC_READ,0,NULL,OPEN_EXISTING,0,NULL);
    if(client==INVALID_HANDLE_VALUE){CloseHandle(server);return FALSE;}
    OVERLAPPED connect={0};connect.hEvent=CreateEventW(NULL,TRUE,FALSE,NULL);
    BOOL connected=ConnectNamedPipe(server,&connect);DWORD e=connected?0:GetLastError();
    CloseHandle(connect.hEvent);
    if(!connected && e!=ERROR_PIPE_CONNECTED){CloseHandle(client);CloseHandle(server);return FALSE;}
    unsigned char bytes[WRITE_CHUNK];for(unsigned i=0;i<WRITE_CHUNK;i++)bytes[i]=(unsigned char)(i*17u+3u);
    PipeReader reader={0};reader.client=client;reader.delay=600;
    ResetEvent(cancel_event);document_deadline=0;pending_timeout=2000;
    HANDLE thread=CreateThread(NULL,0,resume_reader,&reader,0,NULL);
    if(!thread){CloseHandle(client);CloseHandle(server);return FALSE;}
    ULONGLONG started=GetTickCount64();WriteResult r=write_chunk(server,bytes,sizeof(bytes));
    BOOL joined=WaitForSingleObject(thread,2500)==WAIT_OBJECT_0;
    if(!joined || r.cancellation_pending)ExitProcess(20); /* never free active buffers */
    BOOL ok=r.ok && r.bytes==WRITE_CHUNK && GetTickCount64()-started>=500 && reader.ok && reader.received==WRITE_CHUNK && !memcmp(reader.bytes,bytes,WRITE_CHUNK);
    CloseHandle(thread);CloseHandle(client);CloseHandle(server);pending_timeout=WRITE_TIMEOUT;return ok;
}
static unsigned status_test_calls;
static int ready_after_paper(void){status_test_calls++;return status_test_calls<2?0x38:0x19;}
static BOOL test_status_wait(void){
    if(strcmp(status_stage(0x18),"SENDING") || strcmp(status_stage(0x19),"SENDING") || strcmp(status_stage(0x98),"SENDING") ||
       strcmp(status_stage(0x38),"WAITING_PAPER") || strcmp(status_stage(0x20),"WAITING_PAPER") ||
       strcmp(status_stage(0x10),"WAITING_PRINTER") || strcmp(status_stage(0),"WAITING_PRINTER") || strcmp(status_stage(-1),"WAITING_PRINTER"))return FALSE;
    document_started=GetTickCount64();document_deadline=document_started+2000;paper_wait_ms=0;
    status_test_calls=0;test_status_provider=ready_after_paper;poll_status(NULL);
    BOOL ok=wait_ready(NULL) && status_test_calls==2 && paper_wait_ms>=200;
    last_status=0x20;SetEvent(cancel_event);BOOL cancelled_ok=!wait_ready(NULL);
    ResetEvent(cancel_event);test_status_provider=NULL;document_deadline=0;last_status=-1;
    return ok && cancelled_ok;
}
/* A private local pipe models an overlapped write blocked by its receiver.
 * It exercises the real event wait and CancelIoEx, without printer access. */
static BOOL test_pending_stop(unsigned mode) {
    wchar_t name[128];swprintf(name,128,L"\\\\.\\pipe\\scx-sender-test-%lu",(unsigned long)GetCurrentProcessId());
    HANDLE server=CreateNamedPipeW(name,PIPE_ACCESS_OUTBOUND|FILE_FLAG_OVERLAPPED|FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE|PIPE_WAIT|PIPE_REJECT_REMOTE_CLIENTS,1,1,1,0,NULL);
    if(server==INVALID_HANDLE_VALUE)return FALSE;
    HANDLE client=CreateFileW(name,GENERIC_READ,0,NULL,OPEN_EXISTING,0,NULL);
    if(client==INVALID_HANDLE_VALUE){CloseHandle(server);return FALSE;}
    OVERLAPPED connect={0};connect.hEvent=CreateEventW(NULL,TRUE,FALSE,NULL);
    BOOL connected=ConnectNamedPipe(server,&connect);
    DWORD error=connected?0:GetLastError();
    if(!connected && error!=ERROR_PIPE_CONNECTED){CloseHandle(connect.hEvent);CloseHandle(client);CloseHandle(server);return FALSE;}
    CloseHandle(connect.hEvent);
    unsigned char bytes[WRITE_CHUNK]={0};ResetEvent(cancel_event);
    pending_timeout=mode==1?100:WRITE_TIMEOUT;document_deadline=0;
    HANDLE thread=mode==1?NULL:CreateThread(NULL,0,mode==2?disconnect_pipe_thread:signal_cancel_thread,mode==2?client:NULL,0,NULL);
    if(mode!=1 && !thread){CloseHandle(client);CloseHandle(server);return FALSE;}
    WriteResult r=write_chunk(server,bytes,sizeof(bytes));
    if(thread){WaitForSingleObject(thread,1000);CloseHandle(thread);}
    /* Never return while the stack buffer may still be in use. */
    if(r.cancellation_pending){CloseHandle(client);WaitForSingleObject(server,2000);ExitProcess(15);}
    if(mode!=2)CloseHandle(client);CloseHandle(server);ResetEvent(cancel_event);pending_timeout=WRITE_TIMEOUT;
    return !r.ok && (mode==0?(r.error==ERROR_OPERATION_ABORTED && !r.timed_out):mode==1?(r.error==ERROR_TIMEOUT && r.timed_out):r.error==ERROR_BROKEN_PIPE);
}
static void put_be32(unsigned char *p,size_t n) {
    p[0]=(unsigned char)(n>>24);p[1]=(unsigned char)(n>>16);
    p[2]=(unsigned char)(n>>8);p[3]=(unsigned char)n;
}
static BOOL test_bundle_compaction(const unsigned char *blank,size_t size) {
    const unsigned char band[]={12,0,9,176,0,64,13,0,0,0,8,1,0,0,0,0,0,0,1};
    unsigned char second[1024],bundle[4096],digest[32];
    if(size+sizeof(band)>sizeof(second))return FALSE;
    size_t before_footer=size-sizeof(job_footer);
    memcpy(second,blank,before_footer);memcpy(second+before_footer,band,sizeof(band));
    memcpy(second+before_footer+sizeof(band),job_footer,sizeof(job_footer));
    size_t second_size=size+sizeof(band),cursor=12;
    if(!validate_job(second,second_size))return FALSE;
    memcpy(bundle,"SCXJOB06",8);put_be32(bundle+8,3);
    for(unsigned i=0;i<3;i++) {
        const unsigned char *page=i==1?second:blank;size_t length=i==1?second_size:size;
        put_be32(bundle+cursor,length);cursor+=4;
        if(!sha256(page,length,bundle+cursor))return FALSE;
        cursor+=32;memcpy(bundle+cursor,page,length);cursor+=length;
    }
    if(!sha256(bundle,cursor,digest))return FALSE;
    for(unsigned i=0;i<32;i++)sprintf(job_sha256+2*i,"%02x",digest[i]);job_sha256[64]=0;
    if(!validate_bundle(bundle,cursor,FALSE) || !validate_bundle(bundle,cursor,TRUE))return FALSE;
    return document_pages==3 && job_size==size*2+second_size &&
        page_ends[0]==size && page_ends[1]==size+second_size && page_ends[2]==job_size &&
        !memcmp(bundle,blank,size) && !memcmp(bundle+size,second,second_size) &&
        !memcmp(bundle+size+second_size,blank,size);
}
static int run_tests(void) {
    unsigned char valid[sizeof(job_prefix)-1+sizeof(page_header)+sizeof(job_footer)];
    size_t prefix=sizeof(job_prefix)-1;
    memcpy(valid,job_prefix,prefix);memcpy(valid+prefix,page_header,sizeof(page_header));
    memcpy(valid+prefix+sizeof(page_header),job_footer,sizeof(job_footer));
    if(!validate_job(valid,sizeof(valid))) return 1;
    for(size_t i=0;i<sizeof(valid);i++) {valid[i]^=1;if(validate_job(valid,sizeof(valid)))return 10;valid[i]^=1;}
    for(size_t n=0;n<sizeof(valid);n++)if(validate_job(valid,n))return 11;
    if(!test_bundle_compaction(valid,sizeof(valid)))return 17;
    document_pages=0;
    HANDLE permit=CreateEventW(NULL,TRUE,TRUE,NULL);
    if(!permit || consume_permit(permit))return 2;
    if(!SetHandleInformation(permit,HANDLE_FLAG_INHERIT,HANDLE_FLAG_INHERIT) ||
       !consume_permit(permit) || consume_permit(permit))return 2;
    CloseHandle(permit);
    Identity id={"Samsung","SCX-4200 Series","GDI"};
    if(!identity_matches(&id)) return 3;
    strcpy(id.model,"SCX-4300"); if(identity_matches(&id)) return 4;
    if(!target_instance(L"USB\\VID_04E8&PID_341B&MI_01\\123") || target_instance(L"USB\\VID_04E8&PID_341B&MI_00\\123")) return 5;
    const unsigned char fixture[]={0,1,2,3,4,5,6,7,8,9};
    cancel_event=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!cancel_event)return 12;
    for(fake_mode=0;fake_mode<7;fake_mode++) {
        ResetEvent(cancel_event);
        if(fake_mode==6)SetEvent(cancel_event);
        fake_calls=0; fake_offset=0; fake_base=fixture;
        Transfer t=send_job(NULL,fixture,sizeof(fixture),fake_write);
        if(fake_mode==0 && (t.acknowledged!=10 || t.error || fake_calls!=4 || t.uncertain)) return 6;
        if(fake_mode==1 && (t.acknowledged!=3 || fake_calls!=2 || !t.uncertain || !t.error)) return 7;
        if((fake_mode==2 || fake_mode==3) && (fake_calls!=1 || !t.error || t.acknowledged)) return 8;
        if(fake_mode==4 && (fake_calls!=1 || !t.timed_out || !t.cancellation_pending || !t.uncertain)) return 9;
        if(fake_mode==5 && (fake_calls!=1 || t.acknowledged!=3 || !t.uncertain || t.error!=ERROR_OPERATION_ABORTED))return 13;
        if(fake_mode==6 && (fake_calls || t.acknowledged || t.uncertain || t.attempted || t.error!=ERROR_OPERATION_ABORTED))return 14;
    }
    if(!test_pending_stop(0) || !test_pending_stop(1) || !test_pending_stop(2))return 15;
    if(!test_pending_resume())return 20;
    if(!test_status_wait())return 21;
    document_pages=3;page_ends[0]=3;page_ends[1]=6;page_ends[2]=10;
    if(pages_completed(0)!=0 || pages_completed(2)!=0 || pages_completed(3)!=1 ||
       pages_completed(5)!=1 || pages_completed(6)!=2 || pages_completed(9)!=2 || pages_completed(10)!=3)return 16;
    document_pages=0;
    CloseHandle(cancel_event); cancel_event=NULL;
    printf("{\"self_test\":\"PASS\",\"checks\":\"framing mutations and truncation, inherited one-use permit, target identity, short-write continuation, failure and timeout stop without replay, cancellation before/between/during writes, real pending private-pipe write resumed after accelerated old deadline with exact bytes, USB status masks including reserved bits, empty-paper preflight resume and cancellation, completed-page boundaries\"}\n");
    return 0;
}

int wmain(int argc,wchar_t **argv) {
    Report r={0}; r.result="STARTING";
    BOOL stuck=FALSE;
    if(argc==2 && !wcscmp(argv[1],L"--self-test")) return run_tests();
    const wchar_t *job_path=NULL,*hash_arg=NULL,*path=NULL; HANDLE permit=NULL; BOOL validate_only=FALSE;
    for(int i=1;i<argc;i++) {
        if(!wcscmp(argv[i],L"--jobbundle") && !job_path && i+1<argc)job_path=argv[++i];
        else if(!wcscmp(argv[i],L"--sha256") && !hash_arg && i+1<argc)hash_arg=argv[++i];
        else if(!wcscmp(argv[i],L"--check-only") && !r.check_only)r.check_only=TRUE;
        else if(!wcscmp(argv[i],L"--report") && !path && i+1<argc)path=argv[++i];
        else if(!wcscmp(argv[i],L"--progress") && !progress_path && i+1<argc)progress_path=argv[++i];
        else if(!wcscmp(argv[i],L"--permit-handle") && !permit && i+1<argc) {if(!parse_handle(argv[++i],&permit))return 64;}
        else if(!wcscmp(argv[i],L"--cancel-handle") && !cancel_event && i+1<argc) {if(!parse_handle(argv[++i],&cancel_event))return 64;}
        else if(!wcscmp(argv[i],L"--validate-only") && !validate_only)validate_only=TRUE;
        else {fprintf(stderr,"Invalid argument.\n");return 64;}
    }
    if(!job_path || !hash_arg || wcslen(hash_arg)!=64) {fprintf(stderr,"Usage: sender --jobbundle FILE --sha256 HEX --permit-handle DECIMAL --cancel-handle DECIMAL --report FILE [--check-only] [--validate-only]\n");return 64;}
    for(size_t i=0;i<64;i++) {
        wchar_t c=hash_arg[i];if(c>=L'A' && c<=L'F')c+=L'a'-L'A';
        if(!((c>=L'0' && c<=L'9') || (c>=L'a' && c<=L'f')))return 64;
        job_sha256[i]=(char)c;
    }
    bundle_file=CreateFileW(job_path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_FLAG_SEQUENTIAL_SCAN,NULL);
    if(bundle_file==INVALID_HANDLE_VALUE){fprintf(stderr,"Cannot exclusively retain job for reading.\n");return 3;}
    r.job_verified=validate_stream();
    if(!r.job_verified){CloseHandle(bundle_file);fprintf(stderr,"JOB_REJECTED: framing, hash, cancellation or page validation. No device accessed.\n");return 3;}
    if(validate_only){printf("JOB_VALIDATED %u pages %zu USB bytes %zu bundle bytes %s\n",document_pages,job_size,bundle_size,job_sha256);CloseHandle(bundle_file);return 0;}
    stream_buffer=malloc(WRITE_CHUNK);
    if(!stream_buffer){CloseHandle(bundle_file);return 3;}
    if(!path || !inherited_manual_event(cancel_event) || !consume_permit(permit)) {
        fprintf(stderr,"An inherited one-use bridge permit and cancellation Event are required.\n");free(test_job);return 64;
    }
    if(!r.check_only && (!progress_path || !(progress_path[0]==L'\\' || (wcslen(progress_path)>2 && progress_path[1]==L':' && (progress_path[2]==L'\\' || progress_path[2]==L'/'))))){free(test_job);return 64;}
    if(progress_path){
        HANDLE p=CreateFileW(progress_path,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
        if(p==INVALID_HANDLE_VALUE){free(test_job);return 1;}
        CloseHandle(p);document_started=GetTickCount64();
        if(!progress("SENDING")){free(test_job);return 1;}
    }
    r.confirmed=TRUE;
    HANDLE report_handle=CreateFileW(path,GENERIC_READ|GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if(report_handle==INVALID_HANDLE_VALUE) {free(test_job);return 1;}
    int fd=_open_osfhandle((intptr_t)report_handle,_O_BINARY|_O_RDWR);
    if(fd<0) {CloseHandle(report_handle);free(test_job);return 1;}
    report_file=_fdopen(fd,"w+b");
    if(!report_file) {_close(fd);free(test_job);return 1;}
    if(!save_report(path,&r)) {fclose(report_file);free(test_job);return 1;}
    HANDLE device=INVALID_HANDLE_VALUE;
    wchar_t *selected=NULL;
    if(cancelled()) {r.result="CANCELLED_NO_DATA_SENT"; goto finish;}
    HDEVINFO set=SetupDiGetClassDevsW(&usbprint_guid,NULL,NULL,DIGCF_PRESENT|DIGCF_DEVICEINTERFACE);
    if(set==INVALID_HANDLE_VALUE) {r.enum_error=GetLastError(); r.result="ENUMERATION_FAILED"; goto finish;}
    for(DWORD i=0;;i++) {
        SP_DEVICE_INTERFACE_DATA iface={0}; iface.cbSize=sizeof(iface);
        if(!SetupDiEnumDeviceInterfaces(set,NULL,&usbprint_guid,i,&iface)) {
            DWORD e=GetLastError(); if(e!=ERROR_NO_MORE_ITEMS) r.enum_error=e; break;
        }
        DWORD needed=0; SetupDiGetDeviceInterfaceDetailW(set,&iface,NULL,0,&needed,NULL);
        if(!needed || needed>65536) {r.detail_errors++; continue;}
        PSP_DEVICE_INTERFACE_DETAIL_DATA_W detail=(PSP_DEVICE_INTERFACE_DETAIL_DATA_W)calloc(1,needed);
        if(!detail) {r.enum_error=ERROR_NOT_ENOUGH_MEMORY; break;}
        detail->cbSize=sizeof(*detail);
        SP_DEVINFO_DATA info={0}; info.cbSize=sizeof(info);
        wchar_t instance[2048]={0},service[128]={0}; DWORD type=0;
        if(!SetupDiGetDeviceInterfaceDetailW(set,&iface,detail,needed,NULL,&info) ||
           !SetupDiGetDeviceInstanceIdW(set,&info,instance,2048,NULL)) {r.detail_errors++; free(detail); continue;}
        if(target_instance(instance)) {
            r.matches++;
            BOOL got_service=SetupDiGetDeviceRegistryPropertyW(set,&info,SPDRP_SERVICE,&type,(PBYTE)service,sizeof(service),NULL);
            service[127]=0;
            if(!got_service || type!=REG_SZ || _wcsicmp(service,L"usbprint")) r.rejected_service++;
            else if(!selected) {selected=_wcsdup(detail->DevicePath); if(!selected) r.enum_error=ERROR_NOT_ENOUGH_MEMORY;}
        }
        free(detail);
    }
    SetupDiDestroyDeviceInfoList(set);
    if(r.enum_error || r.detail_errors || r.rejected_service) {r.result="ENUMERATION_INCOMPLETE"; goto finish;}
    if(r.matches==0) {r.result="NO_DEVICE"; goto finish;}
    if(r.matches!=1 || !selected) {r.result="AMBIGUOUS_DEVICE"; goto finish;}
    /* Exclusive open prevents another writer interleaving a print job. */
    device=CreateFileW(selected,GENERIC_READ|GENERIC_WRITE,0,NULL,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,NULL);
    if(device==INVALID_HANDLE_VALUE) {r.open_error=GetLastError(); r.result="WRITE_ACCESS_FAILED"; goto finish;}
    r.opened=TRUE;
    query_device(device,GET_ID,ID_CAPACITY,&r.id);
    if(r.id.cancellation_pending) {stuck=TRUE; r.result="IDENTITY_TIMEOUT"; goto finish;}
    Identity identity; parse_identity(r.id.data,r.id.bytes,&identity);
    if(!r.id.ok || !identity_matches(&identity)) {r.result="IDENTITY_NOT_CONFIRMED"; goto finish;}
    poll_status(device);
    r.status.attempted=TRUE;r.status.ok=last_status>=0;r.status.bytes=r.status.ok?1:0;
    if(r.status.ok)r.status.data[0]=(unsigned char)last_status;
    if(status_stuck) {stuck=TRUE; r.status.cancellation_pending=TRUE;r.result="STATUS_TIMEOUT"; goto finish;}
    if(!r.status.ok || r.status.bytes<1) {r.result="STATUS_UNAVAILABLE"; goto finish;}
    printf("Printer identified: Samsung SCX-4200. Exclusive read/write access succeeded.\n");
    printf("Reported status byte: %u\n",r.status.data[0]);
    if(r.check_only) {r.result="PASS_WRITE_OPEN_ONLY"; goto finish;}
    if(cancelled()) {r.result="CANCELLED_NO_DATA_SENT"; goto finish;}
    r.result="SEND_STARTED";
    if(!save_report(path,&r)) {r.result="REPORT_SAVE_FAILED_NO_DATA_SENT"; goto finish;}
    r.transfer=send_stream(device,write_chunk);
    stuck=r.transfer.cancellation_pending || status_stuck;
    r.result=(!r.transfer.error && r.transfer.acknowledged==job_size) ? "USB_WRITE_COMPLETED_PHYSICAL_OUTPUT_UNCONFIRMED" : "SEND_FAILED_DO_NOT_RETRY";
finish:
    progress_acknowledged=r.transfer.acknowledged;
    if(!progress(!strcmp(r.result,"USB_WRITE_COMPLETED_PHYSICAL_OUTPUT_UNCONFIRMED")?"COMPLETE":"FAILED"))r.result="PROGRESS_SAVE_FAILED_DO_NOT_RETRY";
    free(selected);
    CloseHandle(bundle_file);
    if(!stuck)free(stream_buffer);
    if(device!=INVALID_HANDLE_VALUE && !stuck) CloseHandle(device);
    if(!stuck) free(test_job); /* pending I/O retains its buffer until process exit */
    BOOL saved=save_report(path,&r);
    printf("\nResult: %s\n",r.result);
    if(r.transfer.attempted) {
        printf("Windows acknowledged %zu of %zu bytes.\n",r.transfer.acknowledged,job_size);
        printf("%u of %u page payloads fully acknowledged. Please report physical output.\n",pages_completed(r.transfer.acknowledged),document_pages);
        printf("Do not run the test again if output is missing or incorrect; send the report first.\n");
    }
    if(saved) printf("Report saved: %ls\n",path);
    else printf("The final report could not be saved. Tell us this result instead.\n");
    fclose(report_file); report_file=NULL;
    if(!saved) return 1;
    if(!strcmp(r.result,"NO_DEVICE")) return 2;
    if(!strcmp(r.result,"CANCELLED_NO_DATA_SENT")) return 4;
    return (!strcmp(r.result,"PASS_WRITE_OPEN_ONLY") || !strcmp(r.result,"USB_WRITE_COMPLETED_PHYSICAL_OUTPUT_UNCONFIRMED")) ? 0 : 3;
}

