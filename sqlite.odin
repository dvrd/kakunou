package sqlite

import "core:log"
import "core:mem"
import "core:strings"

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
	[]u8,
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

	sqlite3_open_v2 :: proc "c" (
		filename: cstring,
		database: ^^SQLite_DB,
		flags: i32,
		vfs: cstring,
	) -> SQLite_Result ---

	sqlite3_close :: proc "c" (database: ^SQLite_DB) -> SQLite_Result ---

	sqlite3_errmsg :: proc "c" (database: ^SQLite_DB) -> cstring ---
	sqlite3_get_autocommit :: proc "c" (database: ^SQLite_DB) -> i32 ---

	sqlite3_prepare_v2 :: proc "c" (
		database: ^SQLite_DB,
		sql: cstring,
		byte_count: i32,
		statement: ^^SQLite_Statement,
		tail: ^cstring,
	) -> SQLite_Result ---

	sqlite3_bind_text :: proc "c" (
		statement: ^SQLite_Statement,
		index: i32,
		value: cstring,
		byte_count: i32,
		destructor: proc "c" (data: rawptr),
	) -> SQLite_Result ---

	sqlite3_bind_blob :: proc "c" (
		statement: ^SQLite_Statement,
		index: i32,
		value: rawptr,
		byte_count: i32,
		destructor: rawptr,
	) -> SQLite_Result ---

	sqlite3_column_blob :: proc "c" (statement: ^SQLite_Statement, column: i32) -> rawptr ---

	sqlite3_bind_int64 :: proc "c" (
		statement: ^SQLite_Statement,
		index: i32,
		value: i64,
	) -> SQLite_Result ---

	sqlite3_bind_parameter_count :: proc "c" (statement: ^SQLite_Statement) -> i32 ---

	sqlite3_column_text :: proc "c" (statement: ^SQLite_Statement, column: i32) -> [^]u8 ---

	sqlite3_column_int64 :: proc "c" (statement: ^SQLite_Statement, column: i32) -> i64 ---

	sqlite3_column_bytes :: proc "c" (statement: ^SQLite_Statement, column: i32) -> i32 ---

	sqlite3_column_type :: proc "c" (
		statement: ^SQLite_Statement,
		column: i32,
	) -> SQLite_Column_Type ---

	sqlite3_column_count :: proc "c" (statement: ^SQLite_Statement) -> i32 ---

	sqlite3_step :: proc "c" (statement: ^SQLite_Statement) -> SQLite_Result ---

	sqlite3_exec :: proc "c" (
		database: ^SQLite_DB,
		sql: cstring,
		callback: proc "c" (
			data: rawptr,
			coulmn_count: i32,
			values: [^]cstring,
			names: [^]cstring,
		) -> SQLite_Result,
		data: rawptr,
		error_message: ^cstring,
	) -> SQLite_Result ---

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
			path = cast(string)(path),
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
			message = cast(string)(sqlite3_errmsg(database^))
		}

		if mutex_missing {
			message = "SQLite connection serialization is required"
			result = .MISUSE
		}
		err := make_error(.Open_Failed, message, sqlite_code = result, path = cast(string)(path))

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
			cast(string)(sqlite3_errmsg(database)),
			sqlite_code = result,
		)
	}

	return {}
}

// Successful BEGIN transfers one recursive connection-mutex hold to the caller.
// The caller must finish exactly once with commit_transaction or rollback_transaction.
// A failed BEGIN releases only this call's hold; the caller's transaction is untouched.
begin_immediate :: proc(database: ^SQLite_DB) -> Database_Error {
	return begin(database, "BEGIN IMMEDIATE;")
}

// Same ownership contract as begin_immediate, without taking the write lock.
begin_read :: proc(database: ^SQLite_DB) -> Database_Error {
	return begin(database, "BEGIN")
}

@(private)
begin :: proc(database: ^SQLite_DB, sql: cstring) -> Database_Error {
	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	err := execute_sql_unlocked(database, sql)
	if err.kind != .None do sqlite3_mutex_leave(mutex)
	return err
}

// Consumes the transaction hold on BOTH success and failure. Failed COMMIT is
// rolled back internally before releasing the mutex. Callers must clear their
// transaction-owned flag before this call and must never roll back its failure.
commit_transaction :: proc(database: ^SQLite_DB) -> Database_Error {
	err := execute_sql_unlocked(database, "COMMIT;")
	if err.kind != .None && (database == nil || sqlite3_get_autocommit(database) == 0) {
		cleanup := execute_sql_unlocked(database, "ROLLBACK;")
		if cleanup.kind != .None do err.cleanup_code = cleanup.sqlite_code
	}
	sqlite3_mutex_leave(connection_mutex(database))
	return err
}

// Consumes a still-owned BEGIN hold exactly once. This void API logs cleanup
// failures because it cannot attach them to a caller's primary operational error.
rollback_transaction :: proc(database: ^SQLite_DB) {
	// Statement errors may already have rolled SQLite back. The caller still
	// owns its connection-mutex hold, which this terminal call consumes once.
	if database == nil || sqlite3_get_autocommit(database) == 0 {
		if err := execute_sql_unlocked(database, "ROLLBACK;"); err.kind != .None {
			log_error(err, "Could not roll back transaction")
		}
	}
	sqlite3_mutex_leave(connection_mutex(database))
}

last_insert_rowid :: proc(database: ^SQLite_DB) -> i64 {
	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	if database == nil do return 0
	return sqlite3_last_insert_rowid(database)
}

// Caller holds the connection mutex. A nil statement with no error means the
// SQL held no statement; empty names that case in the returned error.
@(private)
prepare :: proc(
	database: ^SQLite_DB,
	sql: cstring,
	empty: string,
) -> (statement: ^SQLite_Statement, err: Database_Error) {
	result := sqlite3_prepare_v2(database, sql, -1, &statement, nil)
	if result != .OK {
		err = make_error(
			.Execution_Failed, cast(string)sqlite3_errmsg(database), sqlite_code = result,
		)
	} else if statement == nil {
		err = make_error(.Execution_Failed, empty, sqlite_code = .MISUSE)
	}
	return
}

// Finalize before taking a return-value snapshot. Odin defers cannot modify a
// returned error, so cleanup diagnostics must be attached in explicit control flow.
statement_finalize :: proc(
	statement: ^SQLite_Statement,
	error: ^Database_Error,
	message: string,
) -> bool {
	assert(error != nil)
	if statement == nil do return true
	code := sqlite3_finalize(statement)
	if code == .OK do return true
	if error.kind == .None {
		error^ = make_error(.Execution_Failed, message, sqlite_code = code)
	} else if code != error.sqlite_code {
		error.cleanup_code = code
	}
	return false
}

// A missing row is successful. Callers own logging and must ignore output on error.
query_one :: proc(
	database: ^SQLite_DB,
	sql: cstring,
	parameters: []SQLite_Value,
	output: ^$T,
	decode: proc(statement: ^SQLite_Statement, output: ^T) -> Database_Error,
) -> (found: bool, err: Database_Error) {
	if database == nil || sql == nil || output == nil || decode == nil {
		return false, make_error(
			.Execution_Failed, "Invalid query arguments", sqlite_code = .MISUSE,
		)
	}
	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	statement: ^SQLite_Statement
	statement, err = prepare(database, sql, "Empty query")
	if err.kind == .None {
		found, err = query_one_row(database, statement, parameters, output, decode)
	}
	if !statement_finalize(statement, &err, "Could not finalize query") do found = false
	return
}

query_one_row :: proc(
	database: ^SQLite_DB,
	statement: ^SQLite_Statement,
	parameters: []SQLite_Value,
	output: ^$T,
	decode: proc(statement: ^SQLite_Statement, output: ^T) -> Database_Error,
) -> (bool, Database_Error) {
	error := bind_parameters(database, statement, parameters)
	if error.kind != .None do return false, error
	result := sqlite3_step(statement)
	if result == .DONE do return false, {}
	if result != .ROW {
		return false, make_error(
			.Execution_Failed, cast(string)sqlite3_errmsg(database), sqlite_code = result,
		)
	}
	error = decode(statement, output)
	return error.kind == .None, error
}

Database_Error_Kind :: enum {
	None,
	Open_Failed,
	Invalid_Schema,
	Allocation_Failed,
	Execution_Failed,
}

// Diagnostic text is owned by the error and survives SQLite cleanup and copying.
// Buffers include a trailing NUL; longer diagnostic text is truncated.
Database_Error :: struct {
	kind:            Database_Error_Kind,
	sqlite_code:     SQLite_Result,
	allocator_error: mem.Allocator_Error,
	cleanup_code:    SQLite_Result,
	message:         [512]u8,
	path:            [1024]u8,
	table:           [256]u8,
}

make_error :: proc(
	kind: Database_Error_Kind,
	message: string,
	sqlite_code: SQLite_Result = .OK,
	allocator_error: mem.Allocator_Error = nil,
	path: string = "",
	table: string = "",
) -> Database_Error {
	err := Database_Error {
		kind            = kind,
		sqlite_code     = sqlite_code,
		allocator_error = allocator_error,
	}
	copy(err.message[:len(err.message) - 1], message)
	copy(err.path[:len(err.path) - 1], path)
	copy(err.table[:len(err.table) - 1], table)

	return err
}

// The returned string borrows the supplied error's buffer.
error_text :: proc(buffer: []u8) -> string {
	text := cast(string)(buffer)
	if end := strings.index_byte(text, 0); end >= 0 do text = text[:end]

	return text
}

log_error :: proc(err: Database_Error, operation := "Database operation failed") {
	if err.kind == .None do return

	diagnostic := err

	log.errorf(
		"%s | kind=%v path=%s table=%s sqlite_code=%v " +
		"allocator_error=%v cleanup_code=%v message=%s",
		operation,
		err.kind,
		error_text(diagnostic.path[:]),
		error_text(diagnostic.table[:]),
		err.sqlite_code,
		err.allocator_error,
		err.cleanup_code,
		error_text(diagnostic.message[:]),
	)
}
