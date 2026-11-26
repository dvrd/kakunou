package unit_tests

import "core:mem"
import "core:strings"
import "core:testing"
import support "../support"
import db "shared:kakunou"

@(test)
table_schema_rejects_invalid_definitions_and_allocation_failure :: proc(t: ^testing.T) {
	capture := support.Test_Log{}
	previous_logger := context.logger
	context.logger = {
		procedure = support.test_capture_log,
		data      = &capture,
	}

	defer context.logger = previous_logger

	for schema in ([]db.Table_Schema {
			{},
			{name = "empty"},
			{name = "bad\x00name", columns = {{name = "id"}}},
			{name = "items", columns = {{name = ""}}},
			{name = "items", columns = {{name = "bad\x00name"}}},
			{name = "items", columns = {{name = "id", data_type = db.Column_Type(999)}}},
		}) {
		sql, err := db.build_new_table_sql(schema)
		testing.expect(
			t,
			err.kind == .Invalid_Schema && sql == nil,
			"invalid schema produces no SQL",
		)
	}

	testing.expect(t, capture.error_count == 0, "invalid schemas are returned without logging")

	storage: [1]u8
	arena: mem.Arena
	mem.arena_init(&arena, storage[:])
	previous_allocator := context.allocator
	context.allocator = mem.arena_allocator(&arena)
	defer context.allocator = previous_allocator

	sql, err := db.build_new_table_sql(db.Table_Schema{name = "items", columns = {{name = "id"}}})
	context.allocator = previous_allocator

	testing.expect(
		t,
		err.kind == .Allocation_Failed && sql == nil,
		"allocation failure produces no SQL",
	)
	testing.expect(
		t,
		err.allocator_error == .Out_Of_Memory,
		"underlying allocation error is preserved",
	)
	testing.expect(t, capture.error_count == 0, "allocation failure is returned without logging")
}

@(test)
database_error_is_small_and_truncates_text :: proc(t: ^testing.T) {
	testing.expect(
		t,
		size_of(db.Database_Error) <= 320,
		"error stays small enough to return by value",
	)

	long_text := make([]u8, 2048)
	defer delete(long_text)

	for &value in long_text {
		value = 'x'
	}

	err := db.make_error(
		.Execution_Failed,
		string(long_text),
		sqlite_code = .ERROR,
		subject = string(long_text),
	)
	testing.expect_value(t, len(db.error_message(&err)), db.ERROR_MESSAGE_CAPACITY - 1)
	testing.expect_value(t, len(db.error_subject(&err)), db.ERROR_SUBJECT_CAPACITY - 1)

	copied := err
	testing.expect_value(t, db.error_message(&copied), db.error_message(&err))

	short := db.make_error(.Open_Failed, "short", subject = "path/to/file")
	testing.expect_value(t, db.error_message(&short), "short")
	testing.expect_value(t, db.error_subject(&short), "path/to/file")
}

@(test)
database_error_truncates_utf8_at_character_boundaries :: proc(t: ^testing.T) {
	for capacity in ([2]int{db.ERROR_MESSAGE_CAPACITY, db.ERROR_SUBJECT_CAPACITY}) {
		for character in ([]string{"é", "計", "😀"}) {
			for overflow in 0..<len(character) {
				length := capacity - 1 - len(character) + overflow
				prefix := strings.repeat("a", length, context.temp_allocator)
				text := strings.concatenate({prefix, character}, context.temp_allocator)
				err := db.make_error(.Execution_Failed, text, subject = text)
				actual := db.error_message(&err) if capacity == db.ERROR_MESSAGE_CAPACITY else db.error_subject(&err)
				testing.expect_value(t, actual, text if overflow == 0 else prefix)
			}
		}
	}
}
