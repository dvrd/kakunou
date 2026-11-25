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
	// The parent supplies a fresh working directory and a one-use marker. An
	// inherited setting alone cannot select a worker or supply its file paths.
	cwd, cwd_err := os.get_working_directory(context.allocator)
	if !testing.expect_value(t, cwd_err, nil) {
		return
	}
	worker_id := os.get_env("KAKUNOU_RECOVERY_WORKER", context.allocator)
	if worker_id == os.base(cwd) && strings.has_prefix(worker_id, "kakunou-recovery-") {
		if !testing.expect_value(t, os.remove(".worker-ticket"), nil) {
			return
		}
		run_recovery_worker(t)
		return
	}
	directory, dir_err := make_backup_fixture("kakunou-recovery-", context.allocator)
	if !testing.expect_value(t, dir_err, nil) {
		return
	}
	defer testing.expect_value(t, os.remove_all(directory), nil)

	source_path := fmt.tprintf("%s/source.sqlite", directory)
	published := fmt.tprintf("%s/latest.sqlite", directory)
	staging := fmt.tprintf("%s/next.partial", directory)
	source: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&source, strings.clone_to_cstring(source_path)).kind, .None) {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(source), .OK)

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
	ticket := fmt.tprintf("%s/.worker-ticket", directory)
	if !testing.expect_value(t, os.write_entire_file(ticket, "ready"), nil) {
		return
	}
	child, start_err := os.process_start({
		command = {self, "-tests:integration_tests.restore_uses_last_completed_backup_after_worker_is_killed"},
		working_dir = directory,
		env = {fmt.tprintf("KAKUNOU_RECOVERY_WORKER=%s", os.base(directory))},
	})
	if !testing.expect_value(t, start_err, nil) {
		return
	}
	started := wait_for_private_backup(directory)
	write_err := db.execute_sql(source, "INSERT INTO events VALUES (4097, zeroblob(512))")
	kill_err := os.process_kill(child)
	state, wait_err := os.process_wait(child)
	if !testing.expect(t, started, "worker started a private backup") ||
	   !testing.expect_value(t, write_err.kind, .None) ||
	   !testing.expect_value(t, kill_err, nil) || !testing.expect_value(t, wait_err, nil) ||
	   !testing.expect(t, !state.success) {
		return
	}
	if !testing.expect_value(t, db.execute_sql(source, "COMMIT").kind, .None) {
		return
	}
	test_database_count(t, source, "SELECT COUNT(*) FROM events", 4097)
	testing.expect(t, !os.exists(staging), "an interrupted backup never installs its candidate")

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

@(private)
wait_for_private_backup :: proc(directory: string) -> bool {
	start := time.tick_now()
	started := false
	for !started && time.tick_since(start) < 5*time.Second {
		files, list_err := os.read_all_directory_by_path(directory, context.allocator)
		if list_err != nil {
			return false
		}
		for file in files {
			if strings.has_prefix(file.name, ".kakunou-backup-") {
				started = os.exists(fmt.tprintf("%s/%s/snapshot.sqlite", directory, file.name))
			}
		}
		os.file_info_slice_delete(files, context.allocator)
		time.sleep(5*time.Millisecond)
	}
	return started
}

@(private)
run_recovery_worker :: proc(t: ^testing.T) {
	source: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&source, "source.sqlite").kind, .None) {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(source), .OK)
	if !testing.expect_value(t, db.backup_file(source, "next.partial").kind, .None) {
		return
	}
	testing.expect_value(t, os.rename("next.partial", "latest.sqlite"), nil)
}

@(test)
recovery_test_ignores_inherited_directory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	unrelated, dir_err := make_backup_fixture("kakunou-unrelated-", context.allocator)
	if !testing.expect_value(t, dir_err, nil) {
		return
	}
	defer testing.expect_value(t, os.remove_all(unrelated), nil)
	self, exe_err := os.get_executable_path(context.allocator)
	if !testing.expect_value(t, exe_err, nil) {
		return
	}
	state, _, diagnostic, child_err := os.process_exec({
		command = {self, "-tests:integration_tests.restore_uses_last_completed_backup_after_worker_is_killed"},
		env = {fmt.tprintf("KAKUNOU_BACKUP_RECOVERY_DIR=%s", unrelated)},
	}, context.allocator)
	testing.expect_value(t, child_err, nil)
	testing.expectf(t, state.success, "%s", string(diagnostic))
	files, list_err := os.read_all_directory_by_path(unrelated, context.allocator)
	testing.expect_value(t, list_err, nil)
	testing.expect_value(t, len(files), 0)
}
