package integration_tests

import "base:runtime"
import "core:testing"
import "core:thread"
import db "shared:kakunou"

@(test)
prepared_statement_recovers_after_errors_and_rejects_result_rows_before_writing :: proc(t: ^testing.T) {
	c, ok := test_insert_database(t)
	if !ok do return
	defer db.close(c)

	write :: proc(q: db.Prepared_Statement, t: ^testing.T) -> db.Database_Error {
		testing.expect_value(t, db.prepared_execute(q, {i64(1)}).sqlite_code, .RANGE)
		testing.expect_value(t, db.prepared_execute(q, {i64(1), cstring("first")}).kind, .None)
		testing.expect_value(t, db.prepared_execute(q, {i64(1), cstring("duplicate")}).sqlite_code, .CONSTRAINT)
		return db.prepared_execute(q, {i64(2), cstring("second")})
	}
	if !testing.expect_value(t, db.with_prepared(c, "INSERT INTO items VALUES(?, ?)", t, write).kind, .None) do return
	rejected :: proc(q: db.Prepared_Statement, t: ^testing.T) -> db.Database_Error {
		return db.prepared_execute(q, nil)
	}
	err := db.with_prepared(c, "INSERT INTO items VALUES(3,'third') RETURNING id", t, rejected)
	testing.expect_value(t, err.sqlite_code, .MISUSE)
	test_database_count(t, c, "SELECT count(*) FROM items", 2)

	err = db.with_prepared(c, "DELETE FROM items; SELECT 1", t, rejected)
	testing.expect_value(t, err.sqlite_code, .MISUSE)
	test_database_count(t, c, "SELECT count(*) FROM items", 2)
}

@(test)
prepared_query_handles_missing_rows_and_recursive_decoders :: proc(t: ^testing.T) {
	c, ok := test_insert_database(t)
	if !ok do return
	defer db.close(c)
	body :: proc(q: db.Prepared_Statement, t: ^testing.T) -> db.Database_Error {
		Result :: struct {
			q: db.Prepared_Statement,
			nested_error: db.Database_Error,
			value: i64,
		}
		decode :: proc(stmt: ^db.SQLite_Statement, out: ^Result) -> db.Database_Error {
			out.nested_error = db.prepared_execute(out.q, {i64(0)})
			value, err := db.column_int(stmt, 0)
			out.value = value
			return err
		}
		result := Result{q = q}
		found, err := db.prepared_query_one(q, {i64(0)}, &result, decode)
		testing.expect_value(t, err.kind, .None)
		testing.expect(t, !found)
		for i in 1..=2 {
			found, err = db.prepared_query_one(q, {i64(i)}, &result, decode)
			testing.expect_value(t, err.kind, .None)
			testing.expect(t, found)
			testing.expect_value(t, result.nested_error.sqlite_code, .MISUSE)
			testing.expect_value(t, result.value, i64(i))
		}
		return {}
	}
	testing.expect_value(t, db.begin_read(c).kind, .None)
	defer db.rollback_transaction(c)
	testing.expect_value(t, db.with_prepared(c, "SELECT ?1 WHERE ?1 > 0", t, body).kind, .None)
}

@(test)
prepared_query_serializes_shared_statement_calls :: proc(t: ^testing.T) {
	c, ok := test_insert_database(t)
	if !ok do return
	defer db.close(c)
	body :: proc(q: db.Prepared_Statement, t: ^testing.T) -> db.Database_Error {
		Job :: struct { q: db.Prepared_Statement, value: i64, ok: bool }
		run :: proc(data: rawptr) {
			job := cast(^Job)data
			decode :: proc(stmt: ^db.SQLite_Statement, out: ^i64) -> db.Database_Error {
				value, err := db.column_int(stmt, 0)
				out^ = value
				return err
			}
			for _ in 0..<1000 {
				got: i64
				found, err := db.prepared_query_one(job.q, {job.value}, &got, decode)
				if !found || err.kind != .None || got != job.value do return
			}
			job.ok = true
		}
		first := Job{q = q, value = 42}
		second := Job{q = q, value = 81}
		worker := thread.create_and_start_with_data(&first, run, runtime.default_context())
		if !testing.expect(t, worker != nil) do return {}
		run(&second)
		thread.join(worker)
		thread.destroy(worker)
		testing.expect(t, first.ok && second.ok)
		return {}
	}
	testing.expect_value(t, db.with_prepared(c, "SELECT ?", t, body).kind, .None)
}

@(test)
prepared_statement_releases_borrowed_values_after_partial_binding_and_decode :: proc(t: ^testing.T) {
	c, ok := test_insert_database(t)
	if !ok do return
	defer db.close(c)
	body :: proc(q: db.Prepared_Statement, t: ^testing.T) -> db.Database_Error {
		Result :: struct {
			parameters: []db.SQLite_Value,
			statement: ^db.SQLite_Statement,
			data: []u8,
		}
		decode :: proc(stmt: ^db.SQLite_Statement, out: ^Result) -> db.Database_Error {
			out.statement = stmt
			data, err := db.column_blob(stmt, 0, context.temp_allocator)
			out.data = data
			// The decoder can change the caller's parameter array after binding.
			for &p in out.parameters do p = i64(0)
			return err
		}
		bytes := []u8{1, 0, 255}
		params := [2]db.SQLite_Value{bytes, db.SQLite_Value{}}
		result := Result{parameters = params[:]}
		_, bad := db.prepared_query_one(q, params[:], &result, decode)
		testing.expect_value(t, bad.sqlite_code, .MISUSE)
		for i in 1..=3 {
			bytes[0] = u8(i)
			params = {bytes, cstring("yes")}
			found, err := db.prepared_query_one(q, params[:], &result, decode)
			testing.expect_value(t, err.kind, .None)
			if !testing.expect(t, found && len(result.data) == 3) do return err
			testing.expect_value(t, result.data[0], u8(i))
			testing.expect_value(t, result.data[2], u8(255))
			// Without rebinding, the cleared ?2 predicate must yield no row.
			testing.expect_value(t, db.sqlite3_step(result.statement), .DONE)
			testing.expect_value(t, db.sqlite3_reset(result.statement), .OK)
		}
		return {}
	}
	testing.expect_value(t, db.with_prepared(c, "SELECT ?1 WHERE ?2='yes'", t, body).kind, .None)
}

@(test)
prepared_lookup_preserves_the_decoder_error_and_recovers :: proc(t: ^testing.T) {
	c, ok := test_insert_database(t)
	if !ok do return
	defer db.close(c)

	body :: proc(q: db.Prepared_Statement, t: ^testing.T) -> db.Database_Error {
		decode :: proc(stmt: ^db.SQLite_Statement, result: ^db.Database_Error) -> db.Database_Error {
			return result^
		}
		diagnostic := db.make_error(.Execution_Failed, "invalid identifier", .MISMATCH, subject = "id")
		diagnostic.cleanup_code = .BUSY
		found, err := db.prepared_query_one(q, {i64(1)}, &diagnostic, decode)
		testing.expect(t, !found)
		testing.expect_value(t, err, diagnostic)

		found, err = db.prepared_query_one(q, {i64(0)}, &diagnostic, decode)
		testing.expect(t, !found)
		testing.expect_value(t, err, db.Database_Error{})

		diagnostic = {}
		found, err = db.prepared_query_one(q, {i64(1)}, &diagnostic, decode)
		testing.expect(t, found)
		testing.expect_value(t, err, db.Database_Error{})
		return {}
	}
	testing.expect_value(t, db.with_prepared(c, "SELECT 1 WHERE ?", t, body).kind, .None)
}
