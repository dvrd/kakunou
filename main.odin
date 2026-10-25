package sqlite

import "core:log"

foreign import sqlite "system:sqlite3"

SQLite_DB :: struct {}

SQLite_Mutex :: struct {}

SQLite_Statement :: struct {}

SQLite_Result :: enum i32 {
	OK         = 0,
	ERROR      = 1,
	INTERNAL   = 2,
	PERM       = 3,
	ABORT      = 4,
	BUSY       = 5,
	LOCKED     = 6,
	NOMEM      = 7,
	READONLY   = 8,
	INTERRUPT  = 9,
	IOERR      = 10,
	CORRUPT    = 11,
	NOTFOUND   = 12,
	FULL       = 13,
	CANTOPEN   = 14,
	PROTOCOL   = 15,
	EMPTY      = 16,
	SCHEMA     = 17,
	TOOBIG     = 18,
	CONSTRAINT = 19,
	MISMATCH   = 20,
	MISUSE     = 21,
	NOLFS      = 22,
	AUTH       = 23,
	FORMAT     = 24,
	RANGE      = 25,
	NOTADB     = 26,
	NOTICE     = 27,
	WARNING    = 28,
	ROW        = 100,
	DONE       = 101,
}

SQLite_Value :: union {
	i64,
	cstring,
}

SQLite_Column_Type :: enum i32 {
	INTEGER = 1,
	FLOAT   = 2,
	TEXT    = 3,
	BLOB    = 4,
	NULL    = 5,
}

SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_CREATE :: 0x00000004
SQLITE_OPEN_FULLMUTEX :: 0x00010000

foreign sqlite {
	sqlite3_db_mutex :: proc "c" (database: ^SQLite_DB) -> ^SQLite_Mutex ---
	sqlite3_mutex_enter :: proc "c" (mutex: ^SQLite_Mutex) ---
	sqlite3_mutex_leave :: proc "c" (mutex: ^SQLite_Mutex) ---

	sqlite3_open_v2 :: proc "c" (filename: cstring, database: ^^SQLite_DB, flags: i32, vfs: cstring) -> SQLite_Result ---

	sqlite3_close :: proc "c" (database: ^SQLite_DB) -> SQLite_Result ---

	sqlite3_errmsg :: proc "c" (database: ^SQLite_DB) -> cstring ---

	sqlite3_prepare_v2 :: proc "c" (database: ^SQLite_DB, sql: cstring, byte_count: i32, statement: ^^SQLite_Statement, tail: ^cstring) -> SQLite_Result ---

	sqlite3_bind_text :: proc "c" (statement: ^SQLite_Statement, index: i32, value: cstring, byte_count: i32, destructor: proc "c" (data: rawptr)) -> SQLite_Result ---

	sqlite3_bind_int64 :: proc "c" (statement: ^SQLite_Statement, index: i32, value: i64) -> SQLite_Result ---

	sqlite3_bind_parameter_count :: proc "c" (statement: ^SQLite_Statement) -> i32 ---

	sqlite3_column_text :: proc "c" (statement: ^SQLite_Statement, column: i32) -> [^]u8 ---

	sqlite3_column_int64 :: proc "c" (statement: ^SQLite_Statement, column: i32) -> i64 ---

	sqlite3_column_bytes :: proc "c" (statement: ^SQLite_Statement, column: i32) -> i32 ---

	sqlite3_column_type :: proc "c" (statement: ^SQLite_Statement, column: i32) -> SQLite_Column_Type ---

	sqlite3_column_count :: proc "c" (statement: ^SQLite_Statement) -> i32 ---

	sqlite3_step :: proc "c" (statement: ^SQLite_Statement) -> SQLite_Result ---

	sqlite3_exec :: proc "c" (database: ^SQLite_DB, sql: cstring, callback: proc "c" (data: rawptr, coulmn_count: i32, values: [^]cstring, names: [^]cstring) -> SQLite_Result, data: rawptr, error_message: ^cstring) -> SQLite_Result ---

	sqlite3_finalize :: proc "c" (statement: ^SQLite_Statement) -> SQLite_Result ---

	sqlite3_last_insert_rowid :: proc "c" (database: ^SQLite_DB) -> i64 ---
}

// SQLite owns this recursive mutex for the lifetime of a FULLMUTEX connection.
// A nil mutex is a no-op for SQLite's enter/leave routines, preserving nil-handle errors.
@(private)
connection_mutex :: proc(database: ^SQLite_DB) -> ^SQLite_Mutex {
	if database == nil do return nil
	return sqlite3_db_mutex(database)
}

open :: proc(database: ^^SQLite_DB, path: cstring) -> Database_Error {
	if database == nil || path == nil {
		return make_error(
			.Open_Failed,
			"Database output and path are required",
			sqlite_code = .MISUSE,
		)
	}

	if database^ != nil {
		return make_error(
			.Open_Failed,
			"Database output must be empty",
			sqlite_code = .MISUSE,
			path = string(path),
		)
	}

	result := sqlite3_open_v2(
		path,
		database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
		nil,
	)

	mutex_missing := result == .OK && connection_mutex(database^) == nil
	if result != .OK || mutex_missing {
		message := "Could not allocate database connection"
		if database^ != nil {
			message = string(sqlite3_errmsg(database^))
		}

		if mutex_missing {
			message = "SQLite connection serialization is required"
			result = .MISUSE
		}
		err := make_error(.Open_Failed, message, sqlite_code = result, path = string(path))

		if database^ != nil {
			err.cleanup_code = sqlite3_close(database^)
			if err.cleanup_code == .OK do database^ = nil
		}

		return err
	}

	return {}
}

close :: proc(database: ^SQLite_DB) {
	if result := sqlite3_close(database); result != .OK {
		log.error("Could not close database:", result)
	}
}

execute_sql :: proc(database: ^SQLite_DB, sql: cstring) -> Database_Error {
	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	return execute_sql_unlocked(database, sql)
}

// Caller holds this connection's mutex through the entire operation or transaction.
execute_sql_unlocked :: proc(database: ^SQLite_DB, sql: cstring) -> Database_Error {
	if database == nil {
		return make_error(.Execution_Failed, "Database is not open", sqlite_code = .MISUSE)
	}

	result := sqlite3_exec(database, sql, nil, nil, nil)
	if result != .OK {
		return make_error(
			.Execution_Failed,
			string(sqlite3_errmsg(database)),
			sqlite_code = result,
		)
	}

	return {}
}

// Holds the connection mutex until commit_transaction or rollback_transaction.
// A failed BEGIN releases only this call's hold; the caller's transaction is untouched.
begin_immediate :: proc(database: ^SQLite_DB) -> Database_Error {
	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	err := execute_sql_unlocked(database, "BEGIN IMMEDIATE;")
	if err.kind != .None do sqlite3_mutex_leave(mutex)
	return err
}

// Releases the hold taken by begin_immediate. A failed COMMIT is rolled back before the release.
commit_transaction :: proc(database: ^SQLite_DB) -> Database_Error {
	err := execute_sql_unlocked(database, "COMMIT;")
	if err.kind != .None do _ = execute_sql_unlocked(database, "ROLLBACK;")
	sqlite3_mutex_leave(connection_mutex(database))
	return err
}

rollback_transaction :: proc(database: ^SQLite_DB) {
	_ = execute_sql_unlocked(database, "ROLLBACK;")
	sqlite3_mutex_leave(connection_mutex(database))
}

last_insert_rowid :: proc(database: ^SQLite_DB) -> i64 {
	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	if database == nil do return 0
	return sqlite3_last_insert_rowid(database)
}

// A missing row is successful. Callers own logging and must ignore output on error.
query_one :: proc(
	database: ^SQLite_DB,
	sql: cstring,
	parameters: []SQLite_Value,
	output: ^$T,
	decode: proc(statement: ^SQLite_Statement, output: ^T) -> Database_Error,
) -> (
	found: bool,
	err: Database_Error,
) {
	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	if database == nil || sql == nil || output == nil || decode == nil {
		err = make_error(.Execution_Failed, "Invalid query arguments", sqlite_code = .MISUSE)
		return
	}
	statement: ^SQLite_Statement
	result := sqlite3_prepare_v2(database, sql, -1, &statement, nil)
	defer {
		if statement != nil {
			code := sqlite3_finalize(statement)
			if code != .OK {
				if err.kind == .None {
					err = make_error(
						.Execution_Failed,
						"Could not finalize query",
						sqlite_code = code,
					)
				} else if code != err.sqlite_code {
					err.cleanup_code = code
				}
				found = false
			}
		}
	}
	if result != .OK {
		err = make_error(.Execution_Failed, string(sqlite3_errmsg(database)), sqlite_code = result)
		return
	}
	if statement == nil {
		err = make_error(.Execution_Failed, "Empty query", sqlite_code = .MISUSE)
		return
	}
	err = bind_parameters(database, statement, parameters)
	if err.kind != .None do return
	result = sqlite3_step(statement)
	if result == .DONE do return
	if result != .ROW {
		err = make_error(.Execution_Failed, string(sqlite3_errmsg(database)), sqlite_code = result)
		return
	}
	err = decode(statement, output)
	if err.kind != .None do return
	found = true
	return
}
