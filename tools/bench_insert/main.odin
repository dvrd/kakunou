package main

import db "../../src"
import "core:fmt"
import "core:slice"
import "core:time"

foreign import sqlite "system:sqlite3"
foreign sqlite {
	sqlite3_reset :: proc "c" (statement: ^db.SQLite_Statement) -> db.SQLite_Result ---
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

sample :: proc(reuse: bool) -> f64 {
	database: ^db.SQLite_DB
	check(db.open(&database, ":memory:"))
	defer db.close(database)
	check(db.execute_sql(database, "CREATE TABLE items(value INTEGER NOT NULL)"))
	check(db.begin_immediate(database))
	start := time.tick_now()
	if reuse {
		statement, err := db.prepare(database, SQL, "empty insert")
		check(err)
		for i in 0..<ROWS {
			// Match insert's per-call mutex and binding checks.
			mutex := db.connection_mutex(database)
			db.sqlite3_mutex_enter(mutex)
			check(db.insert_statement(database, statement, {i64(i)}))
			code := sqlite3_reset(statement)
			db.sqlite3_mutex_leave(mutex)
			if code != .OK do panic("reset failed")
		}
		db.statement_finalize(statement, &err, "finalize failed")
		check(err)
	} else {
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
	sample(false)
	sample(true)
	per_call, reused: [SAMPLES]f64
	for i in 0..<SAMPLES {
		if i%2 == 0 {
			per_call[i], reused[i] = sample(false), sample(true)
		} else {
			reused[i], per_call[i] = sample(true), sample(false)
		}
	}
	slice.sort(per_call[:])
	slice.sort(reused[:])
	fmt.printf("Median elapsed: prepare per insert %.2f ms; reuse %.2f ms (%.2fx)\n",
	           per_call[SAMPLES/2], reused[SAMPLES/2], per_call[SAMPLES/2]/reused[SAMPLES/2])
}
