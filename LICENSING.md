# Component licence boundaries

The project owner selected Apache License 2.0 for genuinely original project code. This is a mixed-licence distribution: that choice does not relicense third-party components or existing GPL files.

| Component | Treatment |
| --- | --- |
| Original bridge, background host, USB sender and local control/build code | Apache-2.0 where declared in the source. |
| SpliX-derived standalone renderer and existing GPL-labelled verification/fixture code | Existing GPL-2.0-only declarations remain. Provide matching source and the applicable full terms with distribution. |
| CUPS and PAPPL | Retain upstream Apache-2.0 notices and applicable upstream additions/exceptions; consult the supplied full texts. |
| zlib | Retain its upstream licence. |
| Compiler runtime, libc++, libc++abi, libunwind and other shipped runtime portions | Retain the complete component notices supplied with the exact build. |

The source package's per-file declarations, PROVENANCE.md, component mapping and full LICENSES notices provide the detailed record. A root Apache licence alone is insufficient for the combined package. No third-party source should be altered merely to make all files share one label.

Each binary release must include a matching source bundle with build scripts, pinned upstream archives or a verified acquisition route, modifications and required licence texts. Preserve copyright notices; do not invent an owner or remove upstream attribution. Keep the separate renderer boundary explicit in code and documentation.

These documents record the project's licensing choices and provenance evidence; they do not claim Samsung/HP endorsement or a legal clearance of every possible use. Names identify compatibility only. Any later evidence of additional third-party source must be reflected before distribution.
