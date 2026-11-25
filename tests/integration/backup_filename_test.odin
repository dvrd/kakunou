package integration_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import db "shared:kakunou"

@(test)
backup_uses_literal_relative_filenames :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// Windows filenames cannot contain the colon in these SQLite names.
		return
	}

	// The parallel test runner shares one working directory. Run the relative
	// pathname check in a child whose working directory belongs to this test.
	if os.get_env("KAKUNOU_LITERAL_BACKUP_CHILD", context.temp_allocator) != "1" {
		directory, err := os.make_directory_temp("", "kakunou-literal-backup-*", context.temp_allocator)
		if !testing.expect_value(t, err, nil) {
			return
		}
		defer testing.expect_value(t, os.remove_all(directory), nil)
		self, exe_err := os.get_executable_path(context.temp_allocator)
		if !testing.expect_value(t, exe_err, nil) {
			return
		}
		state, _, stderr, child_err := os.process_exec(
			{
				command = {self, "-tests:integration_tests.backup_uses_literal_relative_filenames"},
				working_dir = directory,
				env = {"KAKUNOU_LITERAL_BACKUP_CHILD=1"},
			},
			context.temp_allocator,
		)
		testing.expect_value(t, child_err, nil)
		testing.expectf(t, state.exit_code == 0, "%s", string(stderr))
		return
	}

	database, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	if !testing.expect_value(t, db.insert(database, "INSERT INTO items VALUES(42, 'saved')", nil).kind, .None) {
		return
	}

	for name in ([]string{":memory:", "file:snapshot.sqlite?mode=memory"}) {
		if !testing.expect_value(t, db.backup_file(database, name).kind, .None) {
			return
		}
		backup: ^db.SQLite_DB
		literal := strings.clone_to_cstring(fmt.tprintf("./%s", name), context.temp_allocator)
		if !testing.expect_value(t, db.open(&backup, literal).kind, .None) {
			return
		}
		test_database_count(t, backup, "SELECT id FROM items", 42)
		testing.expect_value(t, db.sqlite3_close(backup), .OK)
	}
}
