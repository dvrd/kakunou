package tests

import db "shared:kakunou"
import "core:testing"
import "core:log"
import "core:strings"

test_database_count :: proc(t: ^testing.T, database: ^db.SQLite_DB, sql: cstring, expected: i64) -> bool {
	decode :: proc(statement: ^db.SQLite_Statement, count: ^i64) -> db.Database_Error {
		value, err := db.column_int(statement, 0)
		if err.kind != .None do return err
		count^ = value

		return {}
	}

	count: i64
	found, ok := db.query_one(database, sql, nil, &count, decode)

	return testing.expectf(
		t,
		ok.kind == .None && found && count == expected,
		"SQL count: expected %d, got %d",
		expected,
		count,
	)
}

test_insert_database :: proc(t: ^testing.T) -> (database: ^db.SQLite_DB, ok: bool) {
	err := db.open(&database, ":memory:")
	if !testing.expect(t, err.kind == .None, "open insert fixture") do return

	defer {
		if !ok do testing.expect(t, db.sqlite3_close(database) == .OK, "close failed insert fixture")
	}

	err = db.create_table(
		database,
		db.Table_Schema {
			name = "items",
			columns = {
				{name = "id", data_type = .Integer, primary_key = true},
				{name = "title", data_type = .Text, not_null = true, unique = true},
			},
		},
	)
	ok = testing.expect(t, err.kind == .None, "create insert fixture table")

	return
}

Test_Log :: struct {
	warning_count:  int,
	warning:        string,
	warning_buffer: [2048]u8,
	error_count:    int,
	contains:       string,
	matched:        bool,
}

test_capture_log :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	capture := cast(^Test_Log)data
	if level == .Warning {
		capture.warning_count += 1
		length := copy(capture.warning_buffer[:], transmute([]u8)text)
		capture.warning = string(capture.warning_buffer[:length])
	}

	if level == .Error {
		capture.error_count += 1
		capture.matched = capture.matched || strings.contains(text, capture.contains)
	}
}
