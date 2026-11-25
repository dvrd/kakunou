# Report test progress honestly for conditional suites

Planned against `a06dfab` on 2026-11-25. P2, effort M, change risk medium. Executor is the isolated Codex check agent for its access to local Odin and Git verification. Fallback is the Codex CLI in the same worktree.

## Evidence and scope

suite_test_names walks top-level AST declarations irrespective of filename target selection; nested when statements are omitted. Odin schedules tests from compiled declarations. Limit edits to tools/check, runner regression tests under tests/. Preserve prior public behavior except for the defect described here. Use existing Odin error-return, allocation and test conventions from neighboring procedures.

## Implementation and verification

1. Check `git diff --stat a06dfab..HEAD` and inspect the named paths. Confirm the described code still exists.
2. Prefer compiler-selected test information. Where unavailable, mark an incomplete inventory explicitly and derive actual starts and completions from Odin events. Do not display excluded cases as pending or reject valid conditional tests. Include a build-tagged source, platform-specific filename and conditional declaration in test coverage.
3. Run `task test PACKAGE=unit` with a dedicated `KAKUNOU_CHECK_DIR` in the executor worktree. Assert the new cases exercise the previously broken behavior; keep test sources under `tests/`.
4. Verify the combined changes with `task check` and `git diff --check`. The independent release and runner branches initially retain the known query binding failure until plan 001 joins the combined branch.

Commit the scoped change to the isolated review branch. Stop and report if fixing this requires changing an unrelated public contract. Keep the named regression cases when modifying this subsystem later.
