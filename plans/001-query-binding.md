# Stop queries on binding failure

Planned against `a06dfab` on 2026-11-25. P1, effort S, change risk low. Executor is the isolated Codex sqlite agent for its access to local Odin and Git verification. Fallback is the Codex CLI in the same worktree.

## Evidence and scope

query_many calls bind_parameters then immediately overwrites err with query_many_rows. A missing parameter currently reaches sqlite3_step. Limit edits to src/query.odin, tests/integration/query_many_test.odin. Preserve prior public behavior except for the defect described here. Use existing Odin error-return, allocation and test conventions from neighboring procedures.

## Implementation and verification

1. Check `git diff --stat a06dfab..HEAD` and inspect the named paths. Confirm the described code still exists.
2. Follow insert_statement’s early error handling but keep the common statement_finalize path. Extend the existing integration test to run a write-capable statement with mismatched parameter count and assert RANGE, nil rows, and unchanged table contents.
3. Run `task test PACKAGE=integration` with a dedicated `KAKUNOU_CHECK_DIR` in the executor worktree. Assert the new cases exercise the previously broken behavior; keep test sources under `tests/`.
4. Verify the combined changes with `task check` and `git diff --check`. The independent release and runner branches initially retain the known query binding failure until plan 001 joins the combined branch.

Commit the scoped change to the isolated review branch. Stop and report if fixing this requires changing an unrelated public contract. Keep the named regression cases when modifying this subsystem later.
