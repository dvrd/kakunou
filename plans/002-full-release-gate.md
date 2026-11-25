# Require full verification for release

Planned against `a06dfab` on 2026-11-25. P1, effort S, change risk low. Executor is the isolated Codex release agent for its access to local Odin and Git verification. Fallback is the Codex CLI in the same worktree.

## Evidence and scope

release calls task check with its caller’s environment. PACKAGE=unit selects only the eight unit tests. Limit edits to tools/version, release-related tests under tests/integration. Preserve prior public behavior except for the defect described here. Use existing Odin error-return, allocation and test conventions from neighboring procedures.

## Implementation and verification

1. Check `git diff --stat a06dfab..HEAD` and inspect the named paths. Confirm the described code still exists.
2. Clear or explicitly override suite-selection inputs for the release child process. Preserve dependency and compiler configuration. Add a disposable Git fixture recording child arguments and environment, with filtered input and a failing check. Verify failure creates no release ref.
3. Run `task test PACKAGE=integration` with a dedicated `KAKUNOU_CHECK_DIR` in the executor worktree. Assert the new cases exercise the previously broken behavior; keep test sources under `tests/`.
4. Verify the combined changes with `task check` and `git diff --check`. The independent release and runner branches initially retain the known query binding failure until plan 001 joins the combined branch.

Commit the scoped change to the isolated review branch. Stop and report if fixing this requires changing an unrelated public contract. Keep the named regression cases when modifying this subsystem later.
