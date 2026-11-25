#+build linux, darwin, freebsd, openbsd, netbsd
package sqlite

import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

@(private)
backup_posix_file :: proc(source: ^SQLite_DB, path: string, timeout: time.Duration) -> Database_Error {
	// Resolve the existing parent before creating the file. An absolute path
	// also makes SQLite treat names such as ":memory:" and "file:..." literally.
	parent, basename := os.split_path(path)
	if parent == "" {
		parent = "."
	}
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
	if os.exists(absolute) || basename == "" || basename == "." || basename == ".." {
		return make_error(.Open_Failed, "Backup destination must be a new file", subject = path)
	}

	parent_name, parent_alloc := strings.clone_to_cstring(directory)
	if parent_alloc != nil {
		return make_error(.Allocation_Failed, "Could not copy backup directory", allocator_error = parent_alloc)
	}
	defer delete(parent_name)
	info: posix.stat_t
	if posix.stat(parent_name, &info) != .OK || !posix.S_ISDIR(info.st_mode) ||
	   info.st_uid != posix.geteuid() || .IWGRP in info.st_mode || .IWOTH in info.st_mode {
		return make_error(.Open_Failed, "Backup requires an owner-controlled directory", subject = directory)
	}

	// mkdtemp creates the private directory with mode 0700 in one operation.
	template, template_err := strings.concatenate({directory, "/.kakunou-backup-XXXXXX\x00"})
	if template_err != nil {
		return make_error(.Allocation_Failed, "Could not build staging directory name", allocator_error = template_err)
	}
	defer delete(template)
	if posix.mkdtemp(raw_data(template)) == nil {
		return make_error(.Open_Failed, "Could not create private backup directory", subject = directory)
	}
	stage := template[:len(template)-1]
	defer if cleanup := os.remove_all(stage); cleanup != nil {
		log.error("Could not remove private SQLite backup directory:", stage, cleanup)
	}
	candidate, candidate_err := os.join_path({stage, "snapshot.sqlite"}, context.allocator)
	if candidate_err != nil {
		return make_error(.Allocation_Failed, "Could not build backup filename", allocator_error = candidate_err)
	}
	defer delete(candidate)

	if err := backup_to_path(source, candidate, timeout); err.kind != .None {
		return err
	}
	if os.link(candidate, absolute) != nil {
		return make_error(.Open_Failed, "Could not install backup at a new destination", subject = path)
	}
	return {}
}
