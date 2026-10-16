// SPDX-License-Identifier: Apache-2.0
/* Controlled one-page experiment. Only validated, hash-checked job data can print.
 * No driver installation, queue changes, resets, or vendor IOCTLs.
 */
#include "../native-print-test/usb_read_helpers.h"
#include <bcrypt.h>
#include "job_validator.h"
static unsigned char *test_job;
static size_t job_size;
static char job_sha256[65];

#define SENDER_VERSION "0.4.0"
#define WRITE_CHUNK 16384
#define WRITE_TIMEOUT 15000
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

static BOOL exact_confirmation(const char *s) {
    return !strcmp(s,"PRINT\n") || !strcmp(s,"PRINT\r\n");
}

static BOOL identity_matches(const Identity *id) {
    return !_stricmp(id->manufacturer,"Samsung") &&
        (!_stricmp(id->model,"SCX-4200 Series") || !_stricmp(id->model,"SCX-4200"));
}

static BOOL verify_job_hash(void) {
    BCRYPT_ALG_HANDLE alg=NULL;
    BCRYPT_HASH_HANDLE hash=NULL;
    DWORD length=0,received=0;
    unsigned char digest[32],*object=NULL;
    BOOL ok=FALSE;
    if(job_size==0 || job_size>4*1024*1024) return FALSE;
    if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0)<0) goto done;
    if(BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,(PUCHAR)&length,sizeof(length),&received,0)<0 || !length) goto done;
    object=(unsigned char *)malloc(length);
    if(!object) goto done;
    if(BCryptCreateHash(alg,&hash,object,length,NULL,0,0)<0) goto done;
    if(BCryptHashData(hash,(PUCHAR)test_job,(ULONG)job_size,0)<0) goto done;
    if(BCryptFinishHash(hash,digest,sizeof(digest),0)<0) goto done;
    char hex[65];
    for(size_t i=0;i<32;i++) sprintf(hex+2*i,"%02x",digest[i]);
    hex[64]=0;
    ok=strcmp(hex,job_sha256)==0;
done:
    if(hash) BCryptDestroyHash(hash);
    if(alg) BCryptCloseAlgorithmProvider(alg,0);
    free(object);
    return ok;
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
        DWORD wait=WaitForSingleObject(ov->hEvent,WRITE_TIMEOUT);
        if(wait!=WAIT_OBJECT_0) {
            r.timed_out=(wait==WAIT_TIMEOUT);
            r.error=r.timed_out ? ERROR_TIMEOUT : GetLastError();
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
    ULONGLONG started=GetTickCount64();
    while(t.acknowledged<size) {
        if(GetTickCount64()-started>=SEND_TIMEOUT) {
            t.error=ERROR_TIMEOUT; t.timed_out=TRUE; t.uncertain=t.attempted; break;
        }
        size_t remaining=size-t.acknowledged;
        DWORD request=(DWORD)(remaining>WRITE_CHUNK ? WRITE_CHUNK : remaining);
        t.attempted=TRUE; t.calls++;
        WriteResult r=write_fn(h,data+t.acknowledged,request);
        if(!r.ok || !r.bytes || r.bytes>request) {
            t.error=r.error ? r.error : ERROR_INVALID_DATA;
            t.uncertain=TRUE; t.timed_out=r.timed_out; t.cancellation_pending=r.cancellation_pending;
            break;
        }
        t.acknowledged+=r.bytes;
    }
    return t;
}

static BOOL save_report(const wchar_t *path,const Report *r) {
    FILE *out=_wfopen(path,L"wb");
    if(!out) return FALSE;
    fprintf(out,"{\n\"version\":\"%s\",\"build_architecture\":\"%s\",\"result\":\"%s\",\n",SENDER_VERSION,build_arch(),r->result);
    fprintf(out,"\"scope\":\"One validated A4 page. Bytes accepted by Windows do not prove physical printing.\",\n");
    fprintf(out,"\"check_only\":%s,\"job_sha256\":\"%s\",\"job_bytes\":%zu,\"job_hash_verified\":%s,\n",
        r->check_only?"true":"false",job_sha256,job_size,r->job_verified?"true":"false");
    fprintf(out,"\"enumeration_error\":%lu,\"detail_errors\":%lu,\"matching_devices\":%lu,\"wrong_service\":%lu,\n",
        (unsigned long)r->enum_error,(unsigned long)r->detail_errors,(unsigned long)r->matches,(unsigned long)r->rejected_service);
    fprintf(out,"\"exclusive_read_write_open\":%s,\"open_error\":%lu,\"user_confirmed_PRINT\":%s,\n",
        r->opened?"true":"false",(unsigned long)r->open_error,r->confirmed?"true":"false");
    fprintf(out,"\"identity_query\":"); print_query(out,&r->id,TRUE);
    fprintf(out,",\n\"status_query\":"); print_query(out,&r->status,FALSE);
    fprintf(out,",\n\"transfer\":{\"attempted\":%s,\"acknowledged_bytes\":%zu,\"write_calls\":%u,\"win32_error\":%lu,\"delivery_uncertain\":%s,\"timed_out\":%s,\"cancellation_pending\":%s},\n",
        r->transfer.attempted?"true":"false",r->transfer.acknowledged,r->transfer.calls,(unsigned long)r->transfer.error,
        r->transfer.uncertain?"true":"false",r->transfer.timed_out?"true":"false",r->transfer.cancellation_pending?"true":"false");
    fprintf(out,"\"physical_output\":\"Awaiting user observation\",\"serial_numbers\":\"omitted\"\n}\n");
    BOOL ok=!ferror(out);
    if(fclose(out)) ok=FALSE;
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
    fake_offset+=r.bytes; return r;
}
static int run_tests(void) {
    unsigned char valid[sizeof(job_prefix)-1+sizeof(page_header)+sizeof(job_footer)];
    size_t prefix=sizeof(job_prefix)-1;
    memcpy(valid,job_prefix,prefix);memcpy(valid+prefix,page_header,sizeof(page_header));
    memcpy(valid+prefix+sizeof(page_header),job_footer,sizeof(job_footer));
    if(!validate_job(valid,sizeof(valid))) return 1;
    for(size_t i=0;i<sizeof(valid);i++) {valid[i]^=1;if(validate_job(valid,sizeof(valid)))return 10;valid[i]^=1;}
    for(size_t n=0;n<sizeof(valid);n++)if(validate_job(valid,n))return 11;
    if(!exact_confirmation("PRINT\n") || !exact_confirmation("PRINT\r\n") ||
       exact_confirmation("PRINT") || exact_confirmation("print\n") || exact_confirmation("PRINT MORE\n")) return 2;
    Identity id={"Samsung","SCX-4200 Series","GDI"};
    if(!identity_matches(&id)) return 3;
    strcpy(id.model,"SCX-4300"); if(identity_matches(&id)) return 4;
    if(!target_instance(L"USB\\VID_04E8&PID_341B&MI_01\\123") || target_instance(L"USB\\VID_04E8&PID_341B&MI_00\\123")) return 5;
    const unsigned char fixture[]={0,1,2,3,4,5,6,7,8,9};
    for(fake_mode=0;fake_mode<5;fake_mode++) {
        fake_calls=0; fake_offset=0; fake_base=fixture;
        Transfer t=send_job(NULL,fixture,sizeof(fixture),fake_write);
        if(fake_mode==0 && (t.acknowledged!=10 || t.error || fake_calls!=4 || t.uncertain)) return 6;
        if(fake_mode==1 && (t.acknowledged!=3 || fake_calls!=2 || !t.uncertain || !t.error)) return 7;
        if((fake_mode==2 || fake_mode==3) && (fake_calls!=1 || !t.error || t.acknowledged)) return 8;
        if(fake_mode==4 && (fake_calls!=1 || !t.timed_out || !t.cancellation_pending || !t.uncertain)) return 9;
    }
    printf("{\"self_test\":\"PASS\",\"checks\":\"framing mutations and truncation, confirmation, target, identity, short-write continuation, failure stop, zero/oversize write, timeout stop\"}\n");
    return 0;
}

int wmain(int argc,wchar_t **argv) {
    Report r={0}; r.result="STARTING";
    BOOL pause=TRUE,stuck=FALSE;
    if(argc==2 && !wcscmp(argv[1],L"--self-test")) return run_tests();
    const wchar_t *job_path=NULL,*hash_arg=NULL;BOOL validate_only=FALSE;
    for(int i=1;i<argc;i++) {
        if(!wcscmp(argv[i],L"--job") && !job_path && i+1<argc)job_path=argv[++i];
        else if(!wcscmp(argv[i],L"--sha256") && !hash_arg && i+1<argc)hash_arg=argv[++i];
        else if(!wcscmp(argv[i],L"--check-only") && !r.check_only)r.check_only=TRUE;
        else if(!wcscmp(argv[i],L"--no-pause") && pause)pause=FALSE;
        else if(!wcscmp(argv[i],L"--validate-only") && !validate_only)validate_only=TRUE;
        else {fprintf(stderr,"Invalid argument.\n");return 64;}
    }
    if(!job_path || !hash_arg || wcslen(hash_arg)!=64) {fprintf(stderr,"Usage: sender --job FILE --sha256 HEX [--check-only] [--no-pause] [--validate-only]\n");return 64;}
    for(size_t i=0;i<64;i++) {
        wchar_t c=hash_arg[i];if(c>=L'A' && c<=L'F')c+=L'a'-L'A';
        if(!((c>=L'0' && c<=L'9') || (c>=L'a' && c<=L'f')))return 64;
        job_sha256[i]=(char)c;
    }
    /* Read once into bounded memory; later hash, validation and writes use these
     * same bytes, never a re-opened pathname. No devices accessed here. */
    FILE *input=_wfopen(job_path,L"rb");
    if(!input) {fprintf(stderr,"Cannot open job.\n");return 3;}
    test_job=(unsigned char *)malloc(4*1024*1024);
    if(!test_job) {fclose(input);return 3;}
    job_size=fread(test_job,1,4*1024*1024,input);
    BOOL read_ok=!ferror(input) && fgetc(input)==EOF && !ferror(input);
    if(fclose(input))read_ok=FALSE;
    r.job_verified=read_ok && verify_job_hash() && validate_job(test_job,job_size);
    if(!r.job_verified) {fprintf(stderr,"JOB_REJECTED: read, hash or one-page QPDL validation failed. No device accessed.\n");free(test_job);return 3;}
    if(validate_only) {printf("JOB_VALIDATED %zu bytes %s\n",job_size,job_sha256);free(test_job);return 0;}
    printf("SCX-4200 captured-page test %s (%s)\n",SENDER_VERSION,build_arch());
    printf("Validated one A4 page. Nothing is sent unless you type PRINT.\n");fflush(stdout);
    wchar_t path[32768]; DWORD n=GetModuleFileNameW(NULL,path,32768);
    if(!n || n>=32700) return 1;
    wchar_t *filename=wcsrchr(path,L'\\'); if(!filename) return 1; filename++;
    SYSTEMTIME now; GetLocalTime(&now);
    swprintf(filename,100,L"print-test-%04u%02u%02u-%02u%02u%02u-%lu.json",now.wYear,now.wMonth,now.wDay,now.wHour,now.wMinute,now.wSecond,(unsigned long)GetCurrentProcessId());
    if(!save_report(path,&r)) {fprintf(stderr,"Cannot save a report. Move the program into a writable folder.\n"); if(pause)getchar(); return 1;}
    HANDLE device=INVALID_HANDLE_VALUE;
    wchar_t *selected=NULL;
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
    query_device(device,GET_STATUS,sizeof(DWORD),&r.status);
    if(r.status.cancellation_pending) {stuck=TRUE; r.result="STATUS_TIMEOUT"; goto finish;}
    if(!r.status.ok || r.status.bytes<1) {r.result="STATUS_UNAVAILABLE"; goto finish;}
    printf("Printer identified: Samsung SCX-4200. Exclusive read/write access succeeded.\n");
    printf("Reported status byte: %u\n",r.status.data[0]);
    if(r.check_only) {r.result="PASS_WRITE_OPEN_ONLY"; goto finish;}
    DWORD console_mode=0;
    if(!GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE),&console_mode)) {r.result="INTERACTIVE_CONFIRMATION_REQUIRED"; goto finish;}
    printf("\nLoad A4 paper, check that the printer is ready and no other job is printing.\n");
    printf("This sends ONE test page, one copy.\nType PRINT and press Enter to send it; anything else cancels: "); fflush(stdout);
    char answer[32]={0};
    if(!fgets(answer,sizeof(answer),stdin) || !exact_confirmation(answer)) {r.result="CANCELLED_NO_DATA_SENT"; goto finish;}
    r.confirmed=TRUE;
    r.result="SENDING_OR_INTERRUPTED_DO_NOT_RETRY";
    if(!save_report(path,&r)) {r.result="REPORT_SAVE_FAILED_NO_DATA_SENT"; goto finish;}
    r.transfer=send_job(device,test_job,job_size,write_chunk);
    stuck=r.transfer.cancellation_pending;
    r.result=(!r.transfer.error && r.transfer.acknowledged==job_size) ? "BYTES_SENT_AWAITING_PAPER_CHECK" : "SEND_FAILED_DO_NOT_RETRY";
finish:
    free(selected);
    if(device!=INVALID_HANDLE_VALUE && !stuck) CloseHandle(device);
    if(!stuck) free(test_job); /* pending I/O retains its buffer until process exit */
    BOOL saved=save_report(path,&r);
    printf("\nResult: %s\n",r.result);
    if(r.transfer.attempted) {
        printf("Windows acknowledged %zu of %zu bytes.\n",r.transfer.acknowledged,job_size);
        printf("Please report whether one correct page actually printed.\n");
        printf("Do not run the test again if output is missing or incorrect; send the report first.\n");
    }
    if(saved) printf("Report saved beside this program: %ls\n",filename);
    else printf("The final report could not be saved. Tell us this result instead.\n");
    if(pause && !stuck) {printf("Press Enter to close.\n"); fflush(stdout); getchar();}
    if(!saved) return 1;
    if(!strcmp(r.result,"NO_DEVICE")) return 2;
    if(!strcmp(r.result,"CANCELLED_NO_DATA_SENT")) return 4;
    return (!strcmp(r.result,"PASS_WRITE_OPEN_ONLY") || !strcmp(r.result,"BYTES_SENT_AWAITING_PAPER_CHECK")) ? 0 : 3;
}
