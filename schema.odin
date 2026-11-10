package sqlite

import "core:strings"
import "core:mem"

Column_Type :: enum {
	Integer,
	Real,
	Text,
	Blob,
	Numeric,
}

Column :: struct {
	name:        string,
	data_type:   Column_Type,
	primary_key: bool,
	not_null:    bool,
	unique:      bool,
}

Table_Schema :: struct {
	name:    string,
	columns: []Column,
}

column_type_sql :: proc(data_type: Column_Type) -> string {
	switch data_type {
	case .Integer:
		return "INTEGER"
	case .Real:
		return "REAL"
	case .Text:
		return "TEXT"
	case .Blob:
		return "BLOB"
	case .Numeric:
		return "NUMERIC"
	}

	return ""
}


// SQL identifiers use double quotes, with embedded quotes doubled.
write_schema_identifier :: proc(buffer: []u8, name: string) -> int {
	used := copy(buffer, "\"")

	for value in transmute([]u8)name {
		buffer[used] = value
		used += 1

		if value == '"' {
			buffer[used] = '"'
			used += 1
		}
	}

	used += copy(buffer[used:], "\"")

	return used
}


// The caller owns the returned SQL and releases it with delete.
build_new_table_sql :: proc(
	schema: Table_Schema,
	if_not_exists := true,
) -> (
	cstring,
	Database_Error,
) {
	if schema.name == "" ||
	   strings.contains_rune(schema.name, '\x00') ||
	   len(schema.columns) == 0 {
		return nil, make_error(
			.Invalid_Schema,
			"Schema needs a valid name and at least one column",
			table = schema.name,
		)
	}

	prefix := "CREATE TABLE IF NOT EXISTS " if if_not_exists else "CREATE TABLE "
	size := len(prefix) + len(schema.name) + strings.count(schema.name, "\"") + 2 + len(" ();")

	for column, index in schema.columns {
		data_type := column_type_sql(column.data_type)

		if column.name == "" || strings.contains_rune(column.name, '\x00') || data_type == "" {
			return nil, make_error(
				.Invalid_Schema,
				"Column needs a valid name and data type",
				table = schema.name,
			)
		}

		if index > 0 do size += len(", ")
		size += len(column.name) + strings.count(column.name, "\"") + 2 + 1 + len(data_type)
		if column.primary_key do size += len(" PRIMARY KEY")
		if column.not_null do size += len(" NOT NULL")
		if column.unique do size += len(" UNIQUE")
	}

	buffer, err := make([]u8, size + 1, context.allocator)
	if err != nil {
		return nil, make_error(
			.Allocation_Failed,
			"Could not allocate table SQL",
			allocator_error = err,
			table = schema.name,
		)
	}

	used := copy(buffer, prefix)
	used += write_schema_identifier(buffer[used:], schema.name)
	used += copy(buffer[used:], " (")

	for column, index in schema.columns {
		if index > 0 do used += copy(buffer[used:], ", ")
		used += write_schema_identifier(buffer[used:], column.name)
		used += copy(buffer[used:], " ")
		used += copy(buffer[used:], column_type_sql(column.data_type))

		if column.primary_key do used += copy(buffer[used:], " PRIMARY KEY")
		if column.not_null do used += copy(buffer[used:], " NOT NULL")
		if column.unique do used += copy(buffer[used:], " UNIQUE")
	}

	copy(buffer[used:], ");")

	return cstring(raw_data(buffer)), {}
}

create_table :: proc(
	database: ^SQLite_DB,
	schema: Table_Schema,
	if_not_exists := true,
) -> (
	err: Database_Error,
) {
	mutex := connection_mutex(database)
	sqlite3_mutex_enter(mutex)
	defer sqlite3_mutex_leave(mutex)

	sql: cstring
	sql, err = build_new_table_sql(schema, if_not_exists)
	if err.kind != .None do return


	err = execute_sql(database, sql)
	if err.kind != .None do copy(err.table[:len(err.table) - 1], schema.name)
	// Error metadata must be attached before returning; defer observes a copy.
	if free_error := release_owned_cstring(sql); free_error != nil {
		if err.kind == .None {
			err = make_error(.Allocation_Failed, "Could not free table SQL", table = schema.name)
		}
		err.allocator_error = free_error
	}

	return
}

// Region allocators deliberately release storage through their owner, not per
// object. Propagate real free failures while retaining request-arena semantics.
release_owned_cstring :: proc(value: cstring) -> mem.Allocator_Error {
	error := delete(value)
	if error == .Mode_Not_Implemented && .Free_All in mem.query_features(context.allocator) {
		return nil
	}
	return error
}
