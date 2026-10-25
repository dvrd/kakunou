package sqlite


// Rows borrow the caller's temporary allocator; callers log returned errors.
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
	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)
	statement: ^SQLite_Statement
	result := sqlite3_prepare_v2(database, sql, -1, &statement, nil)
	if result != .OK do return nil, make_error(.Execution_Failed, string(sqlite3_errmsg(database)), sqlite_code = result)
	if statement == nil do return nil, make_error(.Execution_Failed, "Empty query")
	defer {
		code := sqlite3_finalize(statement)
		if code != .OK && err.kind == .None do err = make_error(.Execution_Failed, "Could not finalize query", sqlite_code = code)
	}
	err = bind_parameters(database, statement, parameters)
	if err.kind != .None do return
	// Keep an empty result non-nil so JSON APIs return [] rather than null.
	values, allocation_error := make([dynamic]T, 0, 8, context.temp_allocator)
	if allocation_error != nil do return nil, make_error(.Allocation_Failed, "Could not allocate query rows", allocator_error = allocation_error)
	for {
		result = sqlite3_step(statement)
		if result == .DONE {rows = values[:];return}
		if result != .ROW do return nil, make_error(.Execution_Failed, string(sqlite3_errmsg(database)), sqlite_code = result)
		if len(values) >= max_rows do return nil, make_error(.Execution_Failed, "Query row limit exceeded")
		row: T
		err = decode(statement, &row)
		if err.kind != .None do return
		_, allocation_error := append(&values, row)
		if allocation_error != nil do return nil, make_error(.Allocation_Failed, "Could not allocate query rows", allocator_error = allocation_error)
	}
}
