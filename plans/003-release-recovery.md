# Preserve user edits during release recovery

Planned against `a06dfab` on 2026-11-25. P1, effort M, change risk medium. Executor is the isolated Codex release agent for its access to local Odin and Git verification. Fallback is the Codex CLI in the same worktree.

## Evidence and scope

release restores src/version.odin from HEAD even when it notices a concurrent content change. The checkout is dirty if the process stops during verification. Limit edits to tools/version, release-related tests under tests/integration. Preserve prior public behavior except for the defect described here. Use existing Odin error-return, allocation and test conventions from neighboring procedures.

## Implementation and verification

1. Check `git diff --stat a06dfab..HEAD` and inspect the named paths. Confirm the described code still exists.
2. Prefer checking the proposed release in isolation. Recheck the original branch, HEAD and contents before finalizing; preserve unrelated edits on failure. Retain retries after a release commit is created but tagging fails. Exercise failed checks, edits during a check, interruption and annotated-tag retry using disposable repositories.
3. Run `task test PACKAGE=integration` with a dedicated `KAKUNOU_CHECK_DIR` in the executor worktree. Assert the new cases exercise the previously broken behavior; keep test sources under `tests/`.
4. Verify the combined changes with `task check` and `git diff --check`. The independent release and runner branches initially retain the known query binding failure until plan 001 joins the combined branch.

Commit the scoped change to the isolated review branch. Stop and report if fixing this requires changing an unrelated public contract. Keep the named regression cases when modifying this subsystem later.
