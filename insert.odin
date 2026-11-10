package sqlite


insert :: proc(
	database: ^SQLite_DB,
	sql: cstring,
	parameters: []SQLite_Value,
) -> (err: Database_Error) {
	if database == nil || sql == nil {
		return make_error(
			.Execution_Failed, "Database and insert SQL are required", sqlite_code = .MISUSE,
		)
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
		err = make_error(
			.Execution_Failed, "Insert did not contain an SQL statement", sqlite_code = .MISUSE,
		)
	} else {
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
	if error.kind != .None do return error
	result := sqlite3_step(statement)
	if result == .ROW {
		return make_error(.Execution_Failed, "Insert must not return rows", sqlite_code = result)
	}
	if result != .DONE {
		return make_error(
			.Execution_Failed, cast(string)sqlite3_errmsg(database), sqlite_code = result,
		)
	}
	return {}
}
