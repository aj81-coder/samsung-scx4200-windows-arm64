# General Preview 0.12.0 target acceptance — 15 October 2026

The user upgraded from 0.11.1 and confirms a three-page document printed
correctly. The initial uninstall refusal was resolved by quitting the tray app;
Stop printing alone leaves the host running. This supports documenting Quit
clearly and replacing the generic application tray icon with a printer icon.

Supplied diagnostic archive:
diagnostics-20261015-222756-409-d02bd1a4510144d98ae1b5cbacf6b506.zip
SHA256 35ba0771d6c1f6a1c1dcad8d37d7a5e357eeb29e853d837906c681cd62597d6e.
ZIP integrity passes. Private report: evidence/private/general-0.12.0-target/audit.json.

The new session reports 0.12.0-general-dev, one accepted/completed job and three
accepted/completed pages, 26,092,080 decoded bytes, no fixed document/session
page allowance, blocked=false and automatic_retry=false. Its bridge result
identifies ARM64, success=true and mock_transport=false. The ARM64 0.12.0 sender
reports all three page-data boundaries completed, 1,111,950 acknowledged USB
bytes in 69 writes, zero transfer error/timeouts/uncertainty, no replay, verified
hash, consumed inherited permit and exclusive printer access. Bridge and sender
hashes agree: db1a280c5363cd6a77319ac5ff5f521083b12ba04fe339935f8364f9f867e592.
The current host log identifies ARM64/general version with no stopped message.

Physical completeness comes from the user; USB acknowledgement alone is not
proof of sheets. The snapshot ends at JOB_COMPLETED, not a subsequent clean
shutdown. Earlier 0.11.1 sessions are retained history and are both now cleanly
stopped. This archive does not show a fresh-queue installation or a new-version
restart/cancellation/recovery test. Those scenarios must not be inferred.

The requested short changed-transport target check is accepted. No further
printing is required merely to repeat that check. Prior automated large-count,
failure and cancellation tests remain separately recorded. General publication
still requires owner approval and honest fresh-queue evidence limits.

The user's housekeeping observation is valid: the successful-job ring is in
process memory and does not bound history across starts. Framework logs rotate
per session, but new session folders, host logs and saved diagnostic archives
accumulate. The diagnostic ZIP excludes raw pages/bundles, so it cannot measure
the full data folder or prove that no large historical payload remains there.
Plan cross-session retention before wider deployment; preserve active/uncertain
work and do not instruct the user to delete the entire data folder.
