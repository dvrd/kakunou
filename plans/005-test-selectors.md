# Reject unmatched explicit test names

Planned against `a06dfab` on 2026-11-25. P1, effort M, change risk medium. Executor is the isolated Codex check agent for its access to local Odin and Git verification. Fallback is the Codex CLI in the same worktree.

## Evidence and scope

suite_test_names drops unmatched selectors and the driver accepts Odin’s zero exit when zero tests run. Limit edits to tools/check, runner regression tests under tests/. Preserve prior public behavior except for the defect described here. Use existing Odin error-return, allocation and test conventions from neighboring procedures.

## Implementation and verification

1. Check `git diff --stat a06dfab..HEAD` and inspect the named paths. Confirm the described code still exists.
2. Track explicit selectors across all selected packages. A valid name belonging to a later package must pass; a typo alone or mixed with a valid name must fail. Use runtime evidence for conditional declarations where a static list is incomplete. Exercise the normal task or runner entry point.
3. Run `task test PACKAGE=unit` with a dedicated `KAKUNOU_CHECK_DIR` in the executor worktree. Assert the new cases exercise the previously broken behavior; keep test sources under `tests/`.
4. Verify the combined changes with `task check` and `git diff --check`. The independent release and runner branches initially retain the known query binding failure until plan 001 joins the combined branch.

Commit the scoped change to the isolated review branch. Stop and report if fixing this requires changing an unrelated public contract. Keep the named regression cases when modifying this subsystem later.
