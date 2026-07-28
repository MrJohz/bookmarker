import bookmarker/db
import gleam/dynamic/decode
import gleeunit/should
import simplifile
import sqlight

fn pragma(conn: sqlight.Connection, name: String) -> Int {
  let assert Ok([value]) =
    sqlight.query("PRAGMA " <> name <> ";", on: conn, with: [], expecting: {
      use value <- decode.field(0, decode.int)
      decode.success(value)
    })

  value
}

pub fn per_connection_pragmas_are_applied_test() {
  use conn <- db.with_connection(":memory:")

  pragma(conn, "foreign_keys") |> should.equal(1)
  pragma(conn, "busy_timeout") |> should.equal(5000)
  pragma(conn, "synchronous") |> should.equal(1)
  pragma(conn, "cache_size") |> should.equal(-20_000)
  pragma(conn, "temp_store") |> should.equal(2)
}

/// `journal_mode` is a no-op on `:memory:` databases, so this is the only way
/// to check that the file-level pragmas land.
pub fn file_databases_are_in_wal_mode_test() {
  let path = "build/db_test_wal.db"
  let _ = simplifile.delete(path)

  {
    use conn <- db.with_connection(path)

    let assert Ok(["wal"]) =
      sqlight.query("PRAGMA journal_mode;", on: conn, with: [], expecting: {
        use mode <- decode.field(0, decode.string)
        decode.success(mode)
      })

    pragma(conn, "journal_size_limit") |> should.equal(67_108_864)
  }

  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn foreign_keys_are_enforced_test() {
  use conn <- db.with_connection(":memory:")
  let assert Ok(schema) = simplifile.read("db/schema.sql")
  let assert Ok(Nil) = sqlight.exec(schema, on: conn)

  let insert =
    "INSERT INTO archives (bookmark_id, url, host, created_at)
     VALUES (999, 'http://example.com', 'example.com', 0);"

  let assert Error(sqlight.SqlightError(code, _, _)) =
    sqlight.exec(insert, on: conn)

  code |> should.equal(sqlight.ConstraintForeignkey)
}
