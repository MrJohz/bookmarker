import cake
import cake/dialect/sqlite_dialect
import cake/insert as i
import cake/join as j
import cake/param
import cake/select as s
import cake/where as w
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import sqlight.{type Connection, type Error, type Value}

pub opaque type BookmarkConn {
  Bookmarks(db: Connection)
}

pub fn new(db: Connection) -> BookmarkConn {
  Bookmarks(db)
}

pub opaque type BookmarkId {
  BookmarkId(Int)
}

pub type Bookmark {
  Bookmark(
    id: BookmarkId,
    url: String,
    tags: Option(List(String)),
    archives: Option(List(String)),
  )
}

pub fn list_bookmarks(bc: BookmarkConn) -> Result(List(Bookmark), Error) {
  let sql =
    s.new()
    |> s.from_table("bookmarks")
    |> s.selects([s.col("bookmarks.id"), s.col("bookmarks.url")])
    |> s.to_query
    |> sqlite_dialect.read_query_to_prepared_statement
    |> cake.get_sql

  use entries <- result.try(
    sqlight.query(sql, on: bc.db, with: [], expecting: {
      use id <- decode.field(0, decode.int)
      use url <- decode.field(1, decode.string)
      decode.success(#(BookmarkId(id), url))
    }),
  )

  entries
  |> list.try_map(fn(tup) {
    let #(id, url) = tup
    use tags <- result.try(list_tags(bc, id))
    use archives <- result.try(list_archives(bc, id))
    Ok(Bookmark(id:, url:, tags:, archives:))
  })
}

pub fn add_bookmark(bc: BookmarkConn, url: String) -> Result(Bookmark, Error) {
  let prepared =
    [
      i.row([i.string(url)]),
    ]
    |> i.from_values(table_name: "bookmarks", columns: ["url"])
    |> i.returning(["id", "url"])
    |> i.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: bc.db, with:, expecting: {
      use id <- decode.field(0, decode.int)
      use url <- decode.field(1, decode.string)
      decode.success(Bookmark(
        id: BookmarkId(id),
        url:,
        tags: option.None,
        archives: option.None,
      ))
    }),
  )

  let assert [bookmark] = entries

  Ok(bookmark)
}

fn list_archives(
  _bc: BookmarkConn,
  _bookmark: BookmarkId,
) -> Result(Option(List(String)), Error) {
  Ok(option.None)
}

fn list_tags(
  bc: BookmarkConn,
  bookmark: BookmarkId,
) -> Result(Option(List(String)), Error) {
  let BookmarkId(id) = bookmark
  let prepared =
    s.new()
    |> s.from_table("tags")
    |> s.join(j.left(
      with: j.table("tag_bookmarks"),
      on: w.col("tb.tag_id") |> w.eq(w.col("tags.id")),
      alias: "tb",
    ))
    |> s.where(w.col("tb.bookmark_id") |> w.eq(w.int(id)))
    |> s.selects([s.col("tags.tag")])
    |> s.to_query
    |> sqlite_dialect.read_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: bc.db, with:, expecting: {
      use tag <- decode.field(0, decode.string)
      decode.success(tag)
    }),
  )

  case entries {
    [] -> Ok(option.None)
    _ -> Ok(option.Some(entries))
  }
}

fn param_to_value(p: param.Param) -> Value {
  case p {
    param.StringParam(v) -> sqlight.text(v)
    param.IntParam(v) -> sqlight.int(v)
    param.FloatParam(v) -> sqlight.float(v)
    param.BoolParam(v) -> sqlight.bool(v)
    param.NullParam -> sqlight.null()
    param.DateParam(_) -> panic as "no date columns in this query yet"
  }
}
