import bookmarker/bookmarks.{type BookmarkConn}
import gleam/option.{None}
import gleeunit/should
import simplifile
import sqlight

/// Opens an empty in-memory database with the schema from `db/schema.sql`
/// applied, so tests always run against the same tables as production.
fn with_test_db(f: fn(BookmarkConn) -> a) -> a {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(schema) = simplifile.read("db/schema.sql")
  let assert Ok(Nil) = sqlight.exec(schema, on: conn)

  f(bookmarks.new(conn))
}

// gleeunit test functions end in `_test`
pub fn list_bookmarks_empty_test() {
  use bc <- with_test_db()

  bookmarks.list_bookmarks(bc) |> should.equal(Ok([]))
}

pub fn list_bookmarks_with_unarchived_entry_test() {
  use bc <- with_test_db()

  let assert Ok(_) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok([
    bookmarks.Bookmark(
      url: "http://example.com",
      tags: None,
      archives: None,
      ..,
    ),
  ]) = bookmarks.list_bookmarks(bc)
}

pub fn create_bookmark_returns_bookmark_test() {
  use bc <- with_test_db()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert bookmarks.Bookmark(
    url: "http://example.com",
    tags: None,
    archives: None,
    ..,
  ) = bookmark

  let assert Ok([fetched_bookmark]) = bookmarks.list_bookmarks(bc)

  bookmark |> should.equal(fetched_bookmark)
}
