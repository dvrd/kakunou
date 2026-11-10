package sqlite

import "core:fmt"

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
				return make_error(
					.Execution_Failed, "Blob exceeds SQLite limit", sqlite_code = .TOOBIG,
				)
			}
			data := raw_data(value)
			if len(value) == 0 {
				data = raw_data(cast(string)"\x00")
			}
			result = sqlite3_bind_blob(
				statement, cast(i32)(index + 1), data, cast(i32)len(value), nil,
			)
		case i64:
			result = sqlite3_bind_int64(statement, cast(i32)(index + 1), value)
		case cstring:
			result = sqlite3_bind_text(statement, cast(i32)(index + 1), value, -1, nil)
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
				cast(string)(sqlite3_errmsg(database)),
				sqlite_code = result,
			)
		}
	}

	return {}
}
