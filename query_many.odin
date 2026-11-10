package sqlite


QUERY_ROWS_LIMIT :: 100000

// Rows and decoded fields borrow the caller's temporary allocator. An error
// returns no usable rows; the caller owns that allocator and logging.
query_many :: proc(
	database: ^SQLite_DB,
	sql: cstring,
	parameters: []SQLite_Value,
	decode: proc(statement: ^SQLite_Statement, output: ^$T) -> Database_Error,
	max_rows := 1000,
) -> (rows: []T, err: Database_Error) {
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
	result := sqlite3_prepare_v2(database, sql, -1, &statement, nil)

	if result != .OK {
		err = make_error(
			.Execution_Failed, cast(string)sqlite3_errmsg(database), sqlite_code = result,
		)
	} else if statement == nil {
		err = make_error(.Execution_Failed, "Empty query", sqlite_code = .MISUSE)
	} else {
		err = bind_parameters(database, statement, parameters)
		if err.kind == .None {
			rows, err = query_many_rows(database, statement, decode, max_rows)
		}
	}
	if !statement_finalize(statement, &err, "Could not finalize query") do rows = nil
	return

}

query_many_rows :: proc(
	database: ^SQLite_DB,
	statement: ^SQLite_Statement,
	decode: proc(statement: ^SQLite_Statement, output: ^$T) -> Database_Error,
	max_rows: int,
) -> ([]T, Database_Error) {
	assert(max_rows > 0)
	assert(max_rows <= QUERY_ROWS_LIMIT)
	// Keep an empty result non-nil so JSON APIs return [] rather than null.
	values, allocation_error := make([dynamic]T, 0, min(8, max_rows), context.temp_allocator)
	if allocation_error != nil {
		return nil, make_error(
			.Allocation_Failed, "Could not allocate query rows", allocator_error = allocation_error,
		)
	}
	// One extra step distinguishes an exact-limit result from an excess row.
	for row_index in 0 ..< max_rows + 1 {
		result := sqlite3_step(statement)
		if result == .DONE do return values[:], {}
		if result != .ROW {
			return nil, make_error(
				.Execution_Failed, cast(string)sqlite3_errmsg(database), sqlite_code = result,
			)
		}
		if row_index == max_rows {
			return nil, make_error(
				.Execution_Failed, "Query row limit exceeded", sqlite_code = .TOOBIG,
			)
		}
		row: T
		if error := decode(statement, &row); error.kind != .None do return nil, error
		if len(values) == cap(values) {
			capacity := min(max_rows, cap(values) * 2)
			allocation_error = reserve(&values, capacity)
			if allocation_error != nil {
				return nil, make_error(
					.Allocation_Failed, "Could not grow query rows",
					allocator_error = allocation_error,
				)
			}
		}
		_, allocation_error = append(&values, row)
		if allocation_error != nil {
			return nil, make_error(
				.Allocation_Failed, "Could not append query row",
				allocator_error = allocation_error,
			)
		}
	}
	panic("Bounded query must finish or reject its first excess row")
}
