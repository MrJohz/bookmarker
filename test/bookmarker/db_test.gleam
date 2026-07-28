import bookmarker/db
import gleam/dynamic/decode
import gleam/list
import gleam/string
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

/// The name and DDL of every object in a database, as SQLite stored it.
///
/// `schema_migrations` is dbmate's bookkeeping table, which only exists in the
/// dump, and the `sqlite_%` objects (`sqlite_sequence`, implicit indexes) are
/// derived from the DDL we're already comparing.
fn schema_objects(conn: sqlight.Connection) -> List(#(String, String)) {
  let query =
    "SELECT name, sql FROM sqlite_master
     WHERE sql IS NOT NULL
       AND name NOT LIKE 'sqlite_%'
       AND name != 'schema_migrations'
     ORDER BY name;"

  let assert Ok(objects) =
    sqlight.query(query, on: conn, with: [], expecting: {
      use name <- decode.field(0, decode.string)
      use sql <- decode.field(1, decode.string)
      decode.success(#(name, sql))
    })

  objects
}

/// `db/schema.sql` is dbmate's dump of the migrations, but nothing makes you
/// regenerate it when you add or edit one — and the tests build their databases
/// from the dump while real databases are built from the migrations. So build
/// both and check they agree.
///
/// If this fails, regenerate the dump with `dbmate dump`. Don't hand-edit
/// `db/schema.sql`: it is generated, and the next `dbmate` run will overwrite
/// whatever you write there.
pub fn schema_matches_migrations_test() {
  use from_schema <- db.with_connection(":memory:")
  use from_migrations <- db.with_connection(":memory:")

  let assert Ok(dump) = simplifile.read("db/schema.sql")
  let assert Ok(Nil) = sqlight.exec(dump, on: from_schema)

  // dbmate names migrations `<timestamp>_<name>.sql`, so sorting by filename
  // applies them in the order dbmate would.
  let assert Ok(files) = simplifile.read_directory("db/migrations")
  files
  |> list.filter(string.ends_with(_, ".sql"))
  |> list.sort(string.compare)
  |> list.each(fn(file) {
    let assert Ok(migration) = simplifile.read("db/migrations/" <> file)
    // Running the whole file would create everything and then drop it again.
    let assert [up, ..] = string.split(migration, "-- migrate:down")
    let assert Ok(Nil) = sqlight.exec(up, on: from_migrations)
  })

  let schema = schema_objects(from_schema)
  let migrations = schema_objects(from_migrations)

  // Compare the names first and then each object on its own, so that a failure
  // names what drifted instead of printing two entire schemas side by side.
  let names = fn(objects: List(#(String, String))) {
    list.map(objects, fn(object) { object.0 })
  }
  names(schema) |> should.equal(names(migrations))

  list.zip(schema, migrations)
  |> list.each(fn(pair) { pair.0 |> should.equal(pair.1) })
}
