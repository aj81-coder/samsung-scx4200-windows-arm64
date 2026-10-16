// SPDX-License-Identifier: Apache-2.0
#include <cups/cups.h>
#include <cups/raster.h>
#include <stdio.h>
#include <windows.h>
#include <dbghelp.h>
static LONG WINAPI diagnose(EXCEPTION_POINTERS *e) {
  HMODULE module = NULL;
  GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                    (const char *)e->ExceptionRecord->ExceptionAddress, &module);
  fprintf(stderr,"Exception %08lx at module offset %llu\n",e->ExceptionRecord->ExceptionCode,
          (unsigned long long)((char *)e->ExceptionRecord->ExceptionAddress-(char *)module));
  char buffer[sizeof(SYMBOL_INFO)+MAX_SYM_NAME];
  SYMBOL_INFO *symbol=(SYMBOL_INFO *)buffer;
  DWORD64 displacement=0;
  SymInitialize(GetCurrentProcess(),NULL,TRUE);
  symbol->SizeOfStruct=sizeof(*symbol); symbol->MaxNameLen=MAX_SYM_NAME;
  if(SymFromAddr(GetCurrentProcess(),(DWORD64)e->ExceptionRecord->ExceptionAddress,&displacement,symbol))
    fprintf(stderr,"Symbol %s + %llu\n",symbol->Name,(unsigned long long)displacement);
  return EXCEPTION_CONTINUE_SEARCH;
}
int main(void) {
  AddVectoredExceptionHandler(1,diagnose);
  fprintf(stderr,"Constructing IPP request...\n");
  ipp_t *request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES);
  if (!request) return 1;
  ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL,
               "ipp://127.0.0.1:8631/ipp/print");
  if (!ippFindAttribute(request, "printer-uri", IPP_TAG_URI)) return 2;
  printf("CUPS IPP request construction passed; encoded size=%zu\n", ippLength(request));
  ippDelete(request);
  return 0;
}
