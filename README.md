# Kakunou

Kakunou is an Odin library for SQLite. It links against the system SQLite 3 library.

## Build and test

The development tasks use Odin, Task v3, Git, and POSIX process utilities. Install the SQLite development library for your platform so the linker can resolve `sqlite3`.

```sh
task check                 # Type-check, build, and run all suites
task test PACKAGE=unit
task test PACKAGE=integration
task test -- -define:ODIN_TEST_NAMES=unit_tests.library_version_is_a_release_tag
task version
task build CHECK_DIR=/path/to/output  # Keep the compiled binaries
```

The runner maps `shared:kakunou` to this checkout’s `src/` directory. The current library and tests need no external shared collection. For additional `shared:` imports, set `SHARED=/path/to/collection` on the task or set `WEBTOOLS_SHARED` in the environment. Use `ODIN=/path/to/odin` to select a compiler.

## Writes with RETURNING

A `query_many` error describes the result of reading rows. In autocommit mode, SQLite can apply the write before the decoder, allocator, or row-limit check fails. For example, inserting two rows with `RETURNING id` and `max_rows = 1` can return `.TOOBIG` with both rows already inserted. Retrying that insert can duplicate the write.

Wrap the write and readback in one transaction when both must succeed. This example assumes an open connection and an `items(id INTEGER PRIMARY KEY, title TEXT)` table.

```odin
import db "shared:kakunou"

insert_pair :: proc(database: ^db.SQLite_DB, limit: int) -> db.Database_Error {
    decode_id :: proc(statement: ^db.SQLite_Statement, id: ^i64) -> db.Database_Error {
        value, err := db.column_int(statement, 0)
        if err.kind == .None {
            id^ = value
        }
        return err
    }

    err := db.begin_immediate(database)
    if err.kind != .None {
        return err
    }

    _, err = db.query_many(database,
        "INSERT INTO items(id, title) VALUES (1, 'first'), (2, 'second') RETURNING id",
        nil, decode_id, limit)
    if err.kind != .None {
        db.rollback_transaction(database)
        return err
    }
    return db.commit_transaction(database)
}
```

Keep the successful begin and its matching commit or rollback on the same thread. Each consumes the transaction exactly once. A failed commit handles rollback internally and releases the connection mutex. With a fresh table, the example rolls back both rows for a limit of one and commits both for a limit of two. Returned rows borrow the caller’s temporary allocator. [Transaction regression](tests/integration/query_many_test.odin)

## Publishing and restoring backups

Filesystem backup is implemented for Linux, macOS, FreeBSD, OpenBSD, and NetBSD. Choose a destination directory owned by the backup process’s effective user, with group and other write permissions disabled. Its ancestors and filesystem ACLs must prevent untrusted users from replacing the directory or changing its entries. Use a filesystem that supports hard links. On platforms without the POSIX staging primitives, filesystem backups return `.Open_Failed`; the connection-based `backup_copy` remains available. The library copies into a private directory and links the completed mode-0600 snapshot to the requested name. An existing destination causes the backup to fail.

A single publisher can maintain a last-known-good snapshot with this sequence:

1. Give each attempt a fresh staging filename in the same directory as `latest.sqlite`. Call `backup_file` with the staging path. A killed process can leave a private `.kakunou-backup-*` directory. Remove abandoned directories only after confirming their workers have exited.
2. After `backup_file` succeeds, use `os.rename(staging, published)` to atomically replace `latest.sqlite`. Check the rename result. Reserve the published file for copying and open a separate restored copy for use. Keep the live database and its WAL files at a different path.
3. To restore, copy `latest.sqlite` to a fresh database path. Open the copy, require `PRAGMA integrity_check` to return `ok`, and verify an application-level invariant before switching traffic. Ignore staging files during restore.

The recovery test kills a backup worker while a separate connection holds a write transaction, then opens a restored copy and checks its integrity, row count, and sum of IDs. Repeat the drill with your production database size, journal mode, and write rate. This drill covers process termination. Power-loss durability also depends on filesystem and storage flush guarantees. [Recovery rehearsal](tests/integration/backup_recovery_test.odin)

## Preparing a release

Commit your changes on `develop`, fetch and merge `origin/main`, then run `task version:prepare`. It derives the version from the literal on `origin/main` and the Conventional Commits introduced by the PR. Commit the updated `src/version.odin` before opening or updating the PR to `main`. Use a merge commit to preserve the reviewed history.

The required `check` verifies the literal and runs all suites. After merge, CI repeats both checks on the exact merged commit. A fresh runner creates the annotated tag and GitHub release when the version increases. For a failed publication, rerun the original Actions run. Its tag identifies both the checked commit and the run. Documentation-only merges keep the current version and finish after verification.
