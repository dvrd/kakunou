package main

import db "../../src"
import "core:fmt"
import "core:slice"
import "core:time"

COUNT :: 10_000
SAMPLES :: 15
Operation :: enum { Lookup, Update, Delete }
sql := [Operation]cstring{
	.Lookup = "SELECT value FROM items WHERE id=?",
	.Update = "UPDATE items SET value=value+1 WHERE id=?",
	.Delete = "DELETE FROM items WHERE id=?",
}

check :: proc(err: db.Database_Error) {
	if err.kind != .None {
		diagnostic := err
		panic(db.error_message(&diagnostic))
	}
}

read_int :: proc(stmt: ^db.SQLite_Statement, out: ^i64) -> db.Database_Error {
	value, err := db.column_int(stmt, 0)
	out^ = value
	return err
}

Work :: struct { database: ^db.SQLite_DB, operation: Operation }

run_items :: proc(query: db.Prepared_Statement, work: Work) -> db.Database_Error {
	for i in 1..=COUNT {
		parameters := [1]db.SQLite_Value{i64(i)}
		err: db.Database_Error
		if work.operation == .Lookup {
			value: i64
			found: bool
			if query != nil {
				found, err = db.prepared_query_one(query, parameters[:], &value, read_int)
			} else {
				found, err = db.query_one(work.database, sql[.Lookup], parameters[:], &value, read_int)
			}
			if err.kind == .None && (!found || value != i64(i)) do panic("incorrect lookup")
		} else if query != nil {
			err = db.prepared_execute(query, parameters[:])
		} else {
			err = db.insert(work.database, sql[work.operation], parameters[:])
		}
		if err.kind != .None do return err
	}
	return {}
}

sample :: proc(operation: Operation, reuse: bool) -> f64 {
	c: ^db.SQLite_DB
	check(db.open(&c, ":memory:"))
	defer db.close(c)
	check(db.execute_sql(c, "CREATE TABLE items(id INTEGER PRIMARY KEY, value INTEGER NOT NULL)"))
	seed := fmt.ctprintf("WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<%d) INSERT INTO items SELECT i,i FROM n", COUNT)
	check(db.execute_sql(c, seed))
	check(db.begin_immediate(c))
	work := Work{c, operation}
	start := time.tick_now()
	if reuse {
		check(db.with_prepared(c, sql[operation], work, run_items))
	} else {
		check(run_items(nil, work))
	}
	duration := time.duration_milliseconds(time.tick_since(start))
	check(db.commit_transaction(c))
	total: i64
	found, err := db.query_one(c, "SELECT coalesce(sum(value),0) FROM items", nil, &total, read_int)
	check(err)
	expected := i64(COUNT * (COUNT+1) / 2)
	if operation == .Update do expected += COUNT
	if operation == .Delete do expected = 0
	if !found || total != expected do panic("incorrect final sum")
	return duration
}

main :: proc() {
	for op in Operation {
		sample(op, false)
		sample(op, true)
		times: [2][SAMPLES]f64
		for n in 0..<SAMPLES {
			for j in 0..<2 {
				path := (n+j)%2
				times[path][n] = sample(op, path == 1)
				free_all(context.temp_allocator)
			}
		}
		for &path in times do slice.sort(path[:])
		fmt.printf("%v (%d operations): one-shot %.2f ms, prepared %.2f ms\n",
		           op, COUNT, times[0][SAMPLES/2], times[1][SAMPLES/2])
	}
}
