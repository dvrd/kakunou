package integration_tests

import "core:testing"
import db "shared:kakunou"

@(test)
batch_inserts_bind_each_row_and_preserve_input_types :: proc(t: ^testing.T) {
	database: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&database, ":memory:").kind, .None) do return
	defer db.close(database)
	testing.expect_value(t, db.execute_sql(database, "CREATE TABLE items(id, name, payload)").kind, .None)
	bytes := [?]u8{0, 42, 255}
	rows := [?][3]db.SQLite_Value{
		{i64(1), cstring("a"), bytes[:]},
		{i64(2), cstring("b"), []u8{}},
	}
	sql :: "INSERT INTO items VALUES(?, ?, ?)"
	testing.expect_value(t, db.insert_many(database, sql, rows[:0]).kind, .None)
	test_database_count(t, database, "SELECT count(*) FROM items", 0)
	testing.expect_value(t, db.insert_many(database, sql, rows[:]).kind, .None)
	test_database_count(t, database, "SELECT count(*) FROM items WHERE (id=1 AND name='a' AND hex(payload)='002AFF') OR (id=2 AND name='b' AND payload=x'')", 2)
}

@(test)
batch_insert_rejects_invalid_statements_before_any_write :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready do return
	defer db.close(database)
	rows := [?][1]db.SQLite_Value{{cstring("a")}}
	for sql in ([]cstring{
		"INSERT INTO items(title) VALUES(?) RETURNING id",
		"INSERT INTO items(title) VALUES(?); DELETE FROM items",
		"INSERT INTO items VALUES(?, ?)",
	}) {
		testing.expect_value(t, db.insert_many(database, sql, rows[:]).kind, .Execution_Failed)
		test_database_count(t, database, "SELECT count(*) FROM items", 0)
	}
	expect_transaction_mutex(t, database, .OK)
}

@(test)
batch_insert_stops_at_first_error_and_respects_transaction :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready do return
	defer db.close(database)
	rows := [?][1]db.SQLite_Value{{cstring("a")}, {cstring("a")}, {cstring("c")}}
	sql :: "INSERT INTO items(title) VALUES(?)"
	body :: proc(database: ^db.SQLite_DB, batch: [][1]db.SQLite_Value) -> db.Database_Error {
		return db.insert_many(database, sql, batch)
	}
	testing.expect_value(t, db.with_transaction(database, rows[:], body).sqlite_code, .CONSTRAINT)
	test_database_count(t, database, "SELECT count(*) FROM items", 0)
	testing.expect_value(t, db.insert_many(database, sql, rows[:]).sqlite_code, .CONSTRAINT)
	test_database_count(t, database, "SELECT count(*) FROM items WHERE title='a'", 1)
	test_database_count(t, database, "SELECT count(*) FROM items", 1)

	invalid := [?][1]db.SQLite_Value{{cstring("b")}, {}, {cstring("c")}}
	testing.expect_value(t, db.insert_many(database, sql, invalid[:]).sqlite_code, .MISUSE)
	test_database_count(t, database, "SELECT count(*) FROM items", 2)
	expect_transaction_mutex(t, database, .OK)
}
