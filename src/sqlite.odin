package sqlite

import "core:log"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

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

// open installs this wait on every connection. A second connection otherwise
// receives SQLITE_BUSY immediately, and Saba only passes the handle through.
BUSY_TIMEOUT_MILLISECONDS :: 5000

foreign sqlite {
	sqlite3_busy_timeout :: proc "c" (database: ^SQLite_DB, milliseconds: i32) -> SQLite_Result ---
	sqlite3_changes :: proc "c" (database: ^SQLite_DB) -> i32 ---
	sqlite3_db_mutex :: proc "c" (database: ^SQLite_DB) -> ^SQLite_Mutex ---
	sqlite3_mutex_enter :: proc "c" (mutex: ^SQLite_Mutex) ---
	sqlite3_mutex_leave :: proc "c" (mutex: ^SQLite_Mutex) ---

	sqlite3_open_v2 :: proc "c" (filename: cstring, database: ^^SQLite_DB, flags: i32, vfs: cstring) -> SQLite_Result ---

	sqlite3_close :: proc "c" (database: ^SQLite_DB) -> SQLite_Result ---

	sqlite3_errmsg :: proc "c" (database: ^SQLite_DB) -> cstring ---
	sqlite3_get_autocommit :: proc "c" (database: ^SQLite_DB) -> i32 ---

	sqlite3_prepare_v2 :: proc "c" (database: ^SQLite_DB, sql: cstring, byte_count: i32, statement: ^^SQLite_Statement, tail: ^cstring) -> SQLite_Result ---

	sqlite3_bind_text :: proc "c" (statement: ^SQLite_Statement, index: i32, value: cstring, byte_count: i32, destructor: proc "c" (data: rawptr)) -> SQLite_Result ---

	sqlite3_bind_blob :: proc "c" (statement: ^SQLite_Statement, index: i32, value: rawptr, byte_count: i32, destructor: rawptr) -> SQLite_Result ---

	sqlite3_column_blob :: proc "c" (statement: ^SQLite_Statement, column: i32) -> rawptr ---

	sqlite3_bind_int64 :: proc "c" (statement: ^SQLite_Statement, index: i32, value: i64) -> SQLite_Result ---

	sqlite3_bind_parameter_count :: proc "c" (statement: ^SQLite_Statement) -> i32 ---

	sqlite3_column_text :: proc "c" (statement: ^SQLite_Statement, column: i32) -> [^]u8 ---

	sqlite3_column_int64 :: proc "c" (statement: ^SQLite_Statement, column: i32) -> i64 ---

	sqlite3_column_bytes :: proc "c" (statement: ^SQLite_Statement, column: i32) -> i32 ---

	sqlite3_column_type :: proc "c" (statement: ^SQLite_Statement, column: i32) -> SQLite_Column_Type ---

	sqlite3_column_count :: proc "c" (statement: ^SQLite_Statement) -> i32 ---

	sqlite3_step :: proc "c" (statement: ^SQLite_Statement) -> SQLite_Result ---

	sqlite3_exec :: proc "c" (database: ^SQLite_DB, sql: cstring, callback: proc "c" (data: rawptr, column_count: i32, values: [^]cstring, names: [^]cstring) -> SQLite_Result, data: rawptr, error_message: ^cstring) -> SQLite_Result ---

	sqlite3_finalize :: proc "c" (statement: ^SQLite_Statement) -> SQLite_Result ---

	sqlite3_last_insert_rowid :: proc "c" (database: ^SQLite_DB) -> i64 ---

	sqlite3_backup_init :: proc "c" (destination: ^SQLite_DB, destination_name: cstring, source: ^SQLite_DB, source_name: cstring) -> ^SQLite_Backup ---
	sqlite3_backup_step :: proc "c" (backup: ^SQLite_Backup, pages: i32) -> SQLite_Result ---
	sqlite3_backup_finish :: proc "c" (backup: ^SQLite_Backup) -> SQLite_Result ---
}

// SQLite owns this recursive mutex for the lifetime of a FULLMUTEX connection.
// A nil mutex is a no-op for SQLite's enter/leave routines, preserving nil-handle errors.
connection_mutex :: proc(database: ^SQLite_DB) -> ^SQLite_Mutex {
	if database == nil {
		return nil
	}

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
			subject = cast(string)(path),
		)
	}

	result := sqlite3_open_v2(
		path,
		database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
		nil,
	)

	mutex_missing := result == .OK && connection_mutex(database^) == nil

	if result == .OK && !mutex_missing {
		result = sqlite3_busy_timeout(database^, BUSY_TIMEOUT_MILLISECONDS)
	}

	if result != .OK || mutex_missing {
		message := "Could not allocate database connection"

		if database^ != nil {
			message = cast(string)(sqlite3_errmsg(database^))
		}

		if mutex_missing {
			message = "SQLite connection serialization is required"
			result = .MISUSE
		}

		err := make_error(
			.Open_Failed,
			message,
			sqlite_code = result,
			subject = cast(string)(path),
		)

		if database^ != nil {
			err.cleanup_code = sqlite3_close(database^)
			if err.cleanup_code == .OK {
				database^ = nil
			}
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
		return sqlite_failure(database, result)
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

// Accept a single BEGIN statement. SQLite parses the transaction mode and optional name.
begin :: proc(database: ^SQLite_DB, sql: cstring) -> Database_Error {
	if database == nil {
		return make_error(.Execution_Failed, "Database is not open", sqlite_code = .MISUSE)
	}
	first := skip_sql_empty_statements(string(sql))
	if end := strings.index_any(first, " \t\r\n\f;/-"); end >= 0 {
		first = first[:end]
	}
	if !strings.equal_fold(first, "BEGIN") {
		return make_error(.Execution_Failed, "Expected a BEGIN statement", sqlite_code = .MISUSE)
	}

	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	was_autocommit := sqlite3_get_autocommit(database) != 0
	statement, err := prepare(database, sql, "Expected a BEGIN statement")
	if err.kind == .None {
		result := sqlite3_step(statement)
		if result != .DONE {
			err = sqlite_failure(database, result)
		}
	}
	statement_finalize(statement, &err, "Could not finalize BEGIN")
	// An authorizer can ignore BEGIN while SQLite still reports DONE.
	if err.kind == .None && (!was_autocommit || sqlite3_get_autocommit(database) != 0) {
		err = make_error(.Execution_Failed, "BEGIN did not start a transaction", sqlite_code = .ERROR)
	}
	if err.kind != .None {
		sqlite3_mutex_leave(mutex)
	}

	return err
}

// The callback borrows the transaction on this thread. Only this helper finishes it.
with_transaction :: proc(
	database: ^SQLite_DB,
	data: $T,
	body: proc(database: ^SQLite_DB, data: T) -> Database_Error,
	begin_sql: cstring = "BEGIN IMMEDIATE",
) -> Database_Error {
	if body == nil {
		return make_error(.Execution_Failed, "Transaction callback is required", sqlite_code = .MISUSE)
	}
	if err := begin(database, begin_sql); err.kind != .None {
		return err
	}
	err := body(database, data)
	if err.kind == .None {
		return commit_transaction(database)
	}
	cleanup := rollback_owned_transaction(database)
	if cleanup.kind != .None {
		if err.cleanup_code == .OK {
			err.cleanup_code = cleanup.sqlite_code
		} else {
			log_error(cleanup, "Could not roll back transaction")
		}
	}
	return err
}

// Consumes the transaction hold on BOTH success and failure. Failed COMMIT is
// rolled back internally before releasing the mutex. Callers must clear their
// transaction-owned flag before this call and must never roll back its failure.
commit_transaction :: proc(database: ^SQLite_DB) -> Database_Error {
	err := execute_sql_unlocked(database, "COMMIT;")

	if err.kind == .None && sqlite3_get_autocommit(database) == 0 {
		// An authorizer may ignore COMMIT and leave the transaction active.
		err = make_error(.Execution_Failed, "COMMIT did not end the transaction", sqlite_code = .ERROR)
	}
	if err.kind != .None {
		if cleanup := rollback_owned_transaction(database); cleanup.kind != .None {
			err.cleanup_code = cleanup.sqlite_code
		}
	} else {
		sqlite3_mutex_leave(connection_mutex(database))
	}
	return err
}

// Consumes one successful BEGIN even when SQLite already rolled the transaction back.
@(private)
rollback_owned_transaction :: proc(database: ^SQLite_DB) -> (err: Database_Error) {
	defer sqlite3_mutex_leave(connection_mutex(database))
	if database == nil || sqlite3_get_autocommit(database) == 0 {
		err = execute_sql_unlocked(database, "ROLLBACK;")
		if err.kind == .None && sqlite3_get_autocommit(database) == 0 {
			err = make_error(.Execution_Failed, "ROLLBACK did not end the transaction", sqlite_code = .ERROR)
		}
	}
	return
}

rollback_transaction :: proc(database: ^SQLite_DB) {
	if err := rollback_owned_transaction(database); err.kind != .None {
		log_error(err, "Could not roll back transaction")
	}
}

last_insert_rowid :: proc(database: ^SQLite_DB) -> i64 {
	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	if database == nil {
		return 0
	}

	return sqlite3_last_insert_rowid(database)
}

// Caller holds the connection mutex. A nil statement with no error means the
// SQL held no statement; empty names that case in the returned error.
// These helpers prepare one statement. A second statement is rejected before
// execution, and the caller still finalizes the prepared statement.
prepare :: proc(
	database: ^SQLite_DB,
	sql: cstring,
	empty: string,
) -> (
	statement: ^SQLite_Statement,
	err: Database_Error,
) {
	tail: cstring
	result := sqlite3_prepare_v2(database, sql, -1, &statement, &tail)
	if result != .OK {
		err = sqlite_failure(database, result)
	} else if statement == nil {
		err = make_error(.Execution_Failed, empty, sqlite_code = .MISUSE)
	} else if sql_tail_has_statement(tail) {
		err = make_error(
			.Execution_Failed,
			"SQL contains more than one statement",
			sqlite_code = .MISUSE,
		)
	}

	return
}

// SQLite leaves the unparsed tail, including the trailing NUL. Whitespace,
// comments, and semicolon-only statements are not another statement. Block
// comments end at the first closer; a missing closer is rejected.
sql_tail_has_statement :: proc(tail: cstring) -> bool {
	if tail == nil {
		return false
	}

	return len(skip_sql_empty_statements(string(tail))) > 0
}

@(private)
skip_sql_empty_statements :: proc(sql: string) -> string {
	rest := skip_sql_trivia(sql)
	for len(rest) > 0 && rest[0] == ';' {
		rest = skip_sql_trivia(rest[1:])
	}

	return rest
}

skip_sql_trivia :: proc(sql: string) -> string {
	rest := sql
	for len(rest) > 0 {
		switch rest[0] {
		case ' ', '\t', '\n', '\r', '\f':
			// SQLite accepts a vertical tab only inside a whitespace token.
			rest = rest[1:]
			for len(rest) > 0 && rest[0] == '\v' {
				rest = rest[1:]
			}
		case 0xef:
			if !strings.has_prefix(rest, "\ufeff") {
				return rest
			}
			rest = rest[len("\ufeff"):]
		case '-':
			if len(rest) < 2 || rest[1] != '-' {
				return rest
			}

			rest = rest[2:]
			for len(rest) > 0 && rest[0] != '\n' {
				rest = rest[1:]
			}
		case '/':
			if len(rest) < 2 || rest[1] != '*' {
				return rest
			}

			remainder, closed := skip_sql_block_comment(rest[2:])
			if !closed {
				return rest
			}

			rest = remainder
		case:
			return rest
		}
	}

	return rest
}

skip_sql_block_comment :: proc(body: string) -> (rest: string, closed: bool) {
	end := strings.index(body, "*/")
	if end < 0 {
		return body, false
	}
	return body[end + 2:], true
}

// Finalize before taking a return-value snapshot. Odin defers cannot modify a
// returned error, so cleanup diagnostics must be attached in explicit control flow.
statement_finalize :: proc(
	statement: ^SQLite_Statement,
	error: ^Database_Error,
	message: string,
) -> bool {
	assert(error != nil)
	if statement == nil {
		return true
	}

	code := sqlite3_finalize(statement)
	if code == .OK {
		return true
	}

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
) -> (
	found: bool,
	err: Database_Error,
) {
	if database == nil || sql == nil || output == nil || decode == nil {
		return false, make_error(
			.Execution_Failed,
			"Invalid query arguments",
			sqlite_code = .MISUSE,
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

	if !statement_finalize(statement, &err, "Could not finalize query") {
		found = false
	}

	return
}

query_one_row :: proc(
	database: ^SQLite_DB,
	statement: ^SQLite_Statement,
	parameters: []SQLite_Value,
	output: ^$T,
	decode: proc(statement: ^SQLite_Statement, output: ^T) -> Database_Error,
) -> (
	bool,
	Database_Error,
) {
	error := bind_parameters(database, statement, parameters)
	if error.kind != .None {
		return false, error
	}

	result := sqlite3_step(statement)
	if result == .DONE {
		return false, {}
	}

	if result != .ROW {
		return false, sqlite_failure(database, result)
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

ERROR_MESSAGE_CAPACITY :: 192
ERROR_SUBJECT_CAPACITY :: 96

// Diagnostic text lives inline in the error: no heap, no borrowed pointers, so
// copies outlive SQLite cleanup and the caller's strings. `message` is the
// explanation; `subject` names the table or file the failure concerns. Both
// include a trailing NUL and truncate longer text. The struct stays near 300
// bytes; read the text with error_message/error_subject.
Database_Error :: struct {
	kind:            Database_Error_Kind,
	sqlite_code:     SQLite_Result,
	allocator_error: mem.Allocator_Error,
	cleanup_code:    SQLite_Result,
	message:         [ERROR_MESSAGE_CAPACITY]u8,
	subject:         [ERROR_SUBJECT_CAPACITY]u8,
}

@(private)
copy_diagnostic :: proc(buffer: []u8, text: string) {
	n := min(len(text), len(buffer) - 1)
	if n < len(text) {
		for n > 0 && !utf8.rune_start(text[n]) {
			n -= 1
		}
	}
	copy(buffer[:n], text[:n])
	buffer[n] = 0
}

make_error :: proc(
	kind: Database_Error_Kind,
	message: string,
	sqlite_code: SQLite_Result = .OK,
	allocator_error: mem.Allocator_Error = nil,
	subject: string = "",
) -> Database_Error {
	err := Database_Error {
		kind            = kind,
		sqlite_code     = sqlite_code,
		allocator_error = allocator_error,
	}

	copy_diagnostic(err.message[:], message)
	copy_diagnostic(err.subject[:], subject)

	return err
}

// SQLite's message is only valid until the next call on the connection, so it
// is copied into the error immediately.
sqlite_failure :: proc(database: ^SQLite_DB, code: SQLite_Result) -> Database_Error {
	return make_error(.Execution_Failed, cast(string)sqlite3_errmsg(database), sqlite_code = code)
}

// The returned strings borrow the supplied error.
error_message :: proc(err: ^Database_Error) -> string {
	return strings.truncate_to_byte(cast(string)err.message[:], 0)
}

error_subject :: proc(err: ^Database_Error) -> string {
	return strings.truncate_to_byte(cast(string)err.subject[:], 0)
}

log_error :: proc(err: Database_Error, operation := "Database operation failed") {
	if err.kind == .None {
		return
	}

	diagnostic := err

	log.errorf(
		"%s | kind=%v subject=%s sqlite_code=%v allocator_error=%v cleanup_code=%v message=%s",
		operation,
		err.kind,
		error_subject(&diagnostic),
		err.sqlite_code,
		err.allocator_error,
		err.cleanup_code,
		error_message(&diagnostic),
	)
}
