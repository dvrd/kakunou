# Audit fixes

Baseline `a06dfab`. The SQLite, release and runner groups execute independently. Review 001 first to restore the combined test baseline. Plans 002–003 share a disposable Git fixture, and 005 and 009 share selector and inventory verification.

| Plan | Review branch | Executor | Status |
|---|---|---|---|
| [001 Stop queries on binding failure](001-query-binding.md) | advisor/sqlite-audit | Codex | Verified on develop |
| [002 Require full verification for release](002-full-release-gate.md) | advisor/release-audit | Codex | Verified on develop |
| [003 Preserve user edits during release recovery](003-release-recovery.md) | advisor/release-audit | Codex | Verified on develop |
| [004 Use one filesystem path for backup reservation and SQLite](004-literal-backup-path.md) | advisor/sqlite-audit | Codex | Verified on develop |
| [005 Reject unmatched explicit test names](005-test-selectors.md) | advisor/check-audit | Codex | Verified on develop |
| [006 Resolve the library independently of the checkout name](006-checkout-portability.md) | advisor/check-audit | Codex | Verified on develop |
| [007 Match SQLite block comment boundaries](007-sqlite-tail.md) | advisor/sqlite-audit | Codex | Verified on develop |
| [008 Test retry behavior with a short deadline](008-backup-retries.md) | advisor/sqlite-audit | Codex | Verified on develop |
| [009 Report test progress honestly for conditional suites](009-conditional-inventory.md) | advisor/check-audit | Codex | Verified on develop |
| [010 Verify PRs and release main automatically](010-release-workflow.md) | advisor/release-workflow | Codex | Implemented on develop |
