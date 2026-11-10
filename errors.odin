package sqlite

import "core:log"
import "core:mem"
import "core:strings"

Database_Error_Kind :: enum {
	None,
	Open_Failed,
	Invalid_Schema,
	Allocation_Failed,
	Execution_Failed,
}

// Diagnostic text is owned by the error and survives SQLite cleanup and copying.
// Buffers include a trailing NUL; longer diagnostic text is truncated.
Database_Error :: struct {
	kind:            Database_Error_Kind,
	sqlite_code:     SQLite_Result,
	allocator_error: mem.Allocator_Error,
	cleanup_code:    SQLite_Result,
	message:         [512]u8,
	path:            [1024]u8,
	table:           [256]u8,
}

make_error :: proc(
	kind: Database_Error_Kind,
	message: string,
	sqlite_code: SQLite_Result = .OK,
	allocator_error: mem.Allocator_Error = nil,
	path: string = "",
	table: string = "",
) -> Database_Error {
	err := Database_Error {
		kind            = kind,
		sqlite_code     = sqlite_code,
		allocator_error = allocator_error,
	}
	copy(err.message[:len(err.message) - 1], message)
	copy(err.path[:len(err.path) - 1], path)
	copy(err.table[:len(err.table) - 1], table)

	return err
}

// The returned string borrows the supplied error's buffer.
error_text :: proc(buffer: []u8) -> string {
	text := cast(string)(buffer)
	if end := strings.index_byte(text, 0); end >= 0 do text = text[:end]

	return text
}

log_error :: proc(err: Database_Error, operation := "Database operation failed") {
	if err.kind == .None do return

	diagnostic := err

	log.errorf(
		"%s | kind=%v path=%s table=%s sqlite_code=%v " +
		"allocator_error=%v cleanup_code=%v message=%s",
		operation,
		err.kind,
		error_text(diagnostic.path[:]),
		error_text(diagnostic.table[:]),
		err.sqlite_code,
		err.allocator_error,
		err.cleanup_code,
		error_text(diagnostic.message[:]),
	)
}
