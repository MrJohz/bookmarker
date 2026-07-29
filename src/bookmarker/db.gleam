import exception
import gleam/result
import sqlight.{type Connection, type Error}

/// Applied to every connection we open.
///
/// `journal_mode` is stored in the database file rather than on the
/// connection, so setting it again is a cheap no-op — it is here so that the
/// mode is guaranteed regardless of how the file was first created. The rest
/// are per-connection settings and genuinely have to be set every time; in
/// particular `foreign_keys` defaults to off, and is silently ignored if it is
/// set once a transaction is already open.
///
/// Note that `journal_mode` has no effect on `:memory:` databases, which are
/// always journal_mode=memory.
const pragmas = "
  PRAGMA foreign_keys = ON;
  PRAGMA busy_timeout = 5000;
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA cache_size = -20000;
  PRAGMA temp_store = MEMORY;
  PRAGMA journal_size_limit = 67108864;
"

/// Open a connection with the project's pragmas applied.
///
/// Every connection must be opened through here — with esqlite each
/// connection carries its own settings, so a connection opened directly
/// through `sqlight` would silently run without foreign key enforcement.
pub fn open(path: String) -> Result(Connection, Error) {
  use conn <- result.try(sqlight.open(path))
  use _ <- result.map(sqlight.exec(pragmas, on: conn))
  conn
}

/// As `open`, but closes the connection once `f` returns.
pub fn with_connection(path: String, f: fn(Connection) -> a) -> a {
  let assert Ok(conn) = open(path)
  let value = f(conn)
  let assert Ok(Nil) = sqlight.close(conn)
  value
}

/// Run `f`'s statements as one unit: commit if it returns `Ok`, roll back
/// every write it made if it returns `Error` or crashes.
///
/// `IMMEDIATE` takes the write lock up front. A plain `BEGIN` is deferred, so a
/// transaction that reads before it writes has to upgrade its lock partway
/// through — and SQLite cannot make that wait, so it returns `SQLITE_BUSY`
/// immediately rather than honouring `busy_timeout`. Every transaction here
/// writes, so there is nothing to gain by deferring.
///
/// SQLite has no nested transactions, so `f` must not call this again — the
/// inner `BEGIN` fails. Reach for `SAVEPOINT` if that ever needs to work.
pub fn transaction(
  conn: Connection,
  f: fn() -> Result(a, Error),
) -> Result(a, Error) {
  use _ <- result.try(sqlight.exec("BEGIN IMMEDIATE;", on: conn))

  // A crash in `f` — a failed `let assert`, say — would otherwise leave the
  // transaction open, taking every later write on this connection with it.
  use <- exception.on_crash(fn() { sqlight.exec("ROLLBACK;", on: conn) })

  case f() {
    Ok(value) -> {
      use _ <- result.map(sqlight.exec("COMMIT;", on: conn))
      value
    }
    Error(e) -> {
      let _ = sqlight.exec("ROLLBACK;", on: conn)
      Error(e)
    }
  }
}
