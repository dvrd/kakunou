package integration_tests

import "core:testing"
import db "shared:kakunou"

@(test)
integer_readers_preserve_values_nulls_and_diagnostics :: proc(t: ^testing.T) {
	expect_error :: proc(t: ^testing.T, err: db.Database_Error, code: db.SQLite_Result, message: string) {
		diagnostic := err
		testing.expect_value(t, err.kind, .Execution_Failed)
		testing.expect_value(t, err.sqlite_code, code)
		testing.expect_value(t, db.error_message(&diagnostic), message)
	}
	expect_invalid :: proc(t: ^testing.T, stmt: ^db.SQLite_Statement, index: int, code: db.SQLite_Result, message: string) {
		required, err := db.column_int(stmt, index)
		testing.expect_value(t, required, i64(0))
		expect_error(t, err, code, message)
		value, valid, optional_err := db.column_int_optional(stmt, index)
		testing.expect_value(t, value, i64(0))
		testing.expect(t, !valid)
		expect_error(t, optional_err, code, message)
	}
	expect_invalid(t, nil, 0, .MISUSE, "SQL statement is required")

	database: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&database, ":memory:").kind, .None) do return
	defer db.close(database)
	statement, err := db.prepare(database, "SELECT NULL, 0, 9223372036854775807, '-42'", "empty")
	if !testing.expect_value(t, err.kind, .None) do return
	defer db.sqlite3_finalize(statement)
	if !testing.expect_value(t, db.sqlite3_step(statement), .ROW) do return
	expect_invalid(t, statement, -1, .RANGE, "SQL column -1 is outside 0 ..< 4")
	expect_invalid(t, statement, 4, .RANGE, "SQL column 4 is outside 0 ..< 4")

	required, null_err := db.column_int(statement, 0)
	testing.expect_value(t, required, i64(0))
	expect_error(t, null_err, .MISMATCH, "SQL column 0 is null")
	value, valid, optional_err := db.column_int_optional(statement, 0)
	testing.expect_value(t, value, i64(0))
	testing.expect(t, !valid)
	testing.expect_value(t, optional_err, db.Database_Error{})

	for expected, i in ([3]i64{0, max(i64), -42}) {
		actual, required_err := db.column_int(statement, i+1)
		testing.expect_value(t, actual, expected)
		testing.expect_value(t, required_err, db.Database_Error{})
		optional, present, read_err := db.column_int_optional(statement, i+1)
		testing.expect_value(t, optional, expected)
		testing.expect(t, present)
		testing.expect_value(t, read_err, db.Database_Error{})
	}
}
