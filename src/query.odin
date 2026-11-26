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
		err = make_error(
			.Allocation_Failed,
			"Could not copy column text",
			allocator_error = alloc_err,
		)

		return
	}

	text = cloned
	valid = true

	return
}

column_int :: proc(
	statement: ^SQLite_Statement,
	column: int,
) -> (
	value: i64,
	err: Database_Error,
) {
	integer, status, count := read_column_int(statement, column)
	if status == .Present do return integer, {}
	if status == .Null do return 0, null_column(column)
	return 0, invalid_column_index(statement, column, count)
}

column_int_optional :: proc(
	statement: ^SQLite_Statement,
	column: int,
) -> (
	value: i64,
	valid: bool,
	err: Database_Error,
) {
	integer, status, count := read_column_int(statement, column)
	if status == .Present do return integer, true, {}
	if status == .Null do return 0, false, {}
	return 0, false, invalid_column_index(statement, column, count)
}

@(private)
Integer_Column_State :: enum { Present, Null, Invalid_Index }

@(private)
read_column_int :: proc(statement: ^SQLite_Statement, column: int) -> (value: i64, state: Integer_Column_State, column_count: int) {
	count, in_range := column_bounds(statement, column)
	if !in_range do return 0, .Invalid_Index, count
	index := i32(column)
	if sqlite3_column_type(statement, index) == .NULL do return 0, .Null, count
	return sqlite3_column_int64(statement, index), .Present, count
}

@(private)
column_bounds :: proc(statement: ^SQLite_Statement, column: int) -> (count: int, in_range: bool) {
	if statement == nil do return 0, false
	count = int(sqlite3_column_count(statement))
	return count, column >= 0 && column < count
}

column_index :: proc(statement: ^SQLite_Statement, column: int) -> (err: Database_Error) {
	count, in_range := column_bounds(statement, column)
	if in_range do return {}
	return invalid_column_index(statement, column, count)
}

@(private)
invalid_column_index :: proc(statement: ^SQLite_Statement, column, count: int) -> (err: Database_Error) {
	if statement == nil {
		return make_error(.Execution_Failed, "SQL statement is required", sqlite_code = .MISUSE)
	}
	err = make_error(.Execution_Failed, "", sqlite_code = .RANGE)
	fmt.bprintf(err.message[:len(err.message) - 1], "SQL column %d is outside 0 ..< %d", column, count)
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
		return nil, make_error(
			.Execution_Failed,
			"Expected a non-null blob",
			sqlite_code = .MISMATCH,
		)
	}

	length := sqlite3_column_bytes(statement, cast(i32)column)
	pointer := sqlite3_column_blob(statement, cast(i32)column)
	if length > 0 && pointer == nil {
		return nil, make_error(.Execution_Failed, "Could not read blob", sqlite_code = .NOMEM)
	}

	allocation_error: mem.Allocator_Error
	bytes, allocation_error = make([]u8, cast(int)length, allocator)
	if allocation_error != nil {
		return nil, make_error(
			.Allocation_Failed,
			"Could not copy blob",
			allocator_error = allocation_error,
		)
	}

	copy(bytes, (cast([^]u8)pointer)[:cast(int)length])

	return bytes, {}
}

insert :: proc(
	database: ^SQLite_DB,
	sql: cstring,
	parameters: []SQLite_Value,
) -> (
	err: Database_Error,
) {
	if database == nil || sql == nil {
		return make_error(
			.Execution_Failed,
			"Database and insert SQL are required",
			sqlite_code = .MISUSE,
		)
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

// Execute one no-result statement per row. Earlier rows may remain on error;
// wrap the batch in with_transaction when all rows must succeed together.
insert_many :: proc(
	database: ^SQLite_DB,
	sql: cstring,
	rows: [][$N]SQLite_Value,
) -> (err: Database_Error) {
	if database == nil || sql == nil {
		return make_error(.Execution_Failed, "Database and insert SQL are required", sqlite_code = .MISUSE)
	}

	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	statement: ^SQLite_Statement
	statement, err = prepare(database, sql, "Insert did not contain an SQL statement")
	if err.kind == .None {
		expected := int(sqlite3_bind_parameter_count(statement))
		if expected != N {
			err = parameter_count_error(expected, N)
		} else if sqlite3_column_count(statement) != 0 {
			err = insert_returns_rows()
		}
	}
	if err.kind == .None {
		for &row in rows {
			if !bind_values(database, statement, row[:], &err) do break
			result := sqlite3_step(statement)
			if result != .DONE {
				err = sqlite_failure(database, result)
				break
			}
			result = sqlite3_reset(statement)
			if result != .OK {
				err = sqlite_failure(database, result)
				break
			}
		}
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

	return step_insert(database, statement)
}

@(private)
step_insert :: proc(database: ^SQLite_DB, statement: ^SQLite_Statement) -> Database_Error {
	// Step reports SQLITE_ROW only after the write, and finalize then commits it.
	if sqlite3_column_count(statement) != 0 {
		return insert_returns_rows()
	}

	result := sqlite3_step(statement)
	if result != .DONE {
		return sqlite_failure(database, result)
	}

	return {}
}

@(private)
insert_returns_rows :: proc() -> Database_Error {
	return make_error(.Execution_Failed, "Insert must not return rows", sqlite_code = .MISUSE)
}

@(private)
parameter_count_error :: proc(expected, actual: int) -> (err: Database_Error) {
	err = make_error(.Execution_Failed, "", sqlite_code = .RANGE)
	fmt.bprintf(err.message[:len(err.message) - 1],
	            "SQL statement needs %d parameters, received %d", expected, actual)
	return
}

bind_parameters :: proc(
	database: ^SQLite_DB,
	statement: ^SQLite_Statement,
	parameters: []SQLite_Value,
) -> (err: Database_Error) {
	expected := int(sqlite3_bind_parameter_count(statement))
	if len(parameters) != expected {
		return parameter_count_error(expected, len(parameters))
	}
	bind_values(database, statement, parameters, &err)
	return
}

@(private)
bind_values :: proc(
	database: ^SQLite_DB,
	statement: ^SQLite_Statement,
	parameters: []SQLite_Value,
	err: ^Database_Error,
	borrowed: ^bool = nil,
) -> bool {
	for parameter, index in parameters {
		result: SQLite_Result

		switch value in parameter {
		case []u8:
			if len(value) > cast(int)max(i32) {
				err^ = make_error(
					.Execution_Failed,
					"Blob exceeds SQLite limit",
					sqlite_code = .TOOBIG,
				)
				return false
			}

			data := raw_data(value)

			if len(value) == 0 {
				data = raw_data(cast(string)"\x00")
			}

			if borrowed != nil do borrowed^ = true
			result = sqlite3_bind_blob(
				statement,
				cast(i32)(index + 1),
				data,
				cast(i32)len(value),
				nil,
			)
		case i64:
			result = sqlite3_bind_int64(statement, cast(i32)(index + 1), value)
		case cstring:
			if borrowed != nil do borrowed^ = true
			result = sqlite3_bind_text(statement, cast(i32)(index + 1), value, -1, nil)
		case:
			err^ = make_error(
				.Execution_Failed,
				"Unsupported SQL parameter",
				sqlite_code = .MISUSE,
			)
			return false
		}

		if result != .OK {
			err^ = sqlite_failure(database, result)
			return false
		}
	}

	return true
}

QUERY_ROWS_LIMIT :: 100000

// Rows and decoded fields borrow the caller's temporary allocator. An error
// returns no usable rows; the caller owns that allocator and logging.
// A write with RETURNING may already have taken effect when decoding or the
// row limit fails. Use an explicit transaction to roll back on those errors.
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
		return nil, make_error(
			.Allocation_Failed,
			"Could not allocate query rows",
			allocator_error = allocation_error,
		)
	}

	// One extra step distinguishes an exact-limit result from an excess row.
	for row_index in 0 ..< max_rows + 1 {
		result := sqlite3_step(statement)
		if result == .DONE {
			return values[:], {}
		}

		if result != .ROW {
			return nil, sqlite_failure(database, result)
		}

		if row_index == max_rows {
			return nil, make_error(
				.Execution_Failed,
				"Query row limit exceeded",
				sqlite_code = .TOOBIG,
			)
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
