package sqlite

import "core:fmt"
import "core:mem"
import "core:strings"

// column_text copies into allocator. query_one finalizes the statement before returning.
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
	if err.kind != .None do return
	if !valid do err = null_column(column)

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
	if err = column_index(statement, column); err.kind != .None do return
	if sqlite3_column_type(statement, i32(column)) == .NULL do return

	pointer := sqlite3_column_text(statement, i32(column))
	length := sqlite3_column_bytes(statement, i32(column))
	if pointer == nil {
		err = make_error(.Execution_Failed, "Could not read column text", sqlite_code = .NOMEM)

		return
	}

	cloned, alloc_err := strings.clone(string(pointer[:int(length)]), allocator)
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
	valid: bool
	value, valid, err = column_int_optional(statement, column)
	if err.kind != .None do return
	if !valid do err = null_column(column)

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
	if err = column_index(statement, column); err.kind != .None do return
	if sqlite3_column_type(statement, i32(column)) == .NULL do return

	value = sqlite3_column_int64(statement, i32(column))
	valid = true

	return
}

column_index :: proc(statement: ^SQLite_Statement, column: int) -> (err: Database_Error) {
	if statement == nil {
		return make_error(.Execution_Failed, "SQL statement is required", sqlite_code = .MISUSE)
	}

	count := int(sqlite3_column_count(statement))
	if column < 0 || column >= count {
		err = make_error(.Execution_Failed, "", sqlite_code = .RANGE)
		fmt.bprintf(
			err.message[:len(err.message) - 1],
			"SQL column %d is outside 0 ..< %d",
			column,
			count,
		)
	}

	return
}

null_column :: proc(column: int) -> (err: Database_Error) {
	err = make_error(.Execution_Failed, "", sqlite_code = .MISMATCH)
	fmt.bprintf(err.message[:len(err.message) - 1], "SQL column %d is null", column)

	return
}
