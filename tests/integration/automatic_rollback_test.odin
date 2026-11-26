package integration_tests

import "core:fmt"
import "core:os"
import "core:testing"
import db "shared:kakunou"

@(test)
rollback_after_sqlite_automatic_abort_consumes_ownership_without_second_rollback :: proc(
	t: ^testing.T,
) {
	automatic_rollback_case(t, false)
}

@(test)
commit_after_sqlite_automatic_abort_preserves_error_without_failed_cleanup :: proc(t: ^testing.T) {
	automatic_rollback_case(t, true)
}

automatic_rollback_case :: proc(t: ^testing.T, commit: bool) {
	database: ^db.SQLite_DB

	if !testing.expect_value(t, db.open(&database, ":memory:").kind, .None) {
		return
	}

	defer db.close(database)
	testing.expect_value(
		t,
		db.execute_sql(database, "CREATE TABLE items(id INTEGER PRIMARY KEY,title TEXT)").kind,
		.None,
	)

	if !testing.expect_value(t, db.begin_immediate(database).kind, .None) {
		return
	}

	owned := true

	defer if owned {
		db.rollback_transaction(database)
	}

	testing.expect_value(
		t,
		db.insert(database, "INSERT INTO items VALUES(1,'first')", nil).kind,
		.None,
	)
	error := db.insert(database, "INSERT OR ROLLBACK INTO items VALUES(1,'duplicate')", nil)
	testing.expect_value(t, error.sqlite_code, .CONSTRAINT)
	testing.expect_value(t, db.sqlite3_get_autocommit(database), i32(1))
	owned = false

	if commit {
		error = db.commit_transaction(database)
		testing.expect_value(t, error.kind, .Execution_Failed)
		testing.expect_value(t, error.cleanup_code, .OK)
	} else {
		db.rollback_transaction(database)
	}

	expect_transaction_mutex(t, database, .OK)
	test_database_count(t, database, "SELECT COUNT(*) FROM items", 0)

	if !testing.expect_value(t, db.begin_immediate(database).kind, .None) {
		return
	}

	owned = true
	error = db.insert(database, "INSERT INTO items VALUES(2,'second')", nil)
	testing.expect_value(t, error.kind, .None)
	owned = false
	testing.expect_value(t, db.commit_transaction(database).kind, .None)
	test_database_count(t, database, "SELECT COUNT(*) FROM items", 1)
}

@(test)
full_database_rolls_back_partial_transaction_and_accepts_later_write :: proc(t: ^testing.T) {
	directory, err := make_backup_fixture("kakunou-full-", context.temp_allocator)
	if !testing.expect_value(t, err, nil) do return
	defer testing.expect_value(t, os.remove_all(directory), nil)
	path := fmt.ctprintf("%s/limited.sqlite", directory)
	{
		database: ^db.SQLite_DB
		if !testing.expect_value(t, db.open(&database, path).kind, .None) do return
		defer testing.expect_value(t, db.sqlite3_close(database), .OK)
		setup :: "PRAGMA page_size=4096; CREATE TABLE items(value BLOB); " +
		         "INSERT INTO items VALUES(x'01'); PRAGMA max_page_count=4"
		if !testing.expect_value(t, db.execute_sql(database, setup).kind, .None) do return
		fill :: proc(c: ^db.SQLite_DB, _: bool) -> db.Database_Error {
			err := db.execute_sql(c, "INSERT INTO items VALUES(x'02')")
			if err.kind != .None do return err
			return db.execute_sql(c, "INSERT INTO items VALUES(zeroblob(1048576))")
		}
		result := db.with_transaction(database, true, fill)
		testing.expect_value(t, result.sqlite_code, .FULL)
		testing.expect_value(t, result.cleanup_code, .OK)
		testing.expect_value(t, db.sqlite3_get_autocommit(database), i32(1))
		testing.expect_value(t, db.execute_sql(database, "INSERT INTO items VALUES(x'03')").kind, .None)
	}
	reopened: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&reopened, path).kind, .None) do return
	defer testing.expect_value(t, db.sqlite3_close(reopened), .OK)
	test_database_count(t, reopened, "SELECT COUNT(*) FROM items", 2)
	test_database_count(t, reopened, "SELECT COUNT(DISTINCT value) FROM items WHERE value IN (x'01',x'03')", 2)
	test_database_count(t, reopened, "SELECT COUNT(*) FROM pragma_integrity_check WHERE integrity_check='ok'", 1)
}
