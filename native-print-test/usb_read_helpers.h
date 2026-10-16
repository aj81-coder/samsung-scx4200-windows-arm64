// SPDX-License-Identifier: Apache-2.0
/* Read/query helpers copied from the locally reviewed diagnostic 0.1.0. */
#ifndef SCX_USB_READ_HELPERS_H
#define SCX_USB_READ_HELPERS_H
/* Read/query helpers: no print, reset, set or vendor requests here.
 * Uses only Microsoft USBPRINT GET_1284_ID and GET_LPT_STATUS.
 * The sender separately controls write access and its confirmation gate.
 */
#ifndef UNICODE
#define UNICODE 1
#endif
#ifndef _UNICODE
#define _UNICODE 1
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0a00
#endif
#include <windows.h>
#include <setupapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <stddef.h>

#define VERSION "0.1.0"
#define MAX_DEVICES 16
#define ID_CAPACITY 4094
#define QUERY_TIMEOUT 5000
#define GET_STATUS CTL_CODE(FILE_DEVICE_UNKNOWN, 12, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define GET_ID CTL_CODE(FILE_DEVICE_UNKNOWN, 13, METHOD_BUFFERED, FILE_ANY_ACCESS)
static const GUID usbprint_guid = {0x28d78fad,0x5a12,0x11d1,{0xae,0x5b,0x00,0x00,0xf8,0x03,0xa8,0xc2}};

typedef struct {
    BOOL attempted, ok, timed_out, cancellation_pending;
    DWORD error, bytes;
    unsigned char data[ID_CAPACITY];
} Query;
typedef struct {
    BOOL opened;
    DWORD read_open_error, zero_open_error;
    const char *access;
    Query id, status;
} Device;
typedef struct {
    OVERLAPPED ov;
    unsigned char data[ID_CAPACITY];
} Pending;
typedef struct {
    char manufacturer[512], model[512], commands[512];
} Identity;

static BOOL target_instance(const wchar_t *id) {
    const wchar_t *prefix=L"USB\\VID_04E8&PID_341B&MI_01\\";
    return _wcsnicmp(id,prefix,wcslen(prefix))==0;
}

/* Only retain known non-serial fields; never log raw device paths or ID strings. */
static void parse_identity(const unsigned char *data, DWORD bytes, Identity *id) {
    memset(id,0,sizeof(*id));
    if(bytes < 2 || bytes > ID_CAPACITY) return;
    size_t pos=2;
    while(pos < bytes && data[pos]) {
        size_t start=pos;
        while(pos < bytes && data[pos] && data[pos]!=';') pos++;
        size_t end=pos, colon=start;
        while(colon < end && data[colon]!=':') colon++;
        if(colon < end) {
            char key[32]={0};
            size_t n=colon-start;
            if(n < sizeof(key)) {
                memcpy(key,data+start,n);
                char *dest=NULL;
                if(!_stricmp(key,"MFG") || !_stricmp(key,"MANUFACTURER")) dest=id->manufacturer;
                if(!_stricmp(key,"MDL") || !_stricmp(key,"MODEL")) dest=id->model;
                if(!_stricmp(key,"CMD") || !_stricmp(key,"COMMAND SET")) dest=id->commands;
                if(dest) {
                    size_t len=end-colon-1;
                    if(len>511) len=511;
                    memcpy(dest,data+colon+1,len); dest[len]=0;
                }
            }
        }
        if(pos < bytes && data[pos]==';') pos++;
    }
}

static void json_string(FILE *out,const char *s) {
    fputc('"',out);
    for(const unsigned char *p=(const unsigned char *)s; *p; p++) {
        if(*p=='"' || *p=='\\') {fputc('\\',out); fputc(*p,out);}
        else if(*p<32 || *p>=127) fprintf(out,"\\u%04x",(unsigned)*p);
        else fputc(*p,out);
    }
    fputc('"',out);
}

static void query_device(HANDLE h,DWORD code,DWORD capacity,Query *q) {
    memset(q,0,sizeof(*q)); q->attempted=TRUE;
    /* Keep OVERLAPPED and output memory alive if a driver fails to cancel. */
    Pending *p=(Pending *)calloc(1,sizeof(*p));
    if(!p) {q->error=ERROR_NOT_ENOUGH_MEMORY; return;}
    p->ov.hEvent=CreateEventW(NULL,TRUE,FALSE,NULL);
    if(!p->ov.hEvent) {q->error=GetLastError(); free(p); return;}
    DWORD bytes=0;
    BOOL ok=DeviceIoControl(h,code,NULL,0,p->data,capacity,&bytes,&p->ov);
    DWORD error=ok ? ERROR_SUCCESS : GetLastError();
    if(ok) {
        ok=GetOverlappedResult(h,&p->ov,&bytes,FALSE);
        error=ok ? ERROR_SUCCESS : GetLastError();
    }
    if(!ok && error==ERROR_IO_PENDING) {
        DWORD wait=WaitForSingleObject(p->ov.hEvent,QUERY_TIMEOUT);
        if(wait==WAIT_OBJECT_0) {
            ok=GetOverlappedResult(h,&p->ov,&bytes,FALSE);
            error=ok ? ERROR_SUCCESS : GetLastError();
        } else {
            q->timed_out=(wait==WAIT_TIMEOUT);
            error=q->timed_out ? ERROR_TIMEOUT : GetLastError();
            CancelIoEx(h,&p->ov);
            if(WaitForSingleObject(p->ov.hEvent,2000)!=WAIT_OBJECT_0) {
                q->cancellation_pending=TRUE;
                q->error=error;
                /* Intentional retained allocation/event until process exit.
                 * Freeing them could let outstanding kernel I/O corrupt memory. */
                return;
            }
            ok=FALSE;
        }
    }
    if(ok && bytes>capacity) {ok=FALSE; error=ERROR_INVALID_DATA;}
    q->ok=ok; q->error=error; q->bytes=ok ? bytes : 0;
    if(ok) memcpy(q->data,p->data,bytes);
    CloseHandle(p->ov.hEvent); free(p);
}

static void print_query(FILE *out,const Query *q,BOOL identity) {
    fprintf(out,"{\"attempted\":%s,\"success\":%s,\"win32_error\":%lu,\"bytes_returned\":%lu,\"timed_out\":%s,\"cancellation_pending\":%s",
        q->attempted?"true":"false",q->ok?"true":"false",(unsigned long)q->error,
        (unsigned long)q->bytes,q->timed_out?"true":"false",q->cancellation_pending?"true":"false");
    if(identity && q->ok) {
        Identity id; parse_identity(q->data,q->bytes,&id);
        fprintf(out,",\"manufacturer\":"); json_string(out,id.manufacturer);
        fprintf(out,",\"model\":"); json_string(out,id.model);
        fprintf(out,",\"commands\":"); json_string(out,id.commands);
        fprintf(out,",\"length_prefix_bytes\":[%u,%u]",q->bytes>0?q->data[0]:0,q->bytes>1?q->data[1]:0);
    } else if(!identity && q->ok && q->bytes>=1) {
        fprintf(out,",\"status_byte\":%u",q->data[0]);
    }
    fputc('}',out);
}

static const char *build_arch(void) {
#if defined(__aarch64__) || defined(_M_ARM64)
    return "ARM64";
#elif defined(__x86_64__) || defined(_M_X64)
    return "x64";
#else
    return "other";
#endif
}


#endif
