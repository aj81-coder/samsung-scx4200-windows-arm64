// SPDX-License-Identifier: GPL-2.0-only
// Standalone PGM-to-QPDL adapter. No PAPPL, USB, network or spooler linkage.
#include "request.h"
#include "page.h"
#include "band.h"
#include "bandplane.h"
#include "compress.h"
#include "qpdl.h"
#include <cstdio>
#include <cstring>
#include <cctype>
#include <new>
#include <vector>
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>
#include <cstdint>
#include <algorithm>
#include <string>

// Box-average the whole source page into a centered printable rectangle.
// Integer area weights include every source pixel, including all four edges.
// Called only when the original dithered page would lose top/left ink.
static void fit_margins(std::vector<unsigned char> &gray,unsigned w,unsigned h,
                        unsigned &dw,unsigned &dh,unsigned &ox,unsigned &oy) {
  dw=w-96;dh=(unsigned)((uint64_t)h*dw/w);
  if(dh>h-126){dh=h-126;dw=(unsigned)((uint64_t)w*dh/h);}
  ox=(w-dw)/2;oy=(h-dh)/2;
  std::vector<unsigned char> fitted((size_t)w*h,255);
  for(unsigned y=0;y<dh;y++) {
    const uint64_t top=(uint64_t)y*h,bottom=(uint64_t)(y+1)*h;
    for(unsigned x=0;x<dw;x++) {
      const uint64_t left=(uint64_t)x*w,right=(uint64_t)(x+1)*w;
      uint64_t total=0;
      for(unsigned sy=(unsigned)(top/dh);(uint64_t)sy*dh<bottom;sy++) {
        uint64_t wy=std::min(bottom,(uint64_t)(sy+1)*dh)-std::max(top,(uint64_t)sy*dh);
        for(unsigned sx=(unsigned)(left/dw);(uint64_t)sx*dw<right;sx++) {
          uint64_t wx=std::min(right,(uint64_t)(sx+1)*dw)-std::max(left,(uint64_t)sx*dw);
          total+=(uint64_t)gray[(size_t)sy*w+sx]*wx*wy;
        }
      }
      uint64_t area=(uint64_t)w*h;
      fitted[(size_t)(y+oy)*w+x+ox]=(unsigned char)((total+area/2)/area);
    }
  }
  gray.swap(fitted);
}

Printer::Printer() {
  _manufacturer=_model=_beginPJL=_endPJL=nullptr;
  _color=false; _qpdlVersion=1; _bandHeight=128;
  _specialBandWidth=false; _fixedBandWidth=false; _packetSize=0;
  _paperType=2; _paperSource=1;
  _paperWidth=_pageWidth=595; _paperHeight=_pageHeight=842;
  _unknownByte1=0; _unknownByte2=2; _unknownByte3=1;
  _hardMarginX=10.75; _hardMarginY=15;
}
Printer::~Printer() {}
Request::Request() {
  _ppd=nullptr; _username="SCX4200 test"; _jobname="1";
  _jobtitle="SCX4200 native USB test"; _copiesNr=1;
  _duplex=Simplex; _reverseDuplex=false;
}
Request::~Request() {}

// PGM tokens are bounded. Consume just the terminating whitespace (CRLF is
// one separator), never arbitrary whitespace from the binary pixel payload.
static bool token(FILE *f,char *out,size_t size) {
  int c; size_t used=0;
  do {
    c=fgetc(f);
    if(c=='#') { do { c=fgetc(f); } while(c!=EOF && c!='\n'); }
  } while(c!=EOF && isspace((unsigned char)c));
  if(c==EOF) return false;
  do {
    if(used+1>=size) return false;
    out[used++]=(char)c; c=fgetc(f);
  } while(c!=EOF && !isspace((unsigned char)c));
  if(c==EOF) return false;
  if(c=='\r') { int next=fgetc(f); if(next!='\n' && next!=EOF) ungetc(next,f); }
  out[used]=0; return true;
}

static int render(int argc,wchar_t **argv) {
  bool strict=argc==4 && !wcscmp(argv[3],L"--strict-margins");
  if(argc!=3 && !strict) { fputs("Usage: SCX4200-Render.exe input.pgm output.qpdl [--strict-margins]\n",stderr); return 64; }
  FILE *in=_wfopen(argv[1],L"rb");
  if(!in) { fputs("Cannot open input PGM.\n",stderr); return 2; }
  char magic[16],ws[16],hs[16],max[16];
  bool valid=token(in,magic,sizeof magic) && token(in,ws,sizeof ws) &&
             token(in,hs,sizeof hs) && token(in,max,sizeof max);
  if(!valid || strcmp(magic,"P5") || strcmp(ws,"2480") ||
     (strcmp(hs,"3507") && strcmp(hs,"3509")) || strcmp(max,"255")) {
    fclose(in); fputs("Requires P5 grayscale A4: 2480x3507 or 2480x3509, maxval255.\n",stderr); return 3;
  }
  const unsigned w=2480,h=3509,input_h=!strcmp(hs,"3507")?3507:3509;
  std::vector<unsigned char> gray(w*input_h);
  valid=fread(gray.data(),1,gray.size(),in)==gray.size() && fgetc(in)==EOF && !ferror(in);
  fclose(in);
  if(!valid) { fputs("PGM pixel length mismatch.\n",stderr); return 4; }
  const unsigned matrix[4][4]={{0,8,2,10},{12,4,14,6},{3,11,1,9},{15,7,13,5}};
  unsigned affected=0,dw=w,dh=input_h,ox=0,oy=0;
  for(unsigned y=0;y<input_h;y++) for(unsigned x=0;x<w;x++)
    if((x<48 || y<63) && gray[y*w+x]<matrix[y%4][x%4]*16+8)affected++;
  if(affected && strict) {
    fputs("Page has ink inside the hardware top/left margins; strict-size rendering refused.\n",stderr);return 5;
  }
  if(affected)fit_margins(gray,w,input_h,dw,dh,ox,oy);
  auto *raster=new unsigned char[w/8*h]();
  unsigned black=0;
  for(unsigned y=0;y<input_h;y++) for(unsigned x=0;x<w;x++) {
    if(gray[y*w+x] < matrix[y%4][x%4]*16+8) {
      if(x<48 || y<63) {
        delete[] raster;
        fputs("Internal margin placement check failed.\n",stderr); return 5;
      }
      raster[y*(w/8)+x/8] |= (unsigned char)(0x80u>>(x%8)); black++;
    }
  }
  Request request; Page page;
  page.setXResolution(300); page.setYResolution(300);
  page.setWidth(w); page.setHeight(h); page.setColorsNr(1);
  page.setPageNr(1); page.setCopiesNr(1); page.setCompression(0x0d);
  page.setPlaneBuffer(0,raster);
  if(!compressPage(request,&page)) { fputs("SpliX compression failed.\n",stderr); return 6; }
  for(auto *b=page.firstBand();b;b=b->sibling()) {
    if(b->planesNr()!=1 || (b->plane(0)->compression()!=0x0d && b->plane(0)->compression()!=0x0e)) {
      fputs("Page requires a compression fallback not yet enabled for this test.\n",stderr); return 7;
    }
  }
  int fd=_wopen(argv[2],_O_CREAT|_O_EXCL|_O_WRONLY|_O_BINARY,_S_IREAD|_S_IWRITE);
  if(fd<0) { fputs("Cannot create output (existing files are never replaced).\n",stderr); return 8; }
  std::wstring metadata_path=std::wstring(argv[2])+L".json";
  int metadata_fd=_wopen(metadata_path.c_str(),_O_CREAT|_O_EXCL|_O_WRONLY|_O_BINARY,_S_IREAD|_S_IWRITE);
  if(metadata_fd<0){_close(fd);_wunlink(argv[2]);fputs("Cannot create renderer report (existing files are never replaced).\n",stderr);return 8;}
  FILE *metadata=_fdopen(metadata_fd,"wb");
  if(!metadata){_close(metadata_fd);_close(fd);_wunlink(argv[2]);_wunlink(metadata_path.c_str());return 8;}
  bool ok=_dup2(fd,_fileno(stdout))==0;
  _close(fd);
  if(ok) {
    _setmode(_fileno(stdout),_O_BINARY);
    printf("\033%%-12345X@PJL SET USERNAME=\"SCX4200 test\"\n"
      "@PJL SET JOBNAME=\"SCX4200 native USB test\"\n"
      "@PJL SET JAMRECOVERY=OFF\n@PJL SET DUPLEX=OFF\n"
      "@PJL SET PAPERTYPE=NORMAL\n@PJL SET ALTITUDE=LOW\n"
      "@PJL SET DENSITY=3\n@PJL SET RET=NORMAL\n"
      "@PJL ENTER LANGUAGE = QPDL\n");
    ok=fflush(stdout)==0 && renderPage(request,&page,true);
    if(ok) printf("\t\033%%-12345X");
    ok=!ferror(stdout) && ok;
    if(fclose(stdout)!=0) ok=false;
  }
  bool report_ok=fprintf(metadata,"{\"renderer_version\":\"0.9.2\",\"fit_applied\":%s,\"margin_ink_pixels\":%u,\"source_width\":%u,\"source_height\":%u,\"fitted_width\":%u,\"fitted_height\":%u,\"offset_x\":%u,\"offset_y\":%u,\"black_pixels\":%u}\n",affected?"true":"false",affected,w,input_h,dw,dh,ox,oy,black)>0;
  if(fclose(metadata)!=0)report_ok=false;
  if(!ok || !report_ok) { _wunlink(argv[2]);_wunlink(metadata_path.c_str()); fputs("Could not finish QPDL file/report.\n",stderr); return 9; }
  if(affected)fprintf(stderr,"Fitted page inside hardware margins: %ux%u to %ux%u at (%u,%u). No source edge was cropped.\n",w,input_h,dw,dh,ox,oy);
  fprintf(stderr,"Rendered one A4 page at 300dpi; %u black pixels. No printing performed.\n",black);
  return 0;
}
int wmain(int argc,wchar_t **argv) {
  try { return render(argc,argv); }
  catch(const std::bad_alloc &) { fputs("Insufficient memory to render page.\n",stderr); return 10; }
}
