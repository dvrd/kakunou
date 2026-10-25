package sqlite

import "core:fmt"

// Values are borrowed until the statement is finalized by its caller.
bind_parameters :: proc(
	database: ^SQLite_DB,
	statement: ^SQLite_Statement,
	parameters: []SQLite_Value,
) -> Database_Error {
	expected := int(sqlite3_bind_parameter_count(statement))
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
		case i64:
			result = sqlite3_bind_int64(statement, i32(index + 1), value)
		case cstring:
			result = sqlite3_bind_text(statement, i32(index + 1), value, -1, nil)
		case:
			return make_error(
				.Execution_Failed,
				"Unsupported SQL parameter",
				sqlite_code = .MISUSE,
			)
		}

		if result != .OK {
			return make_error(
				.Execution_Failed,
				string(sqlite3_errmsg(database)),
				sqlite_code = result,
			)
		}
	}

	return {}
}
