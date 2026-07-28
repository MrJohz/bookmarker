import bookmarker/bookmarks.{type BookmarkConn}
import bookmarker/db
import bookmarker/utils
import gleam/dynamic/decode
import gleam/option.{None, Some}
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

pub fn add_archive_to_bookmark_updates_bookmark_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    bookmarks.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )

  bookmark.archives |> should.equal(["http://web.archive.org/1"])
}

pub fn add_archive_replaces_the_archive_for_the_same_host_test() {
  use bc, Deps(conn:, clock:) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10Z"))

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) =
    bookmarks.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )

  let updated_at = ts("2026-02-01T00:00:00Z")
  mock_clock.set(clock, updated_at)
  let assert Ok(bookmark) =
    bookmarks.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/2",
    )

  bookmark.archives |> should.equal(["http://web.archive.org/2"])

  // `archives.created_at` isn't exposed on `Bookmark`, so read it directly.
  // The single row proves the upsert replaced rather than appended, and the
  // refreshed timestamp proves it replaced rather than ignoring the conflict —
  // an ignored insert would have left the original `created_at` behind.
  let assert Ok([created_at]) =
    sqlight.query(
      "SELECT created_at FROM archives;",
      on: conn,
      with: [],
      expecting: {
        use created_at <- decode.field(0, decode.int)
        decode.success(created_at)
      },
    )

  created_at |> should.equal(utils.timestamp_to_millis(updated_at))
}

pub fn add_archive_keeps_archives_from_different_hosts_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    bookmarks.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )
  let assert Ok(bookmark) =
    bookmarks.add_archive(bc, bookmark, "archive.ph", "http://archive.ph/1")

  // Ordered by host, so `archive.ph` sorts before `web.archive.org`.
  bookmark.archives
  |> should.equal(["http://archive.ph/1", "http://web.archive.org/1"])
}

pub fn bookmark_archives_are_fetched_fresh_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(original) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark1) =
    bookmarks.add_archive(
      bc,
      original,
      "web.archive.org",
      "http://web.archive.org/1",
    )
  let assert Ok(bookmark2) =
    bookmarks.add_archive(bc, original, "archive.ph", "http://archive.ph/1")

  bookmark1.archives |> should.equal(["http://web.archive.org/1"])
  bookmark2.archives
  |> should.equal(["http://archive.ph/1", "http://web.archive.org/1"])
}

pub fn list_bookmarks_with_archived_entry_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(_) =
    bookmarks.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )

  let assert Ok([bookmarks.Bookmark(archives:, ..)]) =
    bookmarks.list_bookmarks(bc)

  archives |> should.equal(["http://web.archive.org/1"])
}

pub fn set_title_updates_bookmark_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = bookmarks.set_title(bc, bookmark, Some("Example"))

  bookmark.title |> should.equal(Some("Example"))
}

pub fn set_title_is_read_out_by_list_bookmarks_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(_) = bookmarks.set_title(bc, bookmark, Some("Example"))

  let assert Ok([bookmarks.Bookmark(title:, ..)]) = bookmarks.list_bookmarks(bc)

  title |> should.equal(Some("Example"))
}

pub fn set_title_overwrites_an_existing_title_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = bookmarks.set_title(bc, bookmark, Some("First"))
  let assert Ok(bookmark) = bookmarks.set_title(bc, bookmark, Some("Second"))

  bookmark.title |> should.equal(Some("Second"))
}

pub fn set_title_to_none_clears_the_title_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = bookmarks.set_title(bc, bookmark, Some("Example"))
  let assert Ok(bookmark) = bookmarks.set_title(bc, bookmark, None)

  bookmark.title |> should.equal(None)

  let assert Ok([bookmarks.Bookmark(title:, ..)]) = bookmarks.list_bookmarks(bc)
  title |> should.equal(None)
}
