import bookmarker/bookmarks.{type BookmarkConn}
import bookmarker/db
import gleam/option.{None}
import gleam/time/timestamp
import gleeunit/should
import mock_clock
import simplifile
import sqlight

fn ts(iso: String) -> timestamp.Timestamp {
  let assert Ok(timestamp) = timestamp.parse_rfc3339(iso)
  timestamp
}

type Deps {
  Deps(conn: sqlight.Connection, clock: mock_clock.Clock)
}

fn with_test_conn(f: fn(BookmarkConn, Deps) -> a) -> a {
  use conn <- db.with_connection(":memory:")
  let assert Ok(schema) = simplifile.read("db/schema.sql")
  let assert Ok(Nil) = sqlight.exec(schema, on: conn)

  let clock = mock_clock.new(timestamp.from_unix_seconds(0))
  f(bookmarks.new(conn, mock_clock.now(clock)), Deps(conn:, clock:))
}

pub fn list_bookmarks_empty_test() {
  use bc, _ <- with_test_conn()

  bookmarks.list_bookmarks(bc) |> should.equal(Ok([]))
}

pub fn list_bookmarks_with_unarchived_entry_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let now = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, now)

  let assert Ok(_) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok([
    bookmarks.Bookmark(
      id: _,
      created_at:,
      url:,
      title: None,
      tags: [],
      archives: [],
    ),
  ]) = bookmarks.list_bookmarks(bc)

  created_at |> should.equal(now)
  url |> should.equal("http://example.com")
}

pub fn create_bookmark_returns_bookmark_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let now = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, now)

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert bookmarks.Bookmark(
    id: _,
    created_at:,
    url:,
    title: None,
    tags: [],
    archives: [],
  ) = bookmark

  created_at |> should.equal(now)
  url |> should.equal("http://example.com")

  let assert Ok([fetched_bookmark]) = bookmarks.list_bookmarks(bc)

  bookmark |> should.equal(fetched_bookmark)
}

pub fn add_tags_to_bookmark_updates_bookmark_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = bookmarks.add_tags(bc, bookmark, ["tag1", "tag2"])

  bookmark.tags |> should.equal(["tag1", "tag2"])
}

pub fn add_tags_to_bookmark_is_idempotent_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(_) = bookmarks.add_tags(bc, bookmark, ["tag1", "tag2"])
  let assert Ok(bookmark) = bookmarks.add_tags(bc, bookmark, ["tag1", "tag2"])

  bookmark.tags |> should.equal(["tag1", "tag2"])
}

pub fn add_tags_to_bookmark_merges_with_existing_tags_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = bookmarks.add_tags(bc, bookmark, ["tag1", "tag2"])
  let assert Ok(bookmark) = bookmarks.add_tags(bc, bookmark, ["tag2", "tag3"])

  bookmark.tags |> should.equal(["tag1", "tag2", "tag3"])
}

pub fn add_no_tags_produces_an_unchanged_bookmark_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark2) = bookmarks.add_tags(bc, bookmark, [])

  bookmark |> should.equal(bookmark2)
  bookmark.tags |> should.equal([])
}

pub fn bookmark_tags_are_fetched_fresh_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(original) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark1) = bookmarks.add_tags(bc, original, ["tag1", "tag2"])
  let assert Ok(bookmark2) = bookmarks.add_tags(bc, original, ["tag2", "tag3"])

  bookmark1.tags |> should.equal(["tag1", "tag2"])
  bookmark2.tags |> should.equal(["tag1", "tag2", "tag3"])
}
