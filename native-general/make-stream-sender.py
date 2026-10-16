# SPDX-License-Identifier: Apache-2.0
"""Derive isolated sender retaining the reviewed transport/cancellation code."""
from pathlib import Path
p=Path(__file__).resolve().parent
s=(p.parent/'native-reliable-bridge/sender.c').read_text()
s=s.replace('#include <errno.h>','#include <errno.h>\n#include <stdint.h>')
s=s.replace('#define SENDER_VERSION "0.7.0"','#define SENDER_VERSION "0.12.0"')
s=s.replace('static unsigned document_pages;','static unsigned document_pages;\nstatic HANDLE bundle_file=INVALID_HANDLE_VALUE;\nstatic unsigned streamed_pages;\nstatic BOOL streaming;\nstatic unsigned char *stream_buffer;')
s=s.replace('    unsigned count=0;\n    while(count<document_pages', '    if(streaming)return streamed_pages;\n    unsigned count=0;\n    while(count<document_pages')
s=s.replace('One validated document of up to ten A4 pages.', 'One fully validated disk-spooled A4 document; no application page-count cap.')
insert=r'''
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
'''
s=s.replace('static BOOL save_report(',insert+'\nstatic BOOL save_report(')
a=s.index('    /* Read once into bounded memory;')
b=s.index('    if(!path || !inherited_manual_event',a)
s=s[:a]+r'''    bundle_file=CreateFileW(job_path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_FLAG_SEQUENTIAL_SCAN,NULL);
    if(bundle_file==INVALID_HANDLE_VALUE){fprintf(stderr,"Cannot exclusively retain job for reading.\n");return 3;}
    r.job_verified=validate_stream();
    if(!r.job_verified){CloseHandle(bundle_file);fprintf(stderr,"JOB_REJECTED: framing, hash, cancellation or page validation. No device accessed.\n");return 3;}
    if(validate_only){printf("JOB_VALIDATED %u pages %zu USB bytes %zu bundle bytes %s\n",document_pages,job_size,bundle_size,job_sha256);CloseHandle(bundle_file);return 0;}
    stream_buffer=malloc(WRITE_CHUNK);
    if(!stream_buffer){CloseHandle(bundle_file);return 3;}
''' + s[b:]
s=s.replace('r.transfer=send_job(device,test_job,job_size,write_chunk);','r.transfer=send_stream(device,write_chunk);')
s=s.replace('    free(selected);','    free(selected);\n    CloseHandle(bundle_file);\n    if(!stuck)free(stream_buffer);')
(p/'sender.c').write_text(s)

