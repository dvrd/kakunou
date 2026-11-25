# Match SQLite block comment boundaries

Planned against `a06dfab` on 2026-11-25. P2, effort S, change risk medium. Executor is the isolated Codex sqlite agent for its access to local Odin and Git verification. Fallback is the Codex CLI in the same worktree.

## Evidence and scope

skip_sql_block_comment counts nested delimiters. An existing test treats trailing tokens following the first closing delimiter as comment text. Limit edits to src/sqlite.odin, tests/integration/query_many_test.odin. Preserve prior public behavior except for the defect described here. Use existing Odin error-return, allocation and test conventions from neighboring procedures.

## Implementation and verification

1. Check `git diff --stat a06dfab..HEAD` and inspect the named paths. Confirm the described code still exists.
2. End a block comment at the first closing delimiter. Match SQLite whitespace while retaining the deliberate rejection of unterminated trailing comments. Update the established integration tests with positive trivia cases and assert an invalid tail prevents the first write.
3. Run `task test PACKAGE=integration` with a dedicated `KAKUNOU_CHECK_DIR` in the executor worktree. Assert the new cases exercise the previously broken behavior; keep test sources under `tests/`.
4. Verify the combined changes with `task check` and `git diff --check`. The independent release and runner branches initially retain the known query binding failure until plan 001 joins the combined branch.

Commit the scoped change to the isolated review branch. Stop and report if fixing this requires changing an unrelated public contract. Keep the named regression cases when modifying this subsystem later.
