package integration_tests

import "core:testing"
import db "shared:kakunou"

test_database_count :: proc(
	t: ^testing.T,
	database: ^db.SQLite_DB,
	sql: cstring,
	expected: i64,
) -> bool {
	decode :: proc(statement: ^db.SQLite_Statement, count: ^i64) -> db.Database_Error {
		value, err := db.column_int(statement, 0)
		if err.kind != .None {
			return err
		}
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
	if !testing.expect(t, err.kind == .None, "open insert fixture") {
		return
	}

	defer {
		if !ok {
			testing.expect(t, db.sqlite3_close(database) == .OK, "close failed insert fixture")
		}
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
