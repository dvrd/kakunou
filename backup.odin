package sqlite

import "core:log"
import "core:os"
import "core:strings"
import "core:time"

foreign import backup_library "system:sqlite3"

SQLite_Backup :: struct {}
BACKUP_TIMEOUT :: 10 * time.Second
BACKUP_PAGE_BATCH :: 256

foreign backup_library {
	sqlite3_backup_init :: proc "c" (
		destination: ^SQLite_DB, destination_name: cstring,
		source: ^SQLite_DB, source_name: cstring,
	) -> ^SQLite_Backup ---
	sqlite3_backup_step :: proc "c" (backup: ^SQLite_Backup, pages: i32) -> SQLite_Result ---
	sqlite3_backup_finish :: proc "c" (backup: ^SQLite_Backup) -> SQLite_Result ---
}

// Uses SQLite's consistent online-backup API, including uncheckpointed WAL.
// Never replaces an existing file. Only a successful return denotes a finished
// backup; readers must not consume a destination while the call is running.
backup_file :: proc(source: ^SQLite_DB, path: string) -> Database_Error {
	if source == nil || path == "" || strings.contains_rune(path, 0) {
		return make_error(
			.Execution_Failed, "Invalid backup source or destination", sqlite_code = .MISUSE,
		)
	}
	file, open_error := os.open(path, {.Write, .Create, .Excl}, os.perm_number(0o600))
	if open_error != nil {
		return make_error(
			.Open_Failed, "Backup destination must be a new writable file", path = path,
		)
	}
	if close_error := os.close(file); close_error != nil {
		backup_remove_incomplete(path)
		return make_error(.Execution_Failed, "Could not close new backup file", path = path)
	}
	name, allocation_error := strings.clone_to_cstring(path)
	if allocation_error != nil {
		backup_remove_incomplete(path)
		return make_error(
			.Allocation_Failed, "Could not copy backup path", allocator_error = allocation_error,
		)
	}
	destination: ^SQLite_DB
	error := open(&destination, name)
	if free_error := release_owned_cstring(name); free_error != nil {
		if error.kind == .None {
			error = make_error(.Allocation_Failed, "Could not free backup path")
		}
		error.allocator_error = free_error
	}
	if error.kind == .None do error = backup_copy(source, destination)
	if destination != nil {
		close_code := sqlite3_close(destination)
		if close_code != .OK {
			if error.kind == .None {
				error = make_error(
					.Execution_Failed, "Could not close backup", sqlite_code = close_code,
				)
			} else {
				error.cleanup_code = close_code
			}
		}
	}
	if error.kind != .None do backup_remove_incomplete(path)
	return error
}

backup_copy :: proc(source, destination: ^SQLite_DB) -> Database_Error {
	backup := sqlite3_backup_init(destination, "main", source, "main")
	if backup == nil {
		return make_error(
			.Execution_Failed, "Could not initialize SQLite backup", sqlite_code = .ERROR,
		)
	}
	result := SQLite_Result.BUSY
	started := time.tick_now()
	for time.tick_since(started) <= BACKUP_TIMEOUT {
		result = sqlite3_backup_step(backup, BACKUP_PAGE_BATCH)
		if result == .DONE do break
		if result != .OK && result != .BUSY && result != .LOCKED do break
		if result != .OK do time.sleep(time.Millisecond)
	}
	if result == .OK do result = .BUSY // The last batch succeeded but the deadline expired.
	finish_code := sqlite3_backup_finish(backup)
	if result == .DONE && finish_code == .OK do return {}
	primary_code := finish_code if result == .DONE else result
	error := make_error(
		.Execution_Failed, "SQLite backup did not complete", sqlite_code = primary_code,
	)
	if finish_code != .OK && finish_code != primary_code do error.cleanup_code = finish_code
	return error
}

// Cleanup has no return channel for an OS error alongside the primary database
// failure. Log a leftover partial file explicitly so it is not mistaken for a backup.
backup_remove_incomplete :: proc(path: string) {
	if error := os.remove(path); error != nil {
		log.error("Could not remove incomplete SQLite backup:", path, error)
	}
}
