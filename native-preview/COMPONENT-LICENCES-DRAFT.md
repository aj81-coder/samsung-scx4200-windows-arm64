# Component licence inventory — release draft

This records declarations and supplied notices. It is not a blanket licence
grant for files without a declaration, or a conclusion that every release
requirement has been satisfied. The project owner chose Apache2.0 for genuinely
original project code on 14 October 2026. The mapping and its evidence are
recorded in PROVENANCE.md. This remains a release draft pending distribution
acceptance and approval to publish.

| Component | Declaration or supplied terms | Evidence / distribution files |
|---|---|---|
| Native IPP bridge | Apache-2.0 in `native-async-bridge/bridge.c`; owner confirmed original-code choice | Full original-code licence text in project LICENSE-APACHE-2.0.txt; PAPPL/CUPS notices remain separate |
| Standalone renderer and independent pixel verifier | GPL-2.0-only in their source headers | `SPLIX-COPYING.txt`, full corresponding source, pinned upstream archive and build instructions |
| SpliX algorithms | Upstream GPL2 text | Included `reference-job/upstream/splix-source.zip` and renderer build inputs |
| CUPS and PAPPL | Included Apache2 licence/notice texts | `CUPS-LICENSE.txt`, `CUPS-NOTICE.txt`, `PAPPL-LICENSE.txt`, `PAPPL-NOTICE.txt` |
| zlib | Included upstream zlib licence text | `zlib-LICENSE.txt`, pinned source archive |
| Windows regex code in CUPS build | Included upstream copyright/terms | `Regex-COPYRIGHT.txt`, source in pinned CUPS archive |
| MinGW runtime | Included runtime notices | `MinGW-runtime-LICENSE.txt`; compiler generates the Windows CRT linkage |
| Zig toolchain | Toolchain's MIT text | `Zig-LICENSE.txt`; compiler archive pin is in the build recipe |
| libc++, libc++abi, libunwind | Bundled LLVM runtime licence texts, including LLVM exception and legacy notices | `libcxx-LICENSE.txt`, `libcxxabi-LICENSE.txt`, `libunwind-LICENSE.txt`, copied verbatim from pinned Zig0.15.2; the isolated compiler cache contains all three runtime archives |
| USB sender, USB helpers, local C QPDL validator, and original control/build/test scripts | Apache-2.0 per-file declarations | PROVENANCE.md records local lineage and the validator qualification; existing GPL Python declarations remain unchanged |

The renderer is a separate executable exchanging ordinary PGM/QPDL files with
the bridge. Preserve its source/build materials and the separate component
declarations. Do not overwrite third-party notices or relabel derived renderer
code under a proposed general project licence.

The historical 0.10.0 inventory found 20 files with declarations and 61 without.
The subsequent mapping covered current preparation tools as well: 68 original
files received comment-only Apache declarations, with one further legacy
packaging script identified and verified in the final audit. 20 existing declarations
were preserved. The private audit records exact before/after hashes. This
does not replace upstream terms or assert a reconstructed authoring history.

Prepared additions correct runtime-notice coverage; original0.10.0archives stay
unchanged as historical artifacts. Include these texts and this component map
inside the next source package as well as beside its binaries. Public repository
creation/upload remain unapproved. The original-code licence choice is now
approved and file-level mapping is complete; final distribution acceptance
and publication approval remain.
