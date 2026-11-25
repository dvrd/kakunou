# Resolve the library independently of the checkout name

Planned against `a06dfab` on 2026-11-25. P2, effort M, change risk low. Executor is the isolated Codex check agent for its access to local Odin and Git verification. Fallback is the Codex CLI in the same worktree.

## Evidence and scope

suites derives its local collection alias from the Git directory; tests import shared:kakunou. check rejects a missing external collection even when the library is the only shared import. Limit edits to tools/check, README.md, runner regression tests under tests/. Preserve prior public behavior except for the defect described here. Use existing Odin error-return, allocation and test conventions from neighboring procedures.

## Implementation and verification

1. Check `git diff --stat a06dfab..HEAD` and inspect the named paths. Confirm the described code still exists.
2. Bind shared:kakunou directly to the staged src tree. Validate external imports only as needed. Document Odin, SQLite, Git and Task prerequisites and suite commands. Test from a renamed checkout with no external collection; ensure genuinely missing dependencies still fail.
3. Run `task test PACKAGE=unit` with a dedicated `KAKUNOU_CHECK_DIR` in the executor worktree. Assert the new cases exercise the previously broken behavior; keep test sources under `tests/`.
4. Verify the combined changes with `task check` and `git diff --check`. The independent release and runner branches initially retain the known query binding failure until plan 001 joins the combined branch.

Commit the scoped change to the isolated review branch. Stop and report if fixing this requires changing an unrelated public contract. Keep the named regression cases when modifying this subsystem later.
