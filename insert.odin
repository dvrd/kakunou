package sqlite


// Executes one statement without RETURNING rows. Parameters are bound as data.
insert :: proc(
	database: ^SQLite_DB,
	sql: cstring,
	parameters: []SQLite_Value,
) -> (
	err: Database_Error,
) {
	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)

	if database == nil || sql == nil {
		return make_error(
			.Execution_Failed,
			"Database and insert SQL are required",
			sqlite_code = .MISUSE,
		)
	}

	statement: ^SQLite_Statement
	result := sqlite3_prepare_v2(database, sql, -1, &statement, nil)

	defer {
		if statement != nil {
			finalize_result := sqlite3_finalize(statement)

			if finalize_result != .OK {
				if err.kind == .None {
					err = make_error(
						.Execution_Failed,
						"Could not finalize insert",
						sqlite_code = finalize_result,
					)
				} else if finalize_result != err.sqlite_code {
					err.cleanup_code = finalize_result
				}
			}
		}
	}

	if result != .OK {
		return make_error(
			.Execution_Failed,
			string(sqlite3_errmsg(database)),
			sqlite_code = result,
		)
	}

	if statement == nil {
		return make_error(
			.Execution_Failed,
			"Insert did not contain an SQL statement",
			sqlite_code = .MISUSE,
		)
	}

	err = bind_parameters(database, statement, parameters)
	if err.kind != .None do return

	result = sqlite3_step(statement)
	if result == .ROW {
		return make_error(.Execution_Failed, "Insert must not return rows", sqlite_code = result)
	}

	if result != .DONE {
		return make_error(
			.Execution_Failed,
			string(sqlite3_errmsg(database)),
			sqlite_code = result,
		)
	}

	return
}
