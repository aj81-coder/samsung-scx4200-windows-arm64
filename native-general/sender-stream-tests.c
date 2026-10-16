// SPDX-License-Identifier: Apache-2.0
/* Test-only harness: never enumerates or opens USB devices. */
#define wmain production_sender_main
#include "sender.c"
#undef wmain
static FILE *sink;
static unsigned mode,calls;
static WriteResult capture(HANDLE h,const unsigned char *data,DWORD bytes){
    (void)h;WriteResult r={0};calls++;
    if(mode==1&&calls==2){r.error=ERROR_GEN_FAILURE;return r;}
    DWORD n=bytes>997?997:bytes;
    if(fwrite(data,1,n,sink)!=n){r.error=ERROR_WRITE_FAULT;return r;}
    r.ok=TRUE;r.bytes=n;
    if(mode==2&&calls==1)SetEvent(cancel_event);
    return r;
}
int wmain(int argc,wchar_t **argv){
    if(argc!=4)return 64;
    for(unsigned i=0;i<64;i++)job_sha256[i]=(char)argv[2][i];
    bundle_file=CreateFileW(argv[1],GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    cancel_event=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(bundle_file==INVALID_HANDLE_VALUE||!cancel_event||!validate_stream())return 1;
    if(document_pages<=10||bundle_size<=40u*1024u*1024u)return 2;
    /* Initial progress/report is published before send_stream is entered. */
    if(pages_completed(0)!=0)return 12;
    HANDLE writer=CreateFileW(argv[1],GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,0,NULL);
    if(writer!=INVALID_HANDLE_VALUE){CloseHandle(writer);return 3;}
    stream_buffer=malloc(WRITE_CHUNK);sink=_wfopen(argv[3],L"wb");
    if(!stream_buffer||!sink)return 4;
    Transfer t=send_stream(NULL,capture);
    if(t.error||t.acknowledged!=job_size||streamed_pages!=document_pages||t.uncertain)return 5;
    fclose(sink);sink=tmpfile();if(!sink)return 6;
    for(mode=1;mode<=3;mode++){
        if(!rewind_bundle())return 7;
        calls=0;ResetEvent(cancel_event);if(mode==3)SetEvent(cancel_event);
        t=send_stream(NULL,capture);
        if(mode==1&&(calls!=2||t.acknowledged!=997||!t.uncertain||!t.error))return 8;
        if(mode==2&&(calls!=1||t.acknowledged!=997||!t.uncertain||t.error!=ERROR_OPERATION_ABORTED))return 9;
        if(mode==3&&(calls||t.acknowledged||t.uncertain||t.attempted))return 10;
    }
    ResetEvent(cancel_event);SetEvent(cancel_event);
    if(validate_stream())return 11;
    fclose(sink);CloseHandle(cancel_event);CloseHandle(bundle_file);free(stream_buffer);
    printf("PASS streaming >10 pages/>40MiB, exclusive retained source, short writes, no replay on error, cancellation before and between writes, cancellation during validation\n");
    return 0;
}
