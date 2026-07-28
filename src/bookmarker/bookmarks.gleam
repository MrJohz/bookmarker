import bookmarker/utils
import cake
import cake/dialect/sqlite_dialect
import cake/insert as i
import cake/select as s
import cake/update as u
import cake/where as w
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import sqlight.{type Connection, type Error}

pub opaque type BookmarkConn {
  Bookmarks(db: Connection, now: fn() -> Timestamp)
}

pub fn new(db: Connection, now: fn() -> Timestamp) -> BookmarkConn {
  Bookmarks(db, now)
}

pub opaque type BookmarkId {
  BookmarkId(Int)
}

pub fn id_decoder() -> decode.Decoder(BookmarkId) {
  decode.int |> decode.map(BookmarkId)
}

pub fn id_to_int(id: BookmarkId) -> Int {
  let BookmarkId(value) = id
  value
}

/// A snapshot of a bookmark held by an archiving service.
///
/// `host` names the service (e.g. `web.archive.org`) and is unique per
/// bookmark, so it identifies the archive; `created_at` is when we last
/// recorded a URL for that service, which is how fresh the snapshot is.
pub type Archive {
  Archive(host: String, url: String, created_at: Timestamp)
}

pub type Bookmark {
  Bookmark(
    id: BookmarkId,
    url: String,
    title: Option(String),
    tags: List(String),
    archives: List(Archive),
    created_at: Timestamp,
  )
}

pub fn list_bookmarks(bc: BookmarkConn) -> Result(List(Bookmark), Error) {
  let sql =
    s.new()
    |> s.from_table("bookmarks")
    |> s.selects([
      s.col("bookmarks.id"),
      s.col("bookmarks.url"),
      s.col("bookmarks.title"),
      s.col("bookmarks.created_at"),
    ])
    |> s.to_query
    |> sqlite_dialect.read_query_to_prepared_statement
    |> cake.get_sql

  use entries <- result.try(
    sqlight.query(sql, on: bc.db, with: [], expecting: {
      use id <- decode.field(0, id_decoder())
      use url <- decode.field(1, decode.string)
      use title <- decode.field(2, decode.string |> decode.optional)
      use created_at <- decode.field(3, utils.timestamp_decoder())

      decode.success(#(id, url, title, created_at))
    }),
  )

  entries
  |> list.try_map(fn(tup) {
    let #(id, url, title, created_at) = tup
    use tags <- result.try(list_tags(bc, id))
    use archives <- result.try(list_archives(bc, id))
    Ok(Bookmark(id:, url:, title:, tags:, archives:, created_at:))
  })
}

pub fn add_bookmark(bc: BookmarkConn, url: String) -> Result(Bookmark, Error) {
  let prepared =
    [
      i.row([
        i.string(url),
        i.int(bc.now() |> utils.timestamp_to_millis),
      ]),
    ]
    |> i.from_values(table_name: "bookmarks", columns: ["url", "created_at"])
    |> i.returning(["id", "url", "created_at"])
    |> i.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(utils.param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: bc.db, with:, expecting: {
      use id <- decode.field(0, id_decoder())
      use url <- decode.field(1, decode.string)
      use created_at <- decode.field(2, utils.timestamp_decoder())

      decode.success(
        Bookmark(
          id:,
          url:,
          created_at:,
          title: option.None,
          tags: [],
          archives: [],
        ),
      )
    }),
  )

  let assert [bookmark] = entries

  Ok(bookmark)
}

pub fn add_tags(
  bc: BookmarkConn,
  bm: Bookmark,
  tags: List(String),
) -> Result(Bookmark, Error) {
  use _ <- result.try(case tags {
    [] -> Ok(Nil)
    tags -> {
      let BookmarkId(id) = bm.id
      let prepared =
        tags
        |> list.map(fn(tag) {
          [i.string(tag), i.int(id)]
          |> i.row
        })
        |> i.from_values(table_name: "tags", columns: ["tag", "bookmark_id"])
        |> i.on_columns_conflict_ignore(["tag", "bookmark_id"], where: w.none())
        |> i.to_query
        |> sqlite_dialect.write_query_to_prepared_statement

      let sql = cake.get_sql(prepared)
      let with = cake.get_params(prepared) |> list.map(utils.param_to_value)

      use _ <- result.try(
        sqlight.query(sql, on: bc.db, with:, expecting: { decode.success(Nil) }),
      )
      Ok(Nil)
    }
  })

  use tags <- result.try(list_tags(bc, bm.id))
  Ok(Bookmark(..bm, tags:))
}

/// Record the archive of `bm` held by `host` (the archiving service, e.g.
/// `web.archive.org`) at `url`.
///
/// We keep at most one archive per host per bookmark, so re-archiving replaces
/// the URL we hold rather than accumulating rows — `UNIQUE (bookmark_id, host)`
/// plus the upsert below make that a single statement, which is how we get
/// atomicity without a transaction.
pub fn add_archive(
  bc: BookmarkConn,
  bm: Bookmark,
  host: String,
  url: String,
) -> Result(Bookmark, Error) {
  let BookmarkId(id) = bm.id
  let created_at = bc.now() |> utils.timestamp_to_millis

  let prepared =
    [i.row([i.int(id), i.string(host), i.string(url), i.int(created_at)])]
    |> i.from_values(table_name: "archives", columns: [
      "bookmark_id",
      "host",
      "url",
      "created_at",
    ])
    |> i.on_columns_conflict_update(
      ["bookmark_id", "host"],
      where: w.none(),
      update: u.new()
        |> u.sets([
          u.set_string("url", url),
          u.set_int("created_at", created_at),
        ]),
    )
    |> i.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(utils.param_to_value)

  use _ <- result.try(
    sqlight.query(sql, on: bc.db, with:, expecting: { decode.success(Nil) }),
  )

  use archives <- result.try(list_archives(bc, bm.id))
  Ok(Bookmark(..bm, archives:))
}

/// Set (or, with `None`, clear) the title of `bm`.
///
/// Titles are filled in later by the scraper, so this always overwrites — a
/// re-scrape refreshes a stale title, and `None` lets a caller drop one that
/// turned out to be wrong. We rebuild from the `RETURNING` value rather than
/// from the argument so the record we hand back is what the database actually
/// stores.
pub fn set_title(
  bc: BookmarkConn,
  bm: Bookmark,
  title: Option(String),
) -> Result(Bookmark, Error) {
  let BookmarkId(id) = bm.id

  let prepared =
    u.new()
    |> u.table("bookmarks")
    |> u.sets([
      case title {
        option.Some(title) -> u.set_string("title", title)
        option.None -> u.set_null("title")
      },
    ])
    |> u.where(w.col("bookmarks.id") |> w.eq(w.int(id)))
    |> u.returning(["title"])
    |> u.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(utils.param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: bc.db, with:, expecting: {
      use title <- decode.field(0, decode.string |> decode.optional)
      decode.success(title)
    }),
  )

  let assert [title] = entries

  Ok(Bookmark(..bm, title:))
}

fn list_archives(
  bc: BookmarkConn,
  bookmark: BookmarkId,
) -> Result(List(Archive), Error) {
  let BookmarkId(id) = bookmark
  let prepared =
    s.new()
    |> s.from_table("archives")
    |> s.where(w.col("archives.bookmark_id") |> w.eq(w.int(id)))
    |> s.selects([
      s.col("archives.host"),
      s.col("archives.url"),
      s.col("archives.created_at"),
    ])
    |> s.order_by("archives.host", s.Asc)
    |> s.to_query
    |> sqlite_dialect.read_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(utils.param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: bc.db, with:, expecting: {
      use host <- decode.field(0, decode.string)
      use url <- decode.field(1, decode.string)
      use created_at <- decode.field(2, utils.timestamp_decoder())
      decode.success(Archive(host:, url:, created_at:))
    }),
  )

  Ok(entries)
}

fn list_tags(
  bc: BookmarkConn,
  bookmark: BookmarkId,
) -> Result(List(String), Error) {
  let BookmarkId(id) = bookmark
  let prepared =
    s.new()
    |> s.from_table("tags")
    |> s.where(w.col("tags.bookmark_id") |> w.eq(w.int(id)))
    |> s.selects([s.col("tags.tag")])
    |> s.order_by("tags.tag", s.Asc)
    |> s.to_query
    |> sqlite_dialect.read_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(utils.param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: bc.db, with:, expecting: {
      use tag <- decode.field(0, decode.string)
      decode.success(tag)
    }),
  )

  Ok(entries)
}
