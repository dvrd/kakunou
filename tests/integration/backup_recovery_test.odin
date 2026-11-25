package integration_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import db "shared:kakunou"

@(test)
restore_uses_last_completed_backup_after_worker_is_killed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := os.get_env("KAKUNOU_BACKUP_RECOVERY_DIR", context.allocator)
	worker := directory != ""
	if !worker {
		dir, err := os.make_directory_temp("", "kakunou-recovery-*", context.allocator)
		if !testing.expect_value(t, err, nil) {
			return
		}
		directory = dir
	}
	defer if !worker {
		testing.expect_value(t, os.remove_all(directory), nil)
	}

	source_path := fmt.tprintf("%s/source.sqlite", directory)
	published := fmt.tprintf("%s/latest.sqlite", directory)
	staging := fmt.tprintf("%s/next.partial", directory)
	source: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&source, strings.clone_to_cstring(source_path)).kind, .None) {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(source), .OK)

	if worker {
		if !testing.expect_value(t, db.backup_file(source, staging).kind, .None) {
			return
		}
		testing.expect_value(t, os.rename(staging, published), nil)
		return
	}

	seed :: "CREATE TABLE events(id INTEGER PRIMARY KEY, payload BLOB);" +
	        "WITH RECURSIVE ids(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM ids WHERE i<4096)" +
	        " INSERT INTO events SELECT i, zeroblob(512) FROM ids;"
	if !testing.expect_value(t, db.execute_sql(source, seed).kind, .None) ||
	   !testing.expect_value(t, db.backup_file(source, staging).kind, .None) ||
	   !testing.expect_value(t, os.rename(staging, published), nil) {
		return
	}

	// The exclusive writer keeps the separate backup worker inside the copy
	// until we kill it, independently of disk speed and scheduler timing.
	if !testing.expect_value(t, db.execute_sql(source, "BEGIN EXCLUSIVE").kind, .None) {
		return
	}
	self, exe_err := os.get_executable_path(context.allocator)
	if !testing.expect_value(t, exe_err, nil) {
		return
	}
	child, start_err := os.process_start({
		command = {self, "-tests:integration_tests.restore_uses_last_completed_backup_after_worker_is_killed"},
		env = {fmt.tprintf("KAKUNOU_BACKUP_RECOVERY_DIR=%s", directory)},
	})
	if !testing.expect_value(t, start_err, nil) {
		return
	}
	start := time.tick_now()
	for !os.exists(staging) && time.tick_since(start) < 5*time.Second {
		time.sleep(5*time.Millisecond)
	}
	reserved := os.exists(staging)
	write_err := db.execute_sql(source, "INSERT INTO events VALUES (4097, zeroblob(512))")
	kill_err := os.process_kill(child)
	state, wait_err := os.process_wait(child)
	if !testing.expect(t, reserved, "worker reserved the staging file") ||
	   !testing.expect_value(t, write_err.kind, .None) ||
	   !testing.expect_value(t, kill_err, nil) || !testing.expect_value(t, wait_err, nil) ||
	   !testing.expect(t, !state.success) {
		return
	}
	if !testing.expect_value(t, db.execute_sql(source, "COMMIT").kind, .None) {
		return
	}
	test_database_count(t, source, "SELECT COUNT(*) FROM events", 4097)
	testing.expect(t, os.exists(staging), "interrupted candidate remains unpublished")

	restored := fmt.tprintf("%s/restored.sqlite", directory)
	if !testing.expect_value(t, os.copy_file(restored, published), nil) {
		return
	}
	recovered: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&recovered, strings.clone_to_cstring(restored)).kind, .None) {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(recovered), .OK)
	test_database_count(t, recovered, "SELECT COUNT(*) FROM pragma_integrity_check WHERE integrity_check <> 'ok'", 0)
	test_database_count(t, recovered, "SELECT COUNT(*) FROM events", 4096)
	test_database_count(t, recovered, "SELECT SUM(id) FROM events", 4096*4097/2)
}
