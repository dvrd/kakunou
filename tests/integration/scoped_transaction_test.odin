package integration_tests

import "core:testing"
import db "shared:kakunou"

@(test)
scoped_transaction_commits_or_rolls_back_the_callback :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready do return
	defer db.close(database)

	write :: proc(database: ^db.SQLite_DB, fail: bool) -> db.Database_Error {
		err := db.insert(database, "INSERT INTO items(title) VALUES ('saved')", nil)
		if err.kind != .None do return err
		if fail do return db.make_error(.Execution_Failed, "callback failed", subject = "items")
		return {}
	}
	err := db.with_transaction(database, true, write)
	testing.expect_value(t, db.error_message(&err), "callback failed")
	testing.expect_value(t, db.error_subject(&err), "items")
	expect_transaction_mutex(t, database, .OK)
	test_database_count(t, database, "SELECT count(*) FROM items", 0)

	testing.expect_value(t, db.with_transaction(database, false, write, "BEGIN DEFERRED").kind, .None)
	expect_transaction_mutex(t, database, .OK)
	test_database_count(t, database, "SELECT count(*) FROM items", 1)
}

@(test)
scoped_transaction_skips_callback_on_begin_failure :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready do return
	defer db.close(database)

	mark :: proc(database: ^db.SQLite_DB, called: ^bool) -> db.Database_Error {
		called^ = true
		return {}
	}
	called := false
	if !testing.expect_value(t, db.begin_immediate(database).kind, .None) do return
	testing.expect_value(t, db.with_transaction(database, &called, mark).kind, .Execution_Failed)
	testing.expect_value(t, called, false)
	expect_transaction_mutex(t, database, .BUSY)
	db.rollback_transaction(database)
	expect_transaction_mutex(t, database, .OK)
	testing.expect_value(t, db.with_transaction(database, &called, nil).sqlite_code, .MISUSE)
}

@(test)
scoped_transaction_handles_commit_failure_and_automatic_rollback :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready do return
	defer db.close(database)
	sql :: proc(database: ^db.SQLite_DB, statement: cstring) -> db.Database_Error {
		return db.execute_sql(database, statement)
	}
	testing.expect_value(t, db.execute_sql(database,
		"PRAGMA foreign_keys=ON; CREATE TABLE child(id REFERENCES items(id) DEFERRABLE INITIALLY DEFERRED)").kind, .None)
	for statement in ([]cstring{
		"INSERT INTO child VALUES(100)",
		"INSERT INTO items VALUES(1,'a'); INSERT OR ROLLBACK INTO items VALUES(1,'b')",
	}) {
		err := db.with_transaction(database, statement, sql)
		testing.expect_value(t, err.sqlite_code, .CONSTRAINT)
		testing.expect_value(t, err.cleanup_code, .OK)
		testing.expect_value(t, db.sqlite3_get_autocommit(database), i32(1))
		expect_transaction_mutex(t, database, .OK)
	}
	test_database_count(t, database, "SELECT count(*) FROM child", 0)
	test_database_count(t, database, "SELECT count(*) FROM items", 0)
}

@(test)
scoped_transaction_reports_ignored_commit_and_failed_rollback :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready do return
	defer db.close(database)

	ignore_finish :: proc "c" (data: rawptr, action: i32, operation, b, database, trigger: cstring) -> i32 {
		SQLITE_TRANSACTION :: 22
		SQLITE_IGNORE :: 2
		if action == SQLITE_TRANSACTION && string(operation) == string((cast(^cstring)data)^) {
			return SQLITE_IGNORE
		}
		return 0
	}
	write :: proc(database: ^db.SQLite_DB, fail: bool) -> db.Database_Error {
		err := db.insert(database, "INSERT INTO items VALUES(1, 'test')", nil)
		if err.kind != .None do return err
		if fail do return db.make_error(.Execution_Failed, "body failed", sqlite_code = .ABORT)
		return {}
	}
	for operation in ([]cstring{"COMMIT", "ROLLBACK"}) {
		ignored := operation
		if !testing.expect_value(t, sqlite3_set_authorizer(database, ignore_finish, &ignored), .OK) do return
		failing_body := string(operation) == "ROLLBACK"
		err := db.with_transaction(database, failing_body, write)
		testing.expect_value(t, sqlite3_set_authorizer(database, nil, nil), .OK)
		if failing_body {
			testing.expect_value(t, db.error_message(&err), "body failed")
			testing.expect_value(t, err.sqlite_code, .ABORT)
			testing.expect_value(t, err.cleanup_code, .ERROR)
			testing.expect_value(t, db.sqlite3_get_autocommit(database), i32(0))
			testing.expect_value(t, db.execute_sql(database, "ROLLBACK").kind, .None)
		} else {
			testing.expect_value(t, err.sqlite_code, .ERROR)
			testing.expect_value(t, err.cleanup_code, .OK)
		}
		test_database_count(t, database, "SELECT count(*) FROM items", 0)
		expect_transaction_mutex(t, database, .OK)
	}
}
