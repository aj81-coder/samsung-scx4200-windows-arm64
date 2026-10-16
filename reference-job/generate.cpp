// SPDX-License-Identifier: GPL-2.0-only
// Fixed SCX-4200 fixture adapter. Compression and serialization are upstream SpliX.
#include "request.h"
#include "page.h"
#include "band.h"
#include "bandplane.h"
#include "compress.h"
#include "qpdl.h"
#include <cstdio>
#include <fcntl.h>
#include <io.h>

// Values from upstream ppd/scx4200.ppd, interpreted as in src/printer.cpp.
// No CUPS parser, system configuration, USB access or printer discovery here.
Printer::Printer() {
    _manufacturer = _model = _beginPJL = _endPJL = nullptr;
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

int main(int argc, char **argv) {
    if(argc!=3) { std::fprintf(stderr,"Usage: generate.exe page.raw test-page.qpdl\n"); return 2; }
    constexpr unsigned long width=2480, height=3509, size=width/8*height;
    FILE *in=std::fopen(argv[1],"rb");
    if(!in) return 3;
    auto *raster=new unsigned char[size];
    bool valid=std::fread(raster,1,size,in)==size && std::fgetc(in)==EOF;
    std::fclose(in);
    if(!valid) { delete[] raster; return 4; }
    Request request; Page page;
    page.setXResolution(300); page.setYResolution(300);
    page.setWidth(width); page.setHeight(height); page.setColorsNr(1);
    page.setPageNr(1); page.setCopiesNr(1); page.setCompression(0x0d);
    page.setPlaneBuffer(0,raster);
    if(!compressPage(request,&page)) return 5;
    // A deliberately sparse fixture must encode entirely as 0x0D. Fail closed
    // if the fallback algorithm was selected, since our independent decoder
    // validates 0x0D only.
    for(auto *b=page.firstBand(); b; b=b->sibling()) {
        if(b->planesNr()!=1 || b->plane(0)->compression()!=0x0d) return 6;
    }
    if(!std::freopen(argv[2],"wb",stdout)) return 7;
    _setmode(_fileno(stdout),_O_BINARY);
    // Adapted from upstream Printer::sendPJLHeader, retaining job-scoped
    // options only. DEFAULT service date/power saving changes are omitted.
    std::printf("\033%%-12345X@PJL SET USERNAME=\"SCX4200 test\"\n"
        "@PJL SET JOBNAME=\"SCX4200 native USB test\"\n"
        "@PJL SET JAMRECOVERY=OFF\n@PJL SET DUPLEX=OFF\n"
        "@PJL SET PAPERTYPE=NORMAL\n@PJL SET ALTITUDE=LOW\n"
        "@PJL SET DENSITY=3\n@PJL SET RET=NORMAL\n"
        "@PJL ENTER LANGUAGE = QPDL\n");
    if(std::fflush(stdout)) return 8;
    if(!renderPage(request,&page,true)) return 9;
    std::printf("\t\033%%-12345X");
    return std::fclose(stdout)==0 ? 0 : 10;
}
