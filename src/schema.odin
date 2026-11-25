package sqlite

import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

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

// SQL identifiers use double quotes, with embedded quotes doubled.
// The caller owns the returned SQL and releases it with delete.
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
			subject = schema.name,
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
				subject = schema.name,
			)
		}

		if index > 0 {
			size += len(", ")
		}

		size += len(column.name) + strings.count(column.name, "\"") + 2 + 1 + len(data_type)
		if column.primary_key {
			size += len(" PRIMARY KEY")
		}

		if column.not_null {
			size += len(" NOT NULL")
		}

		if column.unique {
			size += len(" UNIQUE")
		}
	}

	buffer, err := make([]u8, size + 1, context.allocator)

	if err != nil {
		return nil, make_error(
			.Allocation_Failed,
			"Could not allocate table SQL",
			allocator_error = err,
			subject = schema.name,
		)
	}

	used := copy(buffer, prefix)
	used += write_schema_identifier(buffer[used:], schema.name)
	used += copy(buffer[used:], " (")

	for column, index in schema.columns {
		if index > 0 {
			used += copy(buffer[used:], ", ")
		}

		used += write_schema_identifier(buffer[used:], column.name)
		used += copy(buffer[used:], " ")
		used += copy(buffer[used:], column_type_sql(column.data_type))

		if column.primary_key {
			used += copy(buffer[used:], " PRIMARY KEY")
		}

		if column.not_null {
			used += copy(buffer[used:], " NOT NULL")
		}

		if column.unique {
			used += copy(buffer[used:], " UNIQUE")
		}
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
	if err.kind != .None {
		return
	}

	err = execute_sql(database, sql)
	if err.kind != .None {
		copy(err.subject[:len(err.subject) - 1], schema.name)
	}

	// Error metadata must be attached before returning; defer observes a copy.
	release_owned_cstring(sql, &err, "Could not free table SQL", schema.name)

	return
}

// Region allocators deliberately release storage through their owner, not per
// object. Real free failures are recorded on the caller's error, becoming the
// primary failure when none occurred; request-arena semantics are retained.
release_owned_cstring :: proc(
	value: cstring,
	err: ^Database_Error,
	message: string,
	subject := "",
) {
	free_error := delete(value)

	if free_error == .Mode_Not_Implemented && .Free_All in mem.query_features(context.allocator) {
		return
	}

	if free_error == nil {
		return
	}

	if err.kind == .None {
		err^ = make_error(.Allocation_Failed, message, subject = subject)
	}

	err.allocator_error = free_error
}

SQLite_Backup :: struct {}
BACKUP_TIMEOUT :: 10 * time.Second
BACKUP_PAGE_BATCH :: 256

// Uses SQLite's consistent online-backup API, including uncheckpointed WAL.
// Never replaces an existing file. Only a successful return denotes a finished
// backup; readers must not consume a destination while the call is running.
backup_file :: proc(source: ^SQLite_DB, path: string) -> Database_Error {
	if source == nil || path == "" || strings.contains_rune(path, 0) {
		return make_error(
			.Execution_Failed,
			"Invalid backup source or destination",
			sqlite_code = .MISUSE,
		)
	}

	if os.is_absolute_path(path) {
		return backup_to_path(source, path)
	}

	// Resolve the existing parent before creating the file. An absolute path
	// also makes SQLite treat names such as ":memory:" and "file:..." literally.
	parent, basename := os.split_path(path)
	directory, dir_error := os.get_absolute_path(parent, context.allocator)
	if dir_error != nil {
		if alloc_error, ok := dir_error.(mem.Allocator_Error); ok {
			return make_error(.Allocation_Failed, "Could not resolve backup directory", allocator_error = alloc_error)
		}
		return make_error(.Open_Failed, "Could not resolve backup directory", subject = path)
	}
	defer delete(directory)

	absolute, path_error := os.join_path({directory, basename}, context.allocator)
	if path_error != nil {
		return make_error(.Allocation_Failed, "Could not build backup path", allocator_error = path_error)
	}
	defer delete(absolute)
	return backup_to_path(source, absolute)
}

@(private)
backup_to_path :: proc(source: ^SQLite_DB, path: string) -> Database_Error {
	file, open_error := os.open(path, {.Write, .Create, .Excl}, os.perm_number(0o600))

	if open_error != nil {
		return make_error(
			.Open_Failed,
			"Backup destination must be a new writable file",
			subject = path,
		)
	}

	if close_error := os.close(file); close_error != nil {
		backup_remove_incomplete(path)
		return make_error(.Execution_Failed, "Could not close new backup file", subject = path)
	}

	name, allocation_error := strings.clone_to_cstring(path)

	if allocation_error != nil {
		backup_remove_incomplete(path)
		return make_error(
			.Allocation_Failed,
			"Could not copy backup path",
			allocator_error = allocation_error,
		)
	}

	destination: ^SQLite_DB
	error := open(&destination, name)

	release_owned_cstring(name, &error, "Could not free backup path")

	if error.kind == .None {
		error = backup_copy(source, destination)
	}

	if destination != nil {
		close_code := sqlite3_close(destination)

		if close_code != .OK {
			if error.kind == .None {
				error = make_error(
					.Execution_Failed,
					"Could not close backup",
					sqlite_code = close_code,
				)
			} else {
				error.cleanup_code = close_code
			}
		}
	}

	if error.kind != .None {
		backup_remove_incomplete(path)
	}

	return error
}

backup_copy :: proc(source, destination: ^SQLite_DB) -> Database_Error {
	backup := sqlite3_backup_init(destination, "main", source, "main")

	if backup == nil {
		return make_error(
			.Execution_Failed,
			"Could not initialize SQLite backup",
			sqlite_code = .ERROR,
		)
	}

	result := SQLite_Result.BUSY
	started := time.tick_now()

	for time.tick_since(started) <= BACKUP_TIMEOUT {
		result = sqlite3_backup_step(backup, BACKUP_PAGE_BATCH)
		if result == .DONE do break

		if result != .BUSY && result != .LOCKED && result != .OK do break

		if result != .OK do time.sleep(time.Millisecond)
	}

	if result == .OK do result = .BUSY // The last batch succeeded but the deadline expired.

	finish_code := sqlite3_backup_finish(backup)
	if result == .DONE && finish_code == .OK do return {}

	primary_code := finish_code if result == .DONE else result
	error := make_error(
		.Execution_Failed,
		"SQLite backup did not complete",
		sqlite_code = primary_code,
	)

	if finish_code != .OK && finish_code != primary_code {
		error.cleanup_code = finish_code
	}

	return error
}

// Cleanup has no return channel for an OS error alongside the primary database
// failure. Log a leftover partial file explicitly so it is not mistaken for a backup.
backup_remove_incomplete :: proc(path: string) {
	if error := os.remove(path); error != nil {
		log.error("Could not remove incomplete SQLite backup:", path, error)
	}
}
