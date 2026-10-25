# Kakunou

Import the database package from the application with:

```odin
import db "shared:kakunou"
```

Open with `db.open(&database, path)` and close a successful handle with
`db.close(database)`. The caller owns successful connections.

Schema initialization uses Odin structs:

```odin
schema := db.Table_Schema {
    name = "events",
    columns = {
        {name = "id", data_type = .Integer, primary_key = true},
        {name = "title", data_type = .Text, not_null = true},
    },
}

err := db.create_table(database, schema)
if err.kind != .None do return err
```

`Column` supports `primary_key`, `not_null`, and `unique`. A column permits nulls
unless `not_null` or SQLite's primary-key rules prevent them. `Column_Type`
supports `.Integer`, `.Real`, `.Text`, `.Blob`, and `.Numeric`, with SQLite's usual
type affinity behavior. Table and column names are quoted and embedded quotes
escaped. Empty names, embedded NULs, empty column lists, and unknown types fail
before execution; SQLite validates the remaining SQL constraints.

`create_table` uses `IF NOT EXISTS` by default. Pass `if_not_exists = false` to
require a new table. Existing tables are left as they are; changing the struct
does not migrate them. SQL generation, execution, and allocation cleanup belong
to the kakunou package.

For other SQL without bound parameters or returned rows, use
`db.execute_sql(database, sql)`.

`begin_immediate` holds the connection lock until its owner calls
`commit_transaction` or `rollback_transaction`. A failed begin returns the
SQLite error and releases only the lock hold acquired by that call; it never
rolls back an existing transaction or retries implicitly. Nested transactions
are rejected, leaving the outer transaction and its pending changes intact.
Only finish a transaction after its begin succeeded. A failed commit rolls
back that transaction before releasing its lock hold.

Each connection uses its own SQLite-owned recursive mutex, obtained through
[`sqlite3_db_mutex`](https://www.sqlite.org/c3ref/db_mutex.html). Query helpers
hold it through preparation, binding, execution, decoding, and finalization;
transactions retain it until their owner commits or rolls back. Operations on
separate connections no longer share a package-global lock. SQLite's file-level
locking still applies when multiple connections access the same database file.

`open` requests `SQLITE_OPEN_FULLMUTEX` and rejects a connection if its mutex is
unavailable, closing and clearing the handle when cleanup succeeds. SQLite must
support [serialized connections](https://www.sqlite.org/threadsafe.html).
Connections opened through the low-level foreign API must also use FULLMUTEX.
The caller must finish all connection users before closing its handle. SQLite
owns the mutex; kakunou does not allocate or free a separate lock.

`db.query_one` returns `(found: bool, err: Database_Error)`. It prepares one
statement, binds parameters, and steps once. Its
decode callback receives the statement and returns `Database_Error`. A missing
row is `found == false` with `err.kind == .None`. Like `query_many` and
`insert`, it returns failures as `Database_Error` without logging. Callers log
once at the application boundary with their operation context.

Prepare, bind, step, and decode failures retain their diagnostic codes and
message. Finalization always releases the statement. A finalization failure
returns `found == false`; it becomes the primary error if none exists, or is
recorded in `cleanup_code` if its code differs from the existing error. Ignore
the output value whenever an error is returned. Missing rows do not run the
decoder. Empty SQL and invalid arguments return an execution error.

Read columns with `column_int` and `column_text`. The optional forms return
`valid == false` for SQL NULL without an error. NULL and `""` stay distinct:
an empty string is valid text. The required forms return `.MISMATCH` for NULL.
`column_text` copies into the supplied allocator because `query_one` finalizes
the statement before returning. Readers return failures without logging. A nil
statement is `.MISUSE`. A column outside `0 ..< column_count` is `.RANGE`.
Other SQLite types follow the usual conversion.

`open`, `execute_sql`, and `create_table` return `Database_Error`, with
`.kind == .None` on success. `build_new_table_sql` returns `(cstring,
Database_Error)`; on success the caller owns that SQL and releases it with
`delete`. These helpers return failures without logging, allowing the application
to log once with `log_error(err, "Database initialization failed")`.

Errors distinguish opening, invalid schema, allocation, and execution failures.
They retain the original SQLite or allocator code. Message, database path, and
table name are copied into the error value, so they survive closing SQLite and
copying the error. Diagnostic text is bounded to 511, 1023, and 255 bytes
respectively. `error_text(err.message[:])` reads the stored message.
`cleanup_code` preserves a distinct SQLite cleanup failure, such as statement
finalization or connection closure, separately from the primary error.

On an open failure, `open` closes the failed SQLite handle and clears the
output pointer when cleanup succeeds. An existing nonempty output handle is
rejected and left with its owner.

## Development

Install this repository at `$(odin root)/shared/kakunou`. Projects can then
import `shared:kakunou` without additional collection flags. SQLite must be
installed as a system library. This repository has no Anotate dependency.

Run from this repository:

```sh
odin check . -no-entry-point -warnings-as-errors
odin test tests -define:ODIN_TEST_THREADS=4 -warnings-as-errors
```
