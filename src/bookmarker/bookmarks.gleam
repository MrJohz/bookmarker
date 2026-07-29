import bookmarker/db
import bookmarker/utils
import cake
import cake/delete as d
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

pub type Archive {
  Archive(host: String, url: String, created_at: Timestamp)
}

pub type Bookmark {
  Bookmark(
    id: BookmarkId,
    url: String,
    canonical_url: Option(String),
    content: Option(String),
    title: Option(String),
    tags: List(String),
    archives: List(Archive),
    created_at: Timestamp,
  )
}

pub fn list_bookmarks(bc: BookmarkConn) -> Result(List(Bookmark), Error) {
  let prepared =
    s.new()
    |> s.from_table("bookmarks")
    |> s.selects([
      s.col("bookmarks.id"),
      s.col("bookmarks.url"),
      s.col("bookmarks.title"),
      s.col("bookmarks.created_at"),
      s.col("bookmarks.canonical_url"),
      s.col("bookmarks.content"),
    ])
    |> s.to_query
    |> sqlite_dialect.read_query_to_prepared_statement

  use entries <- result.try(
    query(prepared, on: bc, expecting: {
      use id <- decode.field(0, id_decoder())
      use url <- decode.field(1, decode.string)
      use title <- decode.field(2, decode.string |> decode.optional)
      use created_at <- decode.field(3, utils.timestamp_decoder())
      use canonical_url <- decode.field(4, decode.string |> decode.optional)
      use content <- decode.field(5, decode.string |> decode.optional)

      decode.success(
        Bookmark(
          id:,
          url:,
          title:,
          created_at:,
          canonical_url:,
          content:,
          tags: [],
          archives: [],
        ),
      )
    }),
  )

  entries
  |> list.try_map(fn(bm) {
    use tags <- result.try(list_tags(bc, bm.id))
    use archives <- result.try(list_archives(bc, bm.id))
    Ok(Bookmark(..bm, tags:, archives:))
  })
}

pub fn add_bookmark(bc: BookmarkConn, url: String) -> Result(Bookmark, Error) {
  let prepared =
    [i.row([i.string(url), i.int(bc.now() |> utils.timestamp_to_millis)])]
    |> i.from_values(table_name: "bookmarks", columns: ["url", "created_at"])
    |> i.returning(["id", "url", "created_at"])
    |> i.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  use entries <- result.try(
    query(prepared, on: bc, expecting: {
      use id <- decode.field(0, id_decoder())
      use url <- decode.field(1, decode.string)
      use created_at <- decode.field(2, utils.timestamp_decoder())

      decode.success(
        Bookmark(
          id:,
          url:,
          created_at:,
          canonical_url: option.None,
          content: option.None,
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

pub fn clear_bookmark(
  bc: BookmarkConn,
  bm: Bookmark,
) -> Result(Bookmark, Error) {
  use <- db.transaction(bc.db)

  use bm <- result.try(clear_tags(bc, bm))
  use bm <- result.try(clear_archives(bc, bm))

  use _ <- result.try(
    update_bookmark(bc, bm.id, [
      u.set_null("canonical_url"),
      u.set_null("content"),
      u.set_null("title"),
    ]),
  )

  Ok(
    Bookmark(
      ..bm,
      canonical_url: option.None,
      content: option.None,
      title: option.None,
    ),
  )
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
        |> list.map(fn(tag) { [i.string(tag), i.int(id)] |> i.row })
        |> i.from_values(table_name: "tags", columns: ["tag", "bookmark_id"])
        |> i.on_columns_conflict_ignore(["tag", "bookmark_id"], where: w.none())
        |> i.to_query
        |> sqlite_dialect.write_query_to_prepared_statement

      query(prepared, on: bc, expecting: decode.success(Nil))
      |> result.replace(Nil)
    }
  })

  use tags <- result.try(list_tags(bc, bm.id))
  Ok(Bookmark(..bm, tags:))
}

pub fn remove_tags(
  bc: BookmarkConn,
  bm: Bookmark,
  tags: List(String),
) -> Result(Bookmark, Error) {
  let BookmarkId(id) = bm.id
  let prepared =
    d.new()
    |> d.table("tags")
    |> d.where(w.col("bookmark_id") |> w.eq(w.int(id)))
    |> d.where(w.col("tag") |> w.in(tags |> list.map(w.string)))
    |> d.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  use _ <- result.try(query(prepared, on: bc, expecting: decode.success(Nil)))

  use tags <- result.try(list_tags(bc, bm.id))
  Ok(Bookmark(..bm, tags:))
}

pub fn clear_tags(bc: BookmarkConn, bm: Bookmark) -> Result(Bookmark, Error) {
  let BookmarkId(id) = bm.id
  let prepared =
    d.new()
    |> d.table("tags")
    |> d.where(w.col("bookmark_id") |> w.eq(w.int(id)))
    |> d.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  use _ <- result.try(query(prepared, on: bc, expecting: decode.success(Nil)))

  Ok(Bookmark(..bm, tags: []))
}

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

  use _ <- result.try(query(prepared, on: bc, expecting: decode.success(Nil)))

  use archives <- result.try(list_archives(bc, bm.id))
  Ok(Bookmark(..bm, archives:))
}

pub fn remove_archive(
  bc: BookmarkConn,
  bm: Bookmark,
  host: String,
) -> Result(Bookmark, Error) {
  let BookmarkId(id) = bm.id
  let prepared =
    d.new()
    |> d.table("archives")
    |> d.where(w.col("bookmark_id") |> w.eq(w.int(id)))
    |> d.where(w.col("host") |> w.eq(w.string(host)))
    |> d.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  use _ <- result.try(query(prepared, on: bc, expecting: decode.success(Nil)))

  use archives <- result.try(list_archives(bc, bm.id))
  Ok(Bookmark(..bm, archives:))
}

pub fn clear_archives(
  bc: BookmarkConn,
  bm: Bookmark,
) -> Result(Bookmark, Error) {
  let BookmarkId(id) = bm.id
  let prepared =
    d.new()
    |> d.table("archives")
    |> d.where(w.col("bookmark_id") |> w.eq(w.int(id)))
    |> d.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  use _ <- result.try(query(prepared, on: bc, expecting: decode.success(Nil)))

  Ok(Bookmark(..bm, archives: []))
}

pub fn set_title(
  bc: BookmarkConn,
  bm: Bookmark,
  title: Option(String),
) -> Result(Bookmark, Error) {
  use _ <- result.try(
    update_bookmark(bc, bm.id, [set_nullable_string("title", title)]),
  )

  Ok(Bookmark(..bm, title:))
}

pub fn set_content(
  bc: BookmarkConn,
  bm: Bookmark,
  content: Option(String),
) -> Result(Bookmark, Error) {
  use _ <- result.try(
    update_bookmark(bc, bm.id, [set_nullable_string("content", content)]),
  )

  Ok(Bookmark(..bm, content:))
}

pub fn set_canonical_url(
  bc: BookmarkConn,
  bm: Bookmark,
  canonical_url: Option(String),
) -> Result(Bookmark, Error) {
  use _ <- result.try(
    update_bookmark(bc, bm.id, [
      set_nullable_string("canonical_url", canonical_url),
    ]),
  )

  Ok(Bookmark(..bm, canonical_url:))
}

/// Apply `sets` to the `bookmarks` row for `bookmark`.
///
/// The caller already knows the values it asked for, so this reads nothing
/// back — but it does insist the row was there. An update against a bookmark
/// that has since been deleted matches nothing, and without the `RETURNING`
/// row to count we would hand back a `Bookmark` describing a row that no
/// longer exists.
fn update_bookmark(
  bc: BookmarkConn,
  bookmark: BookmarkId,
  sets: List(u.UpdateSet),
) -> Result(Nil, Error) {
  let BookmarkId(id) = bookmark
  let prepared =
    u.new()
    |> u.table("bookmarks")
    |> u.sets(sets)
    |> u.where(w.col("bookmarks.id") |> w.eq(w.int(id)))
    |> u.returning(["id"])
    |> u.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  use rows <- result.try(query(prepared, on: bc, expecting: decode.success(Nil)))

  let assert [_] = rows

  Ok(Nil)
}

fn set_nullable_string(column: String, value: Option(String)) -> u.UpdateSet {
  case value {
    option.Some(value) -> u.set_string(column, value)
    option.None -> u.set_null(column)
  }
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

  query(prepared, on: bc, expecting: {
    use host <- decode.field(0, decode.string)
    use url <- decode.field(1, decode.string)
    use created_at <- decode.field(2, utils.timestamp_decoder())
    decode.success(Archive(host:, url:, created_at:))
  })
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

  query(prepared, on: bc, expecting: {
    use tag <- decode.field(0, decode.string)
    decode.success(tag)
  })
}

/// Run a cake-prepared statement against `bc`'s connection.
///
/// The only place cake's params are translated into sqlight values.
fn query(
  prepared: cake.PreparedStatement,
  on bc: BookmarkConn,
  expecting decoder: decode.Decoder(a),
) -> Result(List(a), Error) {
  sqlight.query(
    cake.get_sql(prepared),
    on: bc.db,
    with: cake.get_params(prepared) |> list.map(utils.param_to_value),
    expecting: decoder,
  )
}
