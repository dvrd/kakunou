package sqlite

// Borrowed for the duration of the with_prepared callback.
Prepared_Statement :: distinct ^Prepared_State

@(private)
Prepared_State :: struct {
	database: ^SQLite_DB,
	statement: ^SQLite_Statement,
	mutex: ^SQLite_Mutex,
	parameter_count: int,
	active: bool,
}

with_prepared :: proc(
	database: ^SQLite_DB,
	sql: cstring,
	data: $T,
	body: proc(query: Prepared_Statement, data: T) -> Database_Error,
) -> (err: Database_Error) {
	if database == nil || sql == nil || body == nil {
		return make_error(.Execution_Failed, "Invalid prepared statement arguments", sqlite_code = .MISUSE)
	}
	state := Prepared_State{database = database, mutex = connection_mutex(database)}
	sqlite3_mutex_enter(state.mutex)
	state.statement, err = prepare(database, sql, "Empty prepared statement")
	if err.kind != .None {
		statement_finalize(state.statement, &err, "Could not finalize prepared statement")
		sqlite3_mutex_leave(state.mutex)
		return
	}
	state.parameter_count = int(sqlite3_bind_parameter_count(state.statement))
	sqlite3_mutex_leave(state.mutex)

	err = body(Prepared_Statement(&state), data)

	sqlite3_mutex_enter(state.mutex)
	statement_finalize(state.statement, &err, "Could not finalize prepared statement")
	sqlite3_mutex_leave(state.mutex)
	return
}

prepared_query_one :: #force_inline proc(
	query: Prepared_Statement,
	parameters: []SQLite_Value,
	output: ^$T,
	decode: proc(statement: ^SQLite_Statement, output: ^T) -> Database_Error,
) -> (found: bool, err: Database_Error) {
	if query == nil || output == nil || decode == nil {
		return false, make_error(.Execution_Failed, "Invalid prepared query arguments", sqlite_code = .MISUSE)
	}
	sqlite3_mutex_enter(query.mutex)
	defer sqlite3_mutex_leave(query.mutex)
	if !prepared_start(query, parameters, &err) do return
	borrowed: bool
	if bind_values(query.database, query.statement, parameters, &err, &borrowed) {
		found, err = step_query_one(query.database, query.statement, output, decode)
	}
	prepared_reset(query, borrowed, &err)
	return found && err.kind == .None, err
}

prepared_execute :: #force_inline proc(query: Prepared_Statement, parameters: []SQLite_Value) -> (err: Database_Error) {
	if query == nil {
		return make_error(.Execution_Failed, "Prepared statement is required", sqlite_code = .MISUSE)
	}
	sqlite3_mutex_enter(query.mutex)
	defer sqlite3_mutex_leave(query.mutex)
	if !prepared_start(query, parameters, &err) do return
	borrowed: bool
	if bind_values(query.database, query.statement, parameters, &err, &borrowed) {
		err = step_insert(query.database, query.statement)
	}
	prepared_reset(query, borrowed, &err)
	return
}

@(private)
prepared_start :: #force_inline proc(query: Prepared_Statement, parameters: []SQLite_Value, err: ^Database_Error) -> bool {
	// A row decoder can reenter Kakunou on the same thread.
	if query.active {
		err^ = make_error(.Execution_Failed, "Prepared statement is already active", sqlite_code = .MISUSE)
		return false
	}
	if len(parameters) != query.parameter_count {
		err^ = parameter_count_error(query.parameter_count, len(parameters))
		return false
	}
	query.active = true
	return true
}

@(private)
prepared_reset :: #force_inline proc(query: Prepared_Statement, borrowed: bool, err: ^Database_Error) {
	// Reset can report a deferred write failure. Clear bindings so SQLite
	// releases borrowed text and blob pointers before returning to the caller.
	reset := sqlite3_reset(query.statement)
	clear := SQLite_Result.OK
	if borrowed {
		clear = sqlite3_clear_bindings(query.statement)
	}
	for code in ([2]SQLite_Result{reset, clear}) {
		if code == .OK do continue
		if err.kind == .None {
			err^ = make_error(.Execution_Failed, "Could not reset prepared statement", sqlite_code = code)
		} else if code != err.sqlite_code && err.cleanup_code == .OK {
			err.cleanup_code = code
		}
	}
	query.active = false
}
