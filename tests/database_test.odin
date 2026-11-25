package tests

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import db "shared:kakunou"

Database_Transaction_Worker :: struct {
	database:          ^db.SQLite_DB,
	started, finished: sync.Sema,
	err:               db.Database_Error,
}

database_transaction_worker :: proc(data: rawptr) {
	state := cast(^Database_Transaction_Worker)data
	sync.sema_post(&state.started)
	state.err = db.begin_immediate(state.database)

	if state.err.kind == .None {
		state.err = db.insert(
			state.database,
			"INSERT INTO items(id,title) VALUES(2,'worker');",
			nil,
		)

		if state.err.kind == .None {
			state.err = db.commit_transaction(state.database)
		} else {
			db.rollback_transaction(state.database)
		}
	}

	sync.sema_post(&state.finished)
}

@(test)
database_transaction_does_not_block_an_independent_connection :: proc(t: ^testing.T) {
	first, first_ready := test_insert_database(t)
	if !first_ready {
		return
	}
	defer db.close(first)
	second, second_ready := test_insert_database(t)
	if !second_ready {
		return
	}
	defer db.close(second)
	err := db.begin_immediate(first)
	if !testing.expect(t, err.kind == .None, "begin transaction on first database") {
		return
	}
	outer_open := true
	defer if outer_open {
		db.rollback_transaction(first)
	}
	err = db.insert(first, "INSERT INTO items(id,title) VALUES(1,'outer');", nil)
	if !testing.expect(t, err.kind == .None, "write to first database") {
		return
	}
	state := Database_Transaction_Worker {
		database = second,
	}

	worker := thread.create_and_start_with_data(
		&state,
		database_transaction_worker,
		runtime.default_context(),
	)
	if !testing.expect(t, worker != nil, "start independent database transaction") {
		return
	}
	defer {
		if outer_open {
			db.rollback_transaction(first)
			outer_open = false
		}

		thread.destroy(worker)
	}

	if !testing.expect(
		t,
		sync.sema_wait_with_timeout(&state.started, 2 * time.Second),
		"independent worker starts",
	) {
		return
	}
	completed := sync.sema_wait_with_timeout(&state.finished, time.Second)
	testing.expect(
		t,
		completed,
		"independent transaction completes while first database remains locked",
	)
	db.rollback_transaction(first)
	outer_open = false
	thread.join(worker)
	testing.expect(t, state.err.kind == .None, "independent transaction succeeds")
	test_database_count(t, first, "SELECT COUNT(*) FROM items;", 0)
	test_database_count(t, second, "SELECT COUNT(*) FROM items;", 1)
}

@(test)
database_connection_stays_locked_until_its_owner_commits_or_rolls_back :: proc(t: ^testing.T) {
	for commit in ([2]bool{true, false}) {
		database, ready := test_insert_database(t)
		if !ready {
			return
		}
		defer db.close(database)
		err := db.begin_immediate(database)
		if !testing.expect(t, err.kind == .None, "begin owner transaction") {
			return
		}
		outer_open := true
		defer if outer_open {
			db.rollback_transaction(database)
		}
		err = db.insert(database, "INSERT INTO items(id,title) VALUES(1,'owner');", nil)
		if !testing.expect(t, err.kind == .None, "write owner row") {
			return
		}
		state := Database_Transaction_Worker {
			database = database,
		}

		worker := thread.create_and_start_with_data(
			&state,
			database_transaction_worker,
			runtime.default_context(),
		)
		if !testing.expect(t, worker != nil, "start competing transaction") {
			return
		}
		defer {
			if outer_open {
				db.rollback_transaction(database)
				outer_open = false
			}

			thread.destroy(worker)
		}

		if !testing.expect(
			t,
			sync.sema_wait_with_timeout(&state.started, 2 * time.Second),
			"competing worker starts",
		) {
			return
		}
		testing.expect(
			t,
			!sync.sema_wait_with_timeout(&state.finished, 100 * time.Millisecond),
			"competing transaction waits for the owner",
		)
		test_database_count(t, database, "SELECT COUNT(*) FROM items;", 1)

		if commit {
			err = db.commit_transaction(database)
			testing.expect(t, err.kind == .None, "owner commits")
		} else {
			db.rollback_transaction(database)
		}

		outer_open = false
		testing.expect(
			t,
			sync.sema_wait_with_timeout(&state.finished, time.Second),
			"competing transaction resumes after the owner finishes",
		)
		thread.join(worker)
		testing.expect(t, state.err.kind == .None, "competing transaction succeeds")
		test_database_count(t, database, "SELECT COUNT(*) FROM items;", 2 if commit else 1)
	}
}

@(test)
database_nested_begin_preserves_the_outer_transaction :: proc(t: ^testing.T) {
	for commit in ([2]bool{true, false}) {
		database, ready := test_insert_database(t)
		if !ready {
			return
		}
		defer db.close(database)
		err := db.begin_immediate(database)
		if !testing.expect(t, err.kind == .None, "begin outer transaction") {
			return
		}
		outer_open := true
		defer if outer_open {
			db.rollback_transaction(database)
		}
		err = db.insert(database, "INSERT INTO items(id,title) VALUES(1,'outer work');", nil)
		if !testing.expect(t, err.kind == .None, "insert within outer transaction") {
			return
		}

		nested := db.begin_immediate(database)
		// Balance both holds when reproducing the old implementation's false success.
		if nested.kind == .None {
			db.rollback_transaction(database)
		}
		testing.expect(
			t,
			nested.kind == .Execution_Failed && nested.sqlite_code == .ERROR,
			"nested begin returns the SQLite error",
		)
		test_database_count(t, database, "SELECT COUNT(*) FROM items;", 1)

		if commit {
			err = db.commit_transaction(database)
			outer_open = false
			testing.expect(t, err.kind == .None, "outer transaction can still commit")
			test_database_count(t, database, "SELECT COUNT(*) FROM items;", 1)
		} else {
			db.rollback_transaction(database)
			outer_open = false
			test_database_count(t, database, "SELECT COUNT(*) FROM items;", 0)
		}

		err = db.begin_immediate(database)
		if !testing.expect(
			t,
			err.kind == .None,
			"connection remains usable after the owner finishes",
		) {
			return
		}
		db.rollback_transaction(database)
	}
}

@(test)
database_helpers_create_tables_and_execute_sql :: proc(t: ^testing.T) {
	database: ^db.SQLite_DB
	opened := (db.open(&database, ":memory:").kind == .None)
	defer testing.expect(
		t,
		db.sqlite3_close(database) == .OK,
		"close database without outstanding statements",
	)
	if !testing.expect(t, opened, "open in-memory database") {
		return
	}

	schema := db.Table_Schema {
		name    = "items",
		columns = {{name = "id", data_type = .Integer, primary_key = true}},
	}

	if !testing.expect(t, (db.create_table(database, schema).kind == .None), "create table") {
		return
	}
	if !testing.expect(
		t,
		(db.create_table(database, schema).kind == .None),
		"idempotent schema initialization",
	) {
		return
	}
	if !testing.expect(
		t,
		(db.execute_sql(database, "INSERT INTO items (id) VALUES (1), (2);").kind == .None),
		"execute insert",
	) {
		return
	}

	test_database_count(t, database, "SELECT COUNT(*) FROM items;", 2)
}

@(test)
database_helpers_return_errors_without_logging :: proc(t: ^testing.T) {
	database: ^db.SQLite_DB
	opened := (db.open(&database, ":memory:").kind == .None)
	defer testing.expect(t, db.sqlite3_close(database) == .OK, "close database after errors")
	if !testing.expect(t, opened, "open in-memory database") {
		return
	}

	capture := Test_Log {
		contains = "Database initialization failed",
	}

	previous_logger := context.logger
	context.logger = {
		procedure = test_capture_log,
		data      = &capture,
	}

	defer context.logger = previous_logger

	err := db.create_table(database, db.Table_Schema{name = "broken"})
	testing.expect(
		t,
		err.kind == .Invalid_Schema,
		"invalid schema is distinguished from SQLite failure",
	)
	testing.expect(t, db.error_subject(&err) == "broken", "table context survives propagation")

	err = db.execute_sql(database, "INSERT INTO missing VALUES (1);")
	testing.expect(
		t,
		err.kind == .Execution_Failed && err.sqlite_code == .ERROR,
		"original SQLite code is returned",
	)
	testing.expect(t, len(db.error_message(&err)) > 0, "SQLite explanation is retained")

	err = db.create_table(
		nil,
		db.Table_Schema{name = "items", columns = {{name = "id", data_type = .Integer}}},
	)
	testing.expect(
		t,
		err.kind == .Execution_Failed && err.sqlite_code == .MISUSE,
		"missing database returns typed failure",
	)
	testing.expect(t, capture.error_count == 0, "helpers do not log while propagating failures")

	db.log_error(err, "Database initialization failed")
	testing.expect(
		t,
		capture.error_count == 1 && capture.matched,
		"caller logs the complete failure once",
	)

	testing.expect(
		t,
		(db.create_table(database, db.Table_Schema{name = "items", columns = {{name = "id", data_type = .Integer}}}).kind ==
			.None),
		"valid SQL succeeds after errors",
	)
}

@(test)
table_schema_types_and_constraints_are_applied :: proc(t: ^testing.T) {
	database: ^db.SQLite_DB
	opened := (db.open(&database, ":memory:").kind == .None)
	defer testing.expect(t, db.sqlite3_close(database) == .OK, "close database")
	if !testing.expect(t, opened, "open database") {
		return
	}

	schema := db.Table_Schema {
		name    = "items",
		columns = {
			{name = "id", data_type = .Integer, primary_key = true},
			{name = "label", data_type = .Text, not_null = true, unique = true},
			{name = "note", data_type = .Text},
			{name = "amount", data_type = .Real},
			{name = "raw", data_type = .Blob},
			{name = "score", data_type = .Numeric},
		},
	}

	if !testing.expect(
		t,
		(db.create_table(database, schema).kind == .None),
		"create typed schema",
	) {
		return
	}

	metadata: cstring = `
		SELECT COUNT(*) FROM pragma_table_info('items') WHERE
		(name = 'id' AND type = 'INTEGER' AND pk = 1) OR
		(name = 'label' AND type = 'TEXT' AND "notnull" = 1) OR
		(name = 'note' AND type = 'TEXT' AND "notnull" = 0) OR
		(name = 'amount' AND type = 'REAL') OR
		(name = 'raw' AND type = 'BLOB') OR
		(name = 'score' AND type = 'NUMERIC');
	`
	if !test_database_count(t, database, metadata, 6) {
		return
	}

	if !testing.expect(
		t,
		(db.execute_sql(database, "INSERT INTO items (label, note) VALUES ('first', NULL);").kind ==
			.None),
		"nullable column and generated primary key",
	) {
		return
	}

	capture := Test_Log{}
	previous_logger := context.logger
	context.logger = {
		procedure = test_capture_log,
		data      = &capture,
	}

	defer context.logger = previous_logger

	for sql in ([]cstring {
			"INSERT INTO items (id, label) VALUES (1, 'different');",
			"INSERT INTO items (label) VALUES (NULL);",
			"INSERT INTO items (label) VALUES ('first');",
		}) {
		err := db.execute_sql(database, sql)
		testing.expect(
			t,
			err.kind == .Execution_Failed && err.sqlite_code == .CONSTRAINT,
			"constraint code reaches caller",
		)
	}

	testing.expect(t, capture.error_count == 0, "constraint errors are returned without logging")
	test_database_count(t, database, "SELECT COUNT(*) FROM items;", 1)
}

@(test)
table_schema_quotes_names_and_supports_explicit_creation :: proc(t: ^testing.T) {
	database: ^db.SQLite_DB
	opened := (db.open(&database, ":memory:").kind == .None)
	defer testing.expect(t, db.sqlite3_close(database) == .OK, "close database")
	if !testing.expect(t, opened, "open database") {
		return
	}

	schema := db.Table_Schema {
		name    = "events\"; DROP TABLE other; --",
		columns = {
			{name = "select", data_type = .Integer},
			{name = "friend\"s 🎉", data_type = .Text},
		},
	}

	if !testing.expect(
		t,
		(db.create_table(database, schema, if_not_exists = false).kind == .None),
		"quoted identifier names are literal",
	) {
		return
	}

	if !testing.expect(
		t,
		(db.execute_sql(database, `INSERT INTO "events""; DROP TABLE other; --" ("select", "friend""s 🎉") VALUES (1, 'name');`).kind ==
			.None),
		"quoted columns are usable",
	) {
		return
	}
	if !test_database_count(
		t,
		database,
		`SELECT COUNT(*) FROM "events""; DROP TABLE other; --";`,
		1,
	) {
		return
	}

	capture := Test_Log{}
	previous_logger := context.logger
	context.logger = {
		procedure = test_capture_log,
		data      = &capture,
	}

	defer context.logger = previous_logger

	err := db.create_table(database, schema, if_not_exists = false)
	testing.expect(
		t,
		err.kind == .Execution_Failed && err.sqlite_code == .ERROR,
		"explicit creation returns SQLite failure",
	)
	testing.expect(
		t,
		db.error_subject(&err) == schema.name,
		"table context is attached to SQLite error",
	)
	testing.expect(
		t,
		capture.error_count == 0,
		"duplicate table error is returned without logging",
	)
}

@(test)
table_schema_rejects_invalid_definitions_and_allocation_failure :: proc(t: ^testing.T) {
	capture := Test_Log{}
	previous_logger := context.logger
	context.logger = {
		procedure = test_capture_log,
		data      = &capture,
	}

	defer context.logger = previous_logger

	for schema in ([]db.Table_Schema {
			{},
			{name = "empty"},
			{name = "bad\x00name", columns = {{name = "id"}}},
			{name = "items", columns = {{name = ""}}},
			{name = "items", columns = {{name = "bad\x00name"}}},
			{name = "items", columns = {{name = "id", data_type = db.Column_Type(999)}}},
		}) {
		sql, err := db.build_new_table_sql(schema)
		testing.expect(
			t,
			err.kind == .Invalid_Schema && sql == nil,
			"invalid schema produces no SQL",
		)
	}

	testing.expect(t, capture.error_count == 0, "invalid schemas are returned without logging")

	storage: [1]u8
	arena: mem.Arena
	mem.arena_init(&arena, storage[:])
	previous_allocator := context.allocator
	context.allocator = mem.arena_allocator(&arena)
	defer context.allocator = previous_allocator

	sql, err := db.build_new_table_sql(db.Table_Schema{name = "items", columns = {{name = "id"}}})
	context.allocator = previous_allocator

	testing.expect(
		t,
		err.kind == .Allocation_Failed && sql == nil,
		"allocation failure produces no SQL",
	)
	testing.expect(
		t,
		err.allocator_error == .Out_Of_Memory,
		"underlying allocation error is preserved",
	)
	testing.expect(t, capture.error_count == 0, "allocation failure is returned without logging")
}

@(test)
database_error_is_small_and_truncates_text :: proc(t: ^testing.T) {
	testing.expect(
		t,
		size_of(db.Database_Error) <= 320,
		"error stays small enough to return by value",
	)

	long_text := make([]u8, 2048)
	defer delete(long_text)

	for &value in long_text {
		value = 'x'
	}

	err := db.make_error(
		.Execution_Failed,
		string(long_text),
		sqlite_code = .ERROR,
		subject = string(long_text),
	)
	testing.expect_value(t, len(db.error_message(&err)), db.ERROR_MESSAGE_CAPACITY - 1)
	testing.expect_value(t, len(db.error_subject(&err)), db.ERROR_SUBJECT_CAPACITY - 1)

	copied := err
	testing.expect_value(t, db.error_message(&copied), db.error_message(&err))

	short := db.make_error(.Open_Failed, "short", subject = "path/to/file")
	testing.expect_value(t, db.error_message(&short), "short")
	testing.expect_value(t, db.error_subject(&short), "path/to/file")
}

@(test)
database_changes_counts_rows_updated :: proc(t: ^testing.T) {
	database, ready := test_insert_database(t)
	if !ready {
		return
	}

	defer db.close(database)

	err := db.execute_sql(
		database,
		"INSERT INTO items(id,title) VALUES(1,'one'),(2,'two'),(3,'three');",
	)
	if !testing.expect(t, err.kind == .None, "seed rows") {
		return
	}

	err = db.execute_sql(database, "UPDATE items SET title = title || '!' WHERE id >= 2;")
	if !testing.expect(t, err.kind == .None, "update rows") {
		return
	}

	testing.expect_value(t, db.sqlite3_changes(database), 2)
}

@(test)
database_busy_timeout_is_accepted :: proc(t: ^testing.T) {
	database: ^db.SQLite_DB
	err := db.open(&database, ":memory:")
	if !testing.expect(t, err.kind == .None, "open busy timeout fixture") {
		return
	}

	defer db.close(database)

	test_database_count(t, database, "PRAGMA busy_timeout;", db.BUSY_TIMEOUT_MILLISECONDS)
	testing.expect_value(t, db.sqlite3_busy_timeout(database, 250), db.SQLite_Result.OK)
	test_database_count(t, database, "PRAGMA busy_timeout;", 250)
}

@(test)
database_second_connection_waits_for_a_write_lock :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	directory, directory_error := os.make_directory_temp("", "kakunou-busy-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {
		return
	}
	defer testing.expect_value(t, os.remove_all(directory), nil)
	path := strings.clone_to_cstring(fmt.aprintf("%s/busy.sqlite", directory))
	holder: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&holder, path).kind, .None) {
		return
	}
	defer db.close(holder)
	contender: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&contender, path).kind, .None) {
		return
	}
	defer db.close(contender)
	err := db.execute_sql(
		holder,
		"CREATE TABLE items(id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE);",
	)
	if !testing.expect(t, err.kind == .None, "create shared table") {
		return
	}
	err = db.begin_immediate(holder)
	if !testing.expect(t, err.kind == .None, "hold the write lock") {
		return
	}
	outer_open := true
	defer if outer_open {
		db.rollback_transaction(holder)
	}
	err = db.insert(holder, "INSERT INTO items(id,title) VALUES(1,'holder');", nil)
	if !testing.expect(t, err.kind == .None, "write while holding the lock") {
		return
	}
	state := Database_Transaction_Worker {
		database = contender,
	}
	worker := thread.create_and_start_with_data(
		&state,
		database_transaction_worker,
		runtime.default_context(),
	)
	if !testing.expect(t, worker != nil, "start second connection") {
		return
	}
	defer {
		if outer_open {
			db.rollback_transaction(holder)
			outer_open = false
		}
		thread.destroy(worker)
	}
	if !testing.expect(
		t,
		sync.sema_wait_with_timeout(&state.started, 2 * time.Second),
		"second connection starts",
	) {
		return
	}
	testing.expect(
		t,
		!sync.sema_wait_with_timeout(&state.finished, 100 * time.Millisecond),
		"second connection waits instead of returning SQLITE_BUSY immediately",
	)
	err = db.commit_transaction(holder)
	outer_open = false
	testing.expect(t, err.kind == .None, "holder commits")
	testing.expect(
		t,
		sync.sema_wait_with_timeout(&state.finished, time.Second),
		"second connection proceeds after the lock is released",
	)
	thread.join(worker)
	testing.expect(t, state.err.kind == .None, "second connection writes after waiting")
	test_database_count(t, holder, "SELECT COUNT(*) FROM items;", 2)
}
