# Contributing

Please discuss substantial changes before implementation. A small, focused fix with a reproducible example is easier to review than unrelated cleanup. Report problems using SUPPORT.md. The project currently has no published repository; the workflow below applies once one exists.

Include the problem, changed behavior, tests run and material limitations in a pull request. Record the exact source/binary version. Use synthetic or explicitly shareable documents, never private target captures.

## Safety boundaries

- Test malformed input, cancellation, resource exhaustion and lifecycle transitions with the fake sender or explicit mock transport. A test must never silently fall back to production USB.
- Do not automatically retry an uncertain transfer, delete an interrupted-session lock or represent USB acknowledgement as physical page completion.
- Preserve queue identity/ownership and existing user printers. Installation tests must mock Windows registration unless a target acceptance explicitly authorizes real changes.
- Keep bounded memory, disk use, traversal and arithmetic checks even when removing artificial page-count limits. Housekeeping must preserve active/failed/uncertain/unknown state and recovery backups; filenames alone never authorize deletion. Test links, malformed metadata, access failures and cross-restart history with synthetic fixtures.
- Keep the renderer as a separate executable; do not casually link GPL-derived renderer code into Apache application components.
- Match claims to evidence. Cross-compiling ARM64 does not mean executing on ARM64; a correct decoded raster does not prove physical printing.

## Licences and provenance

Original application changes use Apache-2.0. Changes to GPL files retain their existing licence. Do not copy external source without recording its origin and compatible terms. Preserve per-file SPDX declarations and upstream notices. See LICENSING.md and the source package's PROVENANCE.md.

Submitting a patch does not transfer ownership. Identify third-party material and its licence explicitly. Do not introduce new dependency or licence assumptions as a silent build change.

## Checks

Follow BUILDING.md for the matching source version. Run the suites relevant to your change, record their results and explain any skips. New sender/bundle formats require matching independent validation, large-document/resource-bound checks and cancellation/failure coverage before hardware use. Do not repeat unrelated physical printer tests for comment-only or documentation changes.
