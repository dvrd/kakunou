# Test retry behavior with a short deadline

Planned against `a06dfab` on 2026-11-25. P2, effort M, change risk medium. Executor is the isolated Codex sqlite agent for its access to local Odin and Git verification. Fallback is the Codex CLI in the same worktree.

## Evidence and scope

backup_copy uses a fixed ten-second budget. The existing timeout test asserts only an upper time bound. Limit edits to src/schema.odin, tests/integration/backup_test.odin. Preserve prior public behavior except for the defect described here. Use existing Odin error-return, allocation and test conventions from neighboring procedures.

## Implementation and verification

1. Check `git diff --stat a06dfab..HEAD` and inspect the named paths. Confirm the described code still exists.
2. Introduce a scoped short-budget path or deterministic retry seam; keep ordinary callers’ default ten-second contract. Prove at least one retry occurs before expiration and retain assertions for destination cleanup and source transaction state.
3. Run `task test PACKAGE=integration` with a dedicated `KAKUNOU_CHECK_DIR` in the executor worktree. Assert the new cases exercise the previously broken behavior; keep test sources under `tests/`.
4. Verify the combined changes with `task check` and `git diff --check`. The independent release and runner branches initially retain the known query binding failure until plan 001 joins the combined branch.

Commit the scoped change to the isolated review branch. Stop and report if fixing this requires changing an unrelated public contract. Keep the named regression cases when modifying this subsystem later.
