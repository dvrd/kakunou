package sqlite

import "core:fmt"
import "core:mem"
import "core:strings"

column_text :: proc(
	statement: ^SQLite_Statement,
	column: int,
	allocator: mem.Allocator,
) -> (
	text: string,
	err: Database_Error,
) {
	valid: bool
	text, valid, err = column_text_optional(statement, column, allocator)
	if err.kind != .None {
		return
	}
	if !valid {
		err = null_column(column)
	}

	return
}

column_text_optional :: proc(
	statement: ^SQLite_Statement,
	column: int,
	allocator: mem.Allocator,
) -> (
	text: string,
	valid: bool,
	err: Database_Error,
) {
	if err = column_index(statement, column); err.kind != .None {
		return
	}
	if sqlite3_column_type(statement, cast(i32)(column)) == .NULL {
		return
	}

	pointer := sqlite3_column_text(statement, cast(i32)(column))
	length := sqlite3_column_bytes(statement, cast(i32)(column))
	if pointer == nil {
		err = make_error(.Execution_Failed, "Could not read column text", sqlite_code = .NOMEM)

		return
	}

	cloned, alloc_err := strings.clone(cast(string)(pointer[:cast(int)(length)]), allocator)
	if alloc_err != nil {
		err = make_error(.Allocation_Failed, "Could not copy column text", allocator_error = alloc_err)

		return
	}

	text = cloned
	valid = true

	return
}

column_int :: proc(statement: ^SQLite_Statement, column: int) -> (value: i64, err: Database_Error) {
	valid: bool
	value, valid, err = column_int_optional(statement, column)
	if err.kind != .None {
		return
	}
	if !valid {
		err = null_column(column)
	}

	return
}

column_int_optional :: proc(
	statement: ^SQLite_Statement,
	column: int,
) -> (
	value: i64,
	valid: bool,
	err: Database_Error,
) {
	if err = column_index(statement, column); err.kind != .None {
		return
	}
	if sqlite3_column_type(statement, cast(i32)(column)) == .NULL {
		return
	}

	value = sqlite3_column_int64(statement, cast(i32)(column))
	valid = true

	return
}

column_index :: proc(statement: ^SQLite_Statement, column: int) -> (err: Database_Error) {
	if statement == nil {
		return make_error(.Execution_Failed, "SQL statement is required", sqlite_code = .MISUSE)
	}

	count := cast(int)(sqlite3_column_count(statement))

	if column < 0 || column >= count {
		err = make_error(.Execution_Failed, "", sqlite_code = .RANGE)
		fmt.bprintf(err.message[:len(err.message) - 1], "SQL column %d is outside 0 ..< %d", column, count)
	}

	return
}

null_column :: proc(column: int) -> (err: Database_Error) {
	err = make_error(.Execution_Failed, "", sqlite_code = .MISMATCH)
	fmt.bprintf(err.message[:len(err.message) - 1], "SQL column %d is null", column)

	return
}

// Copies a required BLOB because the statement's bytes expire on finalization.
column_blob :: proc(
	statement: ^SQLite_Statement,
	column: int,
	allocator: mem.Allocator,
) -> (
	bytes: []u8,
	err: Database_Error,
) {
	if err = column_index(statement, column); err.kind != .None {
		return
	}
	if sqlite3_column_type(statement, cast(i32)column) != .BLOB {
		return nil, make_error(.Execution_Failed, "Expected a non-null blob", sqlite_code = .MISMATCH)
	}
	length := sqlite3_column_bytes(statement, cast(i32)column)
	pointer := sqlite3_column_blob(statement, cast(i32)column)
	if length > 0 && pointer == nil {
		return nil, make_error(.Execution_Failed, "Could not read blob", sqlite_code = .NOMEM)
	}
	allocation_error: mem.Allocator_Error
	bytes, allocation_error = make([]u8, cast(int)length, allocator)
	if allocation_error != nil {
		return nil, make_error(.Allocation_Failed, "Could not copy blob", allocator_error = allocation_error)
	}
	copy(bytes, (cast([^]u8)pointer)[:cast(int)length])
	return bytes, {}
}

insert :: proc(database: ^SQLite_DB, sql: cstring, parameters: []SQLite_Value) -> (err: Database_Error) {
	if database == nil || sql == nil {
		return make_error(.Execution_Failed, "Database and insert SQL are required", sqlite_code = .MISUSE)
	}

	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	statement: ^SQLite_Statement
	statement, err = prepare(database, sql, "Insert did not contain an SQL statement")
	if err.kind == .None {
		err = insert_statement(database, statement, parameters)
	}
	statement_finalize(statement, &err, "Could not finalize insert")

	return
}

insert_statement :: proc(
	database: ^SQLite_DB,
	statement: ^SQLite_Statement,
	parameters: []SQLite_Value,
) -> Database_Error {
	error := bind_parameters(database, statement, parameters)
	if error.kind != .None {
		return error
	}
	result := sqlite3_step(statement)
	if result == .ROW {
		return make_error(.Execution_Failed, "Insert must not return rows", sqlite_code = result)
	}
	if result != .DONE {
		return make_error(.Execution_Failed, cast(string)sqlite3_errmsg(database), sqlite_code = result)
	}
	return {}
}

bind_parameters :: proc(
	database: ^SQLite_DB,
	statement: ^SQLite_Statement,
	parameters: []SQLite_Value,
) -> Database_Error {
	expected := cast(int)(sqlite3_bind_parameter_count(statement))
	if len(parameters) != expected {
		err := make_error(.Execution_Failed, "", sqlite_code = .RANGE)
		fmt.bprintf(
			err.message[:len(err.message) - 1],
			"SQL statement needs %d parameters, received %d",
			expected,
			len(parameters),
		)

		return err
	}

	for parameter, index in parameters {
		result: SQLite_Result

		switch value in parameter {
		case []u8:
			if len(value) > cast(int)max(i32) {
				return make_error(.Execution_Failed, "Blob exceeds SQLite limit", sqlite_code = .TOOBIG)
			}

			data := raw_data(value)

			if len(value) == 0 {
				data = raw_data(cast(string)"\x00")
			}

			result = sqlite3_bind_blob(statement, cast(i32)(index + 1), data, cast(i32)len(value), nil)
		case i64:
			result = sqlite3_bind_int64(statement, cast(i32)(index + 1), value)
		case cstring:
			result = sqlite3_bind_text(statement, cast(i32)(index + 1), value, -1, nil)
		case:
			return make_error(.Execution_Failed, "Unsupported SQL parameter", sqlite_code = .MISUSE)
		}

		if result != .OK {
			return make_error(.Execution_Failed, cast(string)(sqlite3_errmsg(database)), sqlite_code = result)
		}
	}

	return {}
}

QUERY_ROWS_LIMIT :: 100000

// Rows and decoded fields borrow the caller's temporary allocator. An error
// returns no usable rows; the caller owns that allocator and logging.
query_many :: proc(
	database: ^SQLite_DB,
	sql: cstring,
	parameters: []SQLite_Value,
	decode: proc(statement: ^SQLite_Statement, output: ^$T) -> Database_Error,
	max_rows := 1000,
) -> (
	rows: []T,
	err: Database_Error,
) {
	if database == nil || sql == nil || decode == nil {
		return nil, make_error(.Execution_Failed, "Invalid query arguments", sqlite_code = .MISUSE)
	}
	if max_rows < 1 || max_rows > QUERY_ROWS_LIMIT {
		return nil, make_error(.Execution_Failed, "Invalid query row limit", sqlite_code = .MISUSE)
	}

	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	statement: ^SQLite_Statement
	statement, err = prepare(database, sql, "Empty query")
	if err.kind == .None {
		err = bind_parameters(database, statement, parameters)
	}
	if err.kind == .None {
		rows, err = query_many_rows(database, statement, decode, max_rows)
	}
	if !statement_finalize(statement, &err, "Could not finalize query") {
		rows = nil
	}
	return
}

query_many_rows :: proc(
	database: ^SQLite_DB,
	statement: ^SQLite_Statement,
	decode: proc(statement: ^SQLite_Statement, output: ^$T) -> Database_Error,
	max_rows: int,
) -> (
	[]T,
	Database_Error,
) {
	assert(max_rows > 0)
	assert(max_rows <= QUERY_ROWS_LIMIT)
	// Keep an empty result non-nil so JSON APIs return [] rather than null.
	values, allocation_error := make([dynamic]T, 0, min(8, max_rows), context.temp_allocator)
	if allocation_error != nil {
		return nil, make_error(.Allocation_Failed, "Could not allocate query rows", allocator_error = allocation_error)
	}
	// One extra step distinguishes an exact-limit result from an excess row.
	for row_index in 0 ..< max_rows + 1 {
		result := sqlite3_step(statement)
		if result == .DONE {
			return values[:], {}
		}

		if result != .ROW {
			return nil, make_error(.Execution_Failed, cast(string)sqlite3_errmsg(database), sqlite_code = result)
		}

		if row_index == max_rows {
			return nil, make_error(.Execution_Failed, "Query row limit exceeded", sqlite_code = .TOOBIG)
		}

		row: T

		if error := decode(statement, &row); error.kind != .None {
			return nil, error
		}

		_, allocation_error = append(&values, row)

		if allocation_error != nil {
			return nil, make_error(
				.Allocation_Failed,
				"Could not append query row",
				allocator_error = allocation_error,
			)
		}
	}
	panic("Bounded query must finish or reject its first excess row")
}
