package integration_tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import db "shared:kakunou"

@(test)
database_backup_copies_rows_and_preserves_existing_destination :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	directory, directory_error := os.make_directory_temp("", "kakunou-backup-*", context.allocator)

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
	testing.expect_value(t, db.backup_file(database, path).kind, .None)
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
	directory, error := os.make_directory_temp("", "kakunou-wal-*", context.allocator)

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
	directory, error := os.make_directory_temp("", "kakunou-backup-failure-*", context.allocator)

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
	started := time.tick_now()
	failure := db.backup_file(database, path)
	testing.expect_value(t, failure.kind, .Execution_Failed)
	testing.expect(t, failure.sqlite_code == .LOCKED || failure.sqlite_code == .BUSY)
	testing.expect(t, time.tick_since(started) < db.BACKUP_TIMEOUT + 2 * time.Second)
	testing.expect(t, !os.exists(path), "failed backup removes its incomplete destination")
	testing.expect_value(t, db.sqlite3_get_autocommit(database), 0)
	test_database_count(t, database, "SELECT COUNT(*) FROM items", 1)
}
