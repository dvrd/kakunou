#+build linux, darwin, freebsd, openbsd, netbsd
package sqlite

import "core:sys/posix"

@(private)
client_mutex_key :: "kakunou.operation-mutex.v1"

@(private)
client_data: struct {
	get: proc "c" (database: ^SQLite_DB, key: cstring) -> rawptr,
	set: proc "c" (database: ^SQLite_DB, key: cstring, data: rawptr, destroy: proc "c" (rawptr)) -> SQLite_Result,
}

// SQLite 3.44 added client data. Resolve it against the linked SQLite so
// existing applications can still load on systems with an older SQLite.
@(private, init)
resolve_client_data :: proc "contextless" () {
	process := posix.dlopen(nil, {.LAZY})
	if process == nil do return
	defer posix.dlclose(process)
	if posix.dlsym(process, "sqlite3_db_mutex") != rawptr(sqlite3_db_mutex) do return
	get := posix.dlsym(process, "sqlite3_get_clientdata")
	set := posix.dlsym(process, "sqlite3_set_clientdata")
	if get != nil && set != nil {
		client_data.get = auto_cast get
		client_data.set = auto_cast set
	}
}

@(private)
destroy_operation_mutex :: proc "c" (mutex: rawptr) {
	sqlite3_mutex_free(cast(^SQLite_Mutex)mutex)
}

@(private)
install_operation_mutex :: proc(database: ^SQLite_DB) -> SQLite_Result {
	if client_data.set == nil do return .OK
	SQLITE_MUTEX_RECURSIVE :: 1
	mutex := sqlite3_mutex_alloc(SQLITE_MUTEX_RECURSIVE)
	if mutex == nil do return .NOMEM
	// SQLite calls the destructor even if registration fails.
	return client_data.set(database, client_mutex_key, mutex, destroy_operation_mutex)
}
