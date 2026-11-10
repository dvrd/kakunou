package tests

import db "shared:kakunou"
import "core:testing"
import "core:sync"
import "core:thread"
import "core:time"
import "base:runtime"

@(test)
database_blob_parameters_and_columns_preserve_binary_data :: proc(t: ^testing.T) {
	database: ^db.SQLite_DB
	testing.expect_value(t, db.open(&database, ":memory:").kind, .None)
	defer db.close(database)
	testing.expect_value(t, db.execute_sql(database, "CREATE TABLE blobs(value BLOB NOT NULL)").kind, .None)
	data := []u8{0, 255, 1, 0, 42}
	testing.expect_value(t, db.insert(database, "INSERT INTO blobs VALUES(?)", {data}).kind, .None)
	found, err := db.query_one(database, "SELECT value FROM blobs", nil, &data, proc(statement: ^db.SQLite_Statement, output: ^[]u8) -> db.Database_Error {
		value, error := db.column_blob(statement, 0, context.allocator)
		output^ = value
		return error
	})
	testing.expect(t, found)
	testing.expect_value(t, err.kind, .None)
	testing.expect_value(t, len(data), 5)
	if len(data) == 5 {
		testing.expect_value(t, data[1], 255)
		testing.expect_value(t, data[3], 0)
	}
	delete(data)
}

@(test)
database_read_transaction_keeps_connection_locked_until_rollback :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready {return}
	defer db.close(database)
	if !testing.expect(t, db.begin_read(database).kind == .None) {return}
	read_open := true
	defer if read_open {db.rollback_transaction(database)}
	state := Database_Transaction_Worker{database = database}
	worker := thread.create_and_start_with_data(&state, database_transaction_worker, runtime.default_context())
	if !testing.expect(t, worker != nil) {return}
	defer {
		if read_open {db.rollback_transaction(database); read_open = false}
		thread.destroy(worker)
	}
	testing.expect(t, sync.sema_wait_with_timeout(&state.started, 2 * time.Second))
	testing.expect(t, !sync.sema_wait_with_timeout(&state.finished, 100 * time.Millisecond))
	db.rollback_transaction(database)
	read_open = false
	thread.join(worker)
	testing.expect_value(t, state.err.kind, .None)
}
