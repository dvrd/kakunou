package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"
import db "../../src"
import private_temp "../private_temp"

SECONDS :: #config(SOAK_SECONDS, 60)
WRITERS :: #config(SOAK_WRITERS, 4)
SEED_MIB :: #config(SOAK_SEED_MIB, 16)
PACE_MS :: #config(SOAK_PACE_MS, 10)
#assert(SECONDS > 0 && WRITERS > 0 && SEED_MIB > 0 && PACE_MS >= 0)

check :: proc(err: db.Database_Error) {
	if err.kind != .None {
		detail := err
		fmt.eprintln("SQLite error", err.sqlite_code, db.error_message(&detail), "cleanup", err.cleanup_code)
		panic("database operation failed")
	}
}

open_db :: proc(path: cstring) -> ^db.SQLite_DB {
	c: ^db.SQLite_DB
	check(db.open(&c, path))
	return c
}

scalar :: proc(c: ^db.SQLite_DB, sql: cstring, parameters: []db.SQLite_Value = nil) -> i64 {
	read :: proc(stmt: ^db.SQLite_Statement, out: ^i64) -> db.Database_Error {
		value, err := db.column_int(stmt, 0)
		out^ = value
		return err
	}
	value: i64
	found, err := db.query_one(c, sql, parameters, &value, read)
	check(err)
	if !found do panic("expected scalar result")
	return value
}

Writer :: struct {
	connection: ^db.SQLite_DB,
	id: i64,
	stop: ^bool,
	committed, busy: int,
	latencies: [dynamic]time.Duration,
}

append_event :: proc(c: ^db.SQLite_DB, w: ^Writer) -> db.Database_Error {
	if err := db.insert(c, "INSERT INTO events VALUES(?,?)", {w.id, i64(w.committed+1)}); err.kind != .None {
		return err
	}
	return db.insert(c, "UPDATE writers SET total=total+1 WHERE id=?", {w.id})
}

write_loop :: proc(data: rawptr) {
	w := cast(^Writer)data
	for !sync.atomic_load(w.stop) {
		start := time.tick_now()
		err := db.with_transaction(w.connection, w, append_event)
		append(&w.latencies, time.tick_since(start))
		if err.kind == .None {
			w.committed += 1
		} else if err.sqlite_code == .BUSY && err.cleanup_code == .OK {
			w.busy += 1
		} else {
			check(err)
		}
		if PACE_MS > 0 do time.sleep(PACE_MS * time.Millisecond)
	}
}

verify :: proc(c: ^db.SQLite_DB, expected: i64) {
	if scalar(c, "SELECT count(*) FROM pragma_integrity_check WHERE integrity_check <> 'ok'") != 0 {
		panic("integrity_check failed")
	}
	// Unique positive sequence numbers, count and maximum together prove each writer's prefix is complete.
	bad :: "WITH actual AS (SELECT writer, count(*) AS n, max(seq) AS last FROM events GROUP BY writer) " +
	       "SELECT count(*) FROM writers w LEFT JOIN actual a ON a.writer=w.id " +
	       "WHERE w.total<>coalesce(a.n,0) OR w.total<>coalesce(a.last,0)"
	if scalar(c, "SELECT count(*) FROM pragma_foreign_key_check") != 0 || scalar(c, bad) != 0 || scalar(c, "SELECT count(*) FROM events") != expected ||
	   scalar(c, "SELECT count(*) FROM writers") != WRITERS ||
	   scalar(c, "SELECT count(*) FROM seed WHERE length(payload)=1024") != SEED_MIB*1024 {
		panic("restored data disagrees with the ledger or seed")
	}
}

snapshot :: proc(source: ^db.SQLite_DB, path: string, restored: cstring) -> (rows: i64, restore_time: time.Duration) {
	// Pin one committed WAL snapshot so writers can continue during the copy.
	check(db.begin_read(source))
	rows = scalar(source, "SELECT count(*) FROM events")
	err := db.backup_file(source, path)
	db.rollback_transaction(source)
	check(err)
	start := time.tick_now()
	if os.copy_file(string(restored), path) != nil do panic("restore copy failed")
	copy_db := open_db(restored)
	verify(copy_db, rows)
	if db.sqlite3_close(copy_db) != .OK do panic("restored connection still in use")
	restore_time = time.tick_since(start)
	if os.remove(string(restored)) != nil || os.remove(path) != nil do panic("snapshot cleanup failed")
	return
}

main :: proc() {
	directory, err := private_temp.create("kakunou-reliability")
	if err != nil do panic("could not create private work directory")
	fmt.println("Work directory", directory)
	path := fmt.ctprintf("%s/live.sqlite", directory)
	backup_path := fmt.tprintf("%s/snapshot.sqlite", directory)
	restore_path := fmt.ctprintf("%s/restored.sqlite", directory)
	source := open_db(path)
	check(db.execute_sql(source, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=0"))
	if scalar(source, "SELECT journal_mode='wal' FROM pragma_journal_mode") != 1 do panic("WAL unavailable")
	check(db.execute_sql(source, "CREATE TABLE writers(id INTEGER PRIMARY KEY,total INTEGER NOT NULL);" +
	                          "CREATE TABLE events(writer INTEGER NOT NULL REFERENCES writers(id), seq INTEGER CHECK(seq>0) NOT NULL, PRIMARY KEY(writer,seq));" +
	                          "CREATE TABLE seed(payload BLOB NOT NULL)"))
	check(db.execute_sql(source, fmt.ctprintf("WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<%d) INSERT INTO seed SELECT zeroblob(1024) FROM n", SEED_MIB*1024)))
	stop: bool
	writers: [WRITERS]Writer
	workers: [WRITERS]^thread.Thread
	for &w, i in writers {
		check(db.insert(source, "INSERT INTO writers VALUES(?,0)", {i64(i)}))
		w = Writer{connection=open_db(path), id=i64(i), stop=&stop}
		check(db.execute_sql(w.connection, "PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA wal_autocheckpoint=0"))
	}
	for &w, i in writers {
		workers[i] = thread.create_and_start_with_data(&w, write_loop, runtime.default_context())
		if workers[i] == nil do panic("could not start writer")
	}
	start := time.tick_now()
	snapshots, active_checkpoints := 0, 0
	last_rows: i64
	max_restore: time.Duration
	for time.tick_since(start) < SECONDS*time.Second {
		time.sleep(time.Second)
		// PASSIVE returns the number of WAL frames and frames checkpointed.
		read_checkpoint :: proc(stmt: ^db.SQLite_Statement, out: ^i64) -> db.Database_Error {
			value, err := db.column_int(stmt, 2)
			out^ = value
			return err
		}
		frames: i64
		found, checkpoint_err := db.query_one(source, "PRAGMA wal_checkpoint(PASSIVE)", nil, &frames, read_checkpoint)
		check(checkpoint_err)
		if !found || frames < 0 do panic("WAL checkpoint unavailable")
		if frames > 0 do active_checkpoints += 1
		rows, duration := snapshot(source, backup_path, restore_path)
		if rows < last_rows do panic("snapshots went backwards")
		last_rows = rows
		max_restore = max(max_restore, duration)
		snapshots += 1
	}
	sync.atomic_store(&stop, true)
	all: [dynamic]time.Duration
	total, busy := 0, 0
	for &w, i in writers {
		thread.join(workers[i])
		thread.destroy(workers[i])
		if w.committed == 0 do panic("writer made no progress")
		if scalar(source, "SELECT total FROM writers WHERE id=?", {w.id}) != i64(w.committed) do panic("lost acknowledged commit")
		total += w.committed
		busy += w.busy
		append(&all, ..w.latencies[:])
		delete(w.latencies)
		db.close(w.connection)
	}
	if active_checkpoints == 0 do panic("no WAL frames checkpointed")
	if last_rows == 0 do panic("no snapshot captured writes")
	db.close(source)
	source = open_db(path)
	verify(source, i64(total))
	rows, duration := snapshot(source, backup_path, restore_path)
	if rows != i64(total) do panic("final snapshot lost commits")
	db.close(source)
	slice.sort(all[:])
	fmt.printf("writers=%d seed_MiB=%d commits=%d busy=%d attempts=%d p99_ms=%.3f concurrent_snapshots=%d active_checkpoints=%d max_restore_ms=%.3f final_restore_ms=%.3f\n",
	           WRITERS, SEED_MIB, total, busy, len(all), time.duration_milliseconds(all[len(all)-(len(all)/100)-1]),
	           snapshots, active_checkpoints, time.duration_milliseconds(max_restore), time.duration_milliseconds(duration))
	delete(all)
	if os.remove_all(directory) != nil do panic("could not clean work directory")
}
