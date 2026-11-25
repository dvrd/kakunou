package integration_tests

import "base:runtime"
import "core:crypto"
import "core:encoding/uuid"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import db "shared:kakunou"

@(private)
make_backup_fixture :: proc(prefix: string, allocator: mem.Allocator) -> (path: string, err: os.Error) {
	root := os.temp_directory(allocator) or_return
	defer delete(root, allocator)
	context.random_generator = crypto.random_generator()
	buffer: [36]u8
	name := uuid.to_string(uuid.generate_v4(), buffer[:])
	path = strings.concatenate({root, "/", prefix, name}, allocator) or_return
	err = os.make_directory(path, os.perm_number(0o700))
	return path, err
}

@(test)
database_backup_copies_rows_and_preserves_existing_destination :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	directory, directory_error := make_backup_fixture("kakunou-backup-", context.allocator)

	if !testing.expect_value(t, directory_error, nil) {
		return
	}

	defer testing.expect_value(t, os.remove_all(directory), nil)
	path := fmt.aprintf("%s/copy.sqlite", directory)
	database, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	testing.expect_value(
		t,
		db.insert(database, "INSERT INTO items VALUES(1, 'saved')", nil).kind,
		.None,
	)
	if !testing.expect_value(t, os.chmod(directory, os.perm_number(0o770)), nil) {
		return
	}
	testing.expect_value(t, db.backup_file(database, path).kind, .Open_Failed)
	testing.expect(t, !os.exists(path))
	if !testing.expect_value(t, os.chmod(directory, os.perm_number(0o700)), nil) {
		return
	}
	testing.expect_value(t, db.backup_file(database, path).kind, .None)
	info, stat_err := os.stat(path, context.allocator)
	testing.expect_value(t, stat_err, nil)
	testing.expect_value(t, info.mode & os.Permissions_All, os.perm_number(0o600))
	copy_database: ^db.SQLite_DB

	if !testing.expect_value(
		t,
		db.open(&copy_database, strings.clone_to_cstring(path)).kind,
		.None,
	) {
		return
	}

	defer testing.expect_value(t, db.sqlite3_close(copy_database), .OK)
	test_database_count(t, copy_database, "SELECT COUNT(*) FROM items", 1)
	testing.expect_value(
		t,
		db.insert(database, "INSERT INTO items VALUES(2, 'new')", nil).kind,
		.None,
	)
	testing.expect_value(t, db.backup_file(database, path).kind, .Open_Failed)
	test_database_count(t, copy_database, "SELECT COUNT(*) FROM items", 1)
	testing.expect_value(t, db.backup_file(nil, path).sqlite_code, .MISUSE)
	testing.expect_value(t, db.backup_file(database, "bad\x00path").sqlite_code, .MISUSE)
}

@(test)
backup_includes_committed_uncheckpointed_wal_rows :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	directory, error := make_backup_fixture("kakunou-wal-", context.allocator)

	if !testing.expect_value(t, error, nil) {
		return
	}

	defer testing.expect_value(t, os.remove_all(directory), nil)
	source_path := fmt.aprintf("%s/source.sqlite", directory)
	backup_path := fmt.aprintf("%s/backup.sqlite", directory)
	database: ^db.SQLite_DB

	if !testing.expect_value(
		t,
		db.open(&database, strings.clone_to_cstring(source_path)).kind,
		.None,
	) {
		return
	}

	defer testing.expect_value(t, db.sqlite3_close(database), .OK)
	testing.expect_value(
		t,
		db.execute_sql(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; " + "CREATE TABLE saved(value INTEGER); INSERT INTO saved VALUES(42);").kind,
		.None,
	)
	testing.expect(
		t,
		os.exists(fmt.aprintf("%s-wal", source_path)),
		"source owns an uncheckpointed WAL",
	)
	testing.expect_value(t, db.backup_file(database, backup_path).kind, .None)
	backup: ^db.SQLite_DB

	if !testing.expect_value(
		t,
		db.open(&backup, strings.clone_to_cstring(backup_path)).kind,
		.None,
	) {
		return
	}

	defer testing.expect_value(t, db.sqlite3_close(backup), .OK)
	test_database_count(t, backup, "SELECT value FROM saved", 42)
}

@(test)
backup_timeout_removes_incomplete_destination_and_keeps_source_transaction :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	directory, error := make_backup_fixture("kakunou-backup-failure-", context.allocator)

	if !testing.expect_value(t, error, nil) {
		return
	}

	defer testing.expect_value(t, os.remove_all(directory), nil)
	path := fmt.aprintf("%s/incomplete.sqlite", directory)
	database, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer db.close(database)

	if !testing.expect_value(t, db.begin_immediate(database).kind, .None) {
		return
	}

	defer db.rollback_transaction(database)
	testing.expect_value(
		t,
		db.insert(database, "INSERT INTO items VALUES(1,'owned')", nil).kind,
		.None,
	)
	{
		storage: [1]u8
		limited: mem.Arena
		mem.arena_init(&limited, storage[:])
		context.allocator = mem.arena_allocator(&limited)
		failure := db.backup_file(database, path)
		testing.expect_value(t, failure.kind, .Allocation_Failed)
		testing.expect_value(t, failure.allocator_error, .Out_Of_Memory)
	}
	for invalid in ([]time.Duration{0, -time.Millisecond}) {
		testing.expect_value(t, db.backup_file_with_timeout(database, path, invalid).sqlite_code, .MISUSE)
		testing.expect(t, !os.exists(path))
	}
	retry_budget :: 50 * time.Millisecond
	started := time.tick_now()
	failure := db.backup_file_with_timeout(database, path, retry_budget)
	elapsed := time.tick_since(started)
	testing.expect_value(t, failure.kind, .Execution_Failed)
	testing.expect(t, failure.sqlite_code == .LOCKED || failure.sqlite_code == .BUSY)
	testing.expect(t, elapsed >= retry_budget, "retry while the source write transaction is held")
	testing.expect(t, elapsed < retry_budget + 2 * time.Second, "stop within the retry budget and scheduling tolerance")
	testing.expect(t, !os.exists(path), "failed backup never installs its destination")
	files, list_err := os.read_all_directory_by_path(directory, context.allocator)
	testing.expect_value(t, list_err, nil)
	testing.expect_value(t, len(files), 0)
	testing.expect_value(t, db.sqlite3_get_autocommit(database), 0)
	test_database_count(t, database, "SELECT COUNT(*) FROM items", 1)
}

@(test)
concurrent_backup_preserves_first_completed_destination :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory, dir_err := make_backup_fixture("kakunou-publish-", context.allocator)
	if !testing.expect_value(t, dir_err, nil) {
		return
	}
	defer testing.expect_value(t, os.remove_all(directory), nil)

	slow, ready := test_insert_database(t)
	if !ready {
		return
	}
	defer db.close(slow)
	fast, fast_ready := test_insert_database(t)
	if !fast_ready {
		return
	}
	defer db.close(fast)
	if !testing.expect_value(t, db.insert(fast, "INSERT INTO items VALUES(2,'first')", nil).kind, .None) ||
	   !testing.expect_value(t, db.begin_immediate(slow).kind, .None) {
		return
	}
	held := true
	defer if held {
		db.rollback_transaction(slow)
	}

	Publisher :: struct {
		source: ^db.SQLite_DB,
		path: string,
		err: db.Database_Error,
	}
	publish :: proc(data: rawptr) {
		job := cast(^Publisher)data
		job.err = db.backup_file(job.source, job.path)
	}
	job := Publisher{source = slow, path = fmt.aprintf("%s/latest.sqlite", directory)}
	worker := thread.create_and_start_with_data(&job, publish, runtime.default_context())
	if !testing.expect(t, worker != nil) {
		return
	}
	defer thread.destroy(worker)

	started := wait_for_private_backup(directory)
	winner := db.backup_file(fast, job.path)
	db.rollback_transaction(slow)
	held = false
	thread.join(worker)
	testing.expect(t, started, "the slow publisher staged before the fast publisher ran")
	testing.expect_value(t, winner.kind, .None)
	testing.expect_value(t, job.err.kind, .Open_Failed)
	snapshot: ^db.SQLite_DB
	if !testing.expect_value(t, db.open(&snapshot, strings.clone_to_cstring(job.path)).kind, .None) {
		return
	}
	defer db.close(snapshot)
	test_database_count(t, snapshot, "SELECT id FROM items", 2)
}
