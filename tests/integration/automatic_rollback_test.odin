package integration_tests

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
