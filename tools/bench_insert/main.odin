package main

import db "../../src"
import "core:fmt"
import "core:slice"
import "core:time"

foreign import sqlite "system:sqlite3"
foreign sqlite {
	sqlite3_libversion :: proc "c" () -> cstring ---
}

ROWS :: 50_000
SAMPLES :: 9
SQL :: "INSERT INTO items VALUES (?)"

check :: proc(err: db.Database_Error) {
	if err.kind != .None {
		diagnostic := err
		panic(db.error_message(&diagnostic))
	}
}

Insert_Path :: enum { Per_Call, Reuse, Batch }

sample :: proc(path: Insert_Path) -> f64 {
	database: ^db.SQLite_DB
	check(db.open(&database, ":memory:"))
	defer db.close(database)
	check(db.execute_sql(database, "CREATE TABLE items(value INTEGER NOT NULL)"))
	check(db.begin_immediate(database))
	start := time.tick_now()
	switch path {
	case .Batch:
		buffer: [256][1]db.SQLite_Value
		for start := 0; start < ROWS; start += len(buffer) {
			rows := buffer[:min(ROWS-start, len(buffer))]
			for &row, i in rows {
				row[0] = i64(start+i)
			}
			check(db.insert_many(database, SQL, rows))
		}
	case .Reuse:
		statement, err := db.prepare(database, SQL, "empty insert")
		check(err)
		for i in 0..<ROWS {
			// Match insert's per-call mutex and binding checks.
			mutex := db.connection_mutex(database)
			db.sqlite3_mutex_enter(mutex)
			check(db.insert_statement(database, statement, {i64(i)}))
			code := db.sqlite3_reset(statement)
			db.sqlite3_mutex_leave(mutex)
			if code != .OK do panic("reset failed")
		}
		db.statement_finalize(statement, &err, "finalize failed")
		check(err)
	case .Per_Call:
		for i in 0..<ROWS {
			check(db.insert(database, SQL, {i64(i)}))
		}
	}
	elapsed := time.duration_milliseconds(time.tick_since(start))
	check(db.commit_transaction(database))
	decode :: proc(stmt: ^db.SQLite_Statement, result: ^[2]i64) -> db.Database_Error {
		err: db.Database_Error
		result[0], err = db.column_int(stmt, 0)
		if err.kind != .None do return err
		result[1], err = db.column_int(stmt, 1)
		return err
	}
	totals: [2]i64
	found, err := db.query_one(database, "SELECT count(*), sum(value) FROM items", nil, &totals, decode)
	check(err)
	expected := [2]i64{ROWS, i64(ROWS)*(ROWS-1)/2}
	if !found || totals != expected do panic("incorrect insert results")
	return elapsed
}

main :: proc() {
	fmt.printf("SQLite %s, %d inserts per transaction, %d measured samples per path\n",
	           sqlite3_libversion(), ROWS, SAMPLES)
	paths := [?]Insert_Path{.Per_Call, .Reuse, .Batch}
	for path in paths {
		sample(path)
	}
	timings: [Insert_Path][SAMPLES]f64
	for i in 0..<SAMPLES {
		for j in 0..<len(paths) {
			path := paths[(i+j)%len(paths)]
			timings[path][i] = sample(path)
		}
	}
	for path in paths {
		slice.sort(timings[path][:])
	}
	fmt.printf("Median elapsed: prepare per insert %.2f ms; reuse %.2f ms; batch (256 rows) %.2f ms\n",
	           timings[.Per_Call][SAMPLES/2], timings[.Reuse][SAMPLES/2], timings[.Batch][SAMPLES/2])
}
