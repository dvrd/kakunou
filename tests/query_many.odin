package tests

import db "shared:kakunou"
import "core:encoding/json"
import "core:mem"
import "core:testing"

test_query_integer :: proc(statement: ^db.SQLite_Statement, output: ^i64) -> db.Database_Error {
	value, error := db.column_int(statement, 0)
	if error.kind == .None {
		output^ = value
	}

	return error
}

@(test)
query_many_rejects_invalid_inputs_before_allocating_or_entering_sqlite :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	storage: [1]u8
	arena: mem.Arena
	mem.arena_init(&arena, storage[:])
	context.temp_allocator = mem.arena_allocator(&arena)
	decoder: proc(_: ^db.SQLite_Statement, _: ^i64) -> db.Database_Error

	for arguments in ([]struct {
			database: ^db.SQLite_DB,
			sql:      cstring,
			decode:   type_of(decoder),
			limit:    int,
		} {
			{nil, "SELECT 1", test_query_integer, 1},
			{database, nil, test_query_integer, 1},
			{database, "SELECT 1", nil, 1},
			{database, "SELECT 1", test_query_integer, -1},
			{database, "SELECT 1", test_query_integer, 0},
			{database, "SELECT 1", test_query_integer, db.QUERY_ROWS_LIMIT + 1},
			{database, "SELECT 1", test_query_integer, max(int)},
		}) {
		rows, error := db.query_many(arguments.database, arguments.sql, nil, arguments.decode, arguments.limit)
		testing.expect_value(t, error.kind, .Execution_Failed)
		testing.expect_value(t, error.sqlite_code, .MISUSE)
		testing.expect(t, rows == nil)
	}
}

@(test)
query_many_preserves_empty_json_and_accepts_the_maximum_configured_limit :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	database, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	rows, error := db.query_many(database, "SELECT 1 WHERE 0", nil, test_query_integer)
	testing.expect_value(t, error.kind, .None)
	testing.expect(t, rows != nil)
	testing.expect_value(t, len(rows), 0)
	encoded, encoding_error := json.marshal(rows)
	defer delete(encoded)
	testing.expect_value(t, encoding_error, nil)
	testing.expect_value(t, cast(string)encoded, "[]")
	rows, error = db.query_many(database, "SELECT 9", nil, test_query_integer, db.QUERY_ROWS_LIMIT)
	testing.expect_value(t, error.kind, .None)
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0], 9)
	}
}

@(test)
query_many_bounds_initial_capacity_by_the_requested_limit :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	// One i64 plus alignment fits; the old unconditional eight-row allocation did not.
	storage: [2 * size_of(i64)]u8
	arena: mem.Arena
	mem.arena_init(&arena, storage[:])
	context.temp_allocator = mem.arena_allocator(&arena)
	rows, error := db.query_many(database, "SELECT 42", nil, test_query_integer, 1)
	testing.expect_value(t, error.kind, .None)
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0], 42)
	}
}

@(test)
query_many_accepts_exact_limits_and_rejects_excess_rows_without_partial_rows :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	database, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	sql: cstring = "SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3"
	rows, error := db.query_many(database, sql, nil, test_query_integer, 3)
	testing.expect_value(t, error.kind, .None)

	if testing.expect_value(t, len(rows), 3) {
		for value, index in rows {
			testing.expect_value(t, value, i64(index + 1))
		}
	}

	rows, error = db.query_many(database, sql, nil, test_query_integer, 2)
	testing.expect_value(t, error.kind, .Execution_Failed)
	testing.expect_value(t, error.sqlite_code, .TOOBIG)
	testing.expect(t, rows == nil)
	test_database_count(t, database, "SELECT COUNT(*) FROM items", 0)
}

@(test)
query_many_finalizes_prepare_bind_step_and_decoder_failure_paths :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	database, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)

	for query in ([]struct {
			sql:  cstring,
			code: db.SQLite_Result,
		} {
			{"SELECT FROM", .ERROR},
			{"; -- Empty statement", .MISUSE},
			{"SELECT ?", .RANGE},
			{"SELECT abs(-9223372036854775808)", .ERROR},
		}) {
		rows, error := db.query_many(database, query.sql, nil, test_query_integer)
		testing.expect_value(t, error.kind, .Execution_Failed)
		testing.expect_value(t, error.sqlite_code, query.code)
		testing.expect(t, rows == nil)
	}

	decode_failure := proc(statement: ^db.SQLite_Statement, output: ^i64) -> db.Database_Error {
		return db.make_error(.Execution_Failed, "Decoder failure", sqlite_code = .MISMATCH)
	}

	rows, error := db.query_many(database, "SELECT 1", nil, decode_failure)
	testing.expect(t, rows == nil)
	testing.expect_value(t, error.sqlite_code, .MISMATCH)
	testing.expect_value(t, db.error_text(error.message[:]), "Decoder failure")
	test_database_count(t, database, "SELECT COUNT(*) FROM items", 0)
}

@(test)
query_many_retains_finalize_error_alongside_the_primary_decoder_failure :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	database, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	decode_failure := proc(statement: ^db.SQLite_Statement, output: ^i64) -> db.Database_Error {
		// Fail the following row while the callback owns the borrowed statement.
		assert(db.sqlite3_step(statement) == .ERROR)
		return db.make_error(.Execution_Failed, "Decoder failure", sqlite_code = .MISMATCH)
	}

	rows, error := db.query_many(database, "SELECT 1 UNION ALL SELECT abs(-9223372036854775808)", nil, decode_failure)
	testing.expect(t, rows == nil)
	testing.expect_value(t, error.sqlite_code, .MISMATCH)
	testing.expect_value(t, error.cleanup_code, .ERROR)
	testing.expect_value(t, db.error_text(error.message[:]), "Decoder failure")
}

@(test)
query_many_propagates_initial_and_growth_allocation_failures :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)

	for limit in ([]int{1, 8 * size_of(i64) + align_of(i64) - 1}) {
		storage: [80]u8
		arena: mem.Arena
		mem.arena_init(&arena, storage[:limit])
		context.temp_allocator = mem.arena_allocator(&arena)
		query :: "WITH RECURSIVE r(n) AS (VALUES(1) UNION ALL " + "SELECT n+1 FROM r WHERE n<9) SELECT n FROM r"
		rows, error := db.query_many(database, query, nil, test_query_integer, 9)
		testing.expect_value(t, error.kind, .Allocation_Failed)
		testing.expect_value(t, error.allocator_error, .Out_Of_Memory)
		testing.expect(t, rows == nil)
	}
}

@(test)
query_one_and_insert_surface_deferred_constraint_failures_during_finalize :: proc(t: ^testing.T) {
	database: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&database, ":memory:").kind, .None) {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	// RETURNING yields a row before SQLite attempts the implicit transaction commit.
	schema: cstring = `PRAGMA foreign_keys=ON;
		CREATE TABLE parents(id INTEGER PRIMARY KEY);
		CREATE TABLE children(parent INTEGER REFERENCES parents(id)
			DEFERRABLE INITIALLY DEFERRED);`
	if !testing.expect_value(t, db.execute_sql(database, schema).kind, .None) {
		return
	}
	query: cstring = "INSERT INTO children VALUES(1) RETURNING parent"
	value: i64
	found, query_error := db.query_one(database, query, nil, &value, test_query_integer)
	testing.expect(t, !found)
	testing.expect_value(t, query_error.kind, .Execution_Failed)
	testing.expect_value(t, query_error.sqlite_code, .CONSTRAINT)
	test_database_count(t, database, "SELECT COUNT(*) FROM children", 0)
	error := db.insert(database, query, nil)
	testing.expect_value(t, error.kind, .Execution_Failed)
	testing.expect_value(t, error.sqlite_code, .ROW)
	testing.expect_value(t, error.cleanup_code, .CONSTRAINT)
	test_database_count(t, database, "SELECT COUNT(*) FROM children", 0)
}

@(test)
query_one_preserves_primary_decoder_and_finalize_failures :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	decode_failure := proc(statement: ^db.SQLite_Statement, output: ^i64) -> db.Database_Error {
		assert(db.sqlite3_step(statement) == .ERROR)
		return db.make_error(.Execution_Failed, "Decoder failure", sqlite_code = .MISMATCH)
	}

	value: i64
	found, error := db.query_one(
		database,
		"SELECT 1 UNION ALL SELECT abs(-9223372036854775808)",
		nil,
		&value,
		decode_failure,
	)
	testing.expect(t, !found)
	testing.expect_value(t, error.sqlite_code, .MISMATCH)
	testing.expect_value(t, error.cleanup_code, .ERROR)
}

@(test)
commit_failure_consumes_the_transaction_hold_and_allows_a_new_transaction :: proc(t: ^testing.T) {
	database: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&database, ":memory:").kind, .None) {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	schema: cstring = `PRAGMA foreign_keys=ON;
		CREATE TABLE parents(id INTEGER PRIMARY KEY);
		CREATE TABLE children(parent INTEGER REFERENCES parents(id)
			DEFERRABLE INITIALLY DEFERRED);`
	if !testing.expect_value(t, db.execute_sql(database, schema).kind, .None) {
		return
	}
	if !testing.expect_value(t, db.begin_immediate(database).kind, .None) {
		return
	}
	owned := true
	defer if owned {
		db.rollback_transaction(database)
	}
	testing.expect_value(t, db.insert(database, "INSERT INTO children VALUES(1)", nil).kind, .None)
	owned = false
	error := db.commit_transaction(database)
	testing.expect_value(t, error.sqlite_code, .CONSTRAINT)
	testing.expect_value(t, error.cleanup_code, .OK)
	test_database_count(t, database, "SELECT COUNT(*) FROM children", 0)

	if testing.expect_value(t, db.begin_read(database).kind, .None) {
		db.rollback_transaction(database)
	}
}

// Free the real allocation, then report an injected cleanup failure. This keeps
// the allocator tracker sound while checking propagation of a secondary error.
test_schema_free_failure :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]u8,
	mem.Allocator_Error,
) {
	parent := cast(^mem.Allocator)data
	result, error := parent.procedure(parent.data, mode, size, alignment, old_memory, old_size, location)
	if mode == .Free && error == nil {
		error = .Invalid_Pointer
	}
	return result, error
}

@(test)
schema_creation_retains_cleanup_errors_before_returning :: proc(t: ^testing.T) {
	database: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&database, ":memory:").kind, .None) {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	parent := context.allocator
	context.allocator = {
		procedure = test_schema_free_failure,
		data      = &parent,
	}

	schema := db.Table_Schema {
		name    = "items",
		columns = {{name = "id"}},
	}

	error := db.create_table(database, schema)
	testing.expect_value(t, error.kind, .Allocation_Failed)
	testing.expect_value(t, error.allocator_error, .Invalid_Pointer)
	error = db.create_table(database, schema, if_not_exists = false)
	testing.expect_value(t, error.kind, .Execution_Failed)
	testing.expect_value(t, error.sqlite_code, .ERROR)
	testing.expect_value(t, error.allocator_error, .Invalid_Pointer)
}
