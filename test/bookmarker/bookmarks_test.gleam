import bookmarker/bookmarks.{type BookmarkConn}
import bookmarker/db
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
      canonical_url: None,
      content: None,
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
    canonical_url: None,
    content: None,
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

pub fn deleting_added_tags_removes_those_tags_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) =
    bookmarks.add_tags(bc, bookmark, ["aaa", "bbb", "ccc"])

  let assert Ok(bookmark) = bookmarks.remove_tags(bc, bookmark, ["aaa", "bbb"])

  bookmark.tags |> should.equal(["ccc"])

  let assert Ok([bookmark]) = bookmarks.list_bookmarks(bc)
  bookmark.tags |> should.equal(["ccc"])
}

pub fn deleting_all_tags_clears_tag_list_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) =
    bookmarks.add_tags(bc, bookmark, ["aaa", "bbb", "ccc"])

  let assert Ok(bookmark) = bookmarks.clear_tags(bc, bookmark)

  bookmark.tags |> should.equal([])

  let assert Ok([bookmark]) = bookmarks.list_bookmarks(bc)
  bookmark.tags |> should.equal([])
}

pub fn deleting_an_empty_list_of_tags_does_nothing_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) =
    bookmarks.add_tags(bc, bookmark, ["aaa", "bbb", "ccc"])

  let assert Ok(bookmark) = bookmarks.remove_tags(bc, bookmark, [])

  bookmark.tags |> should.equal(["aaa", "bbb", "ccc"])

  let assert Ok([bookmark]) = bookmarks.list_bookmarks(bc)
  bookmark.tags |> should.equal(["aaa", "bbb", "ccc"])
}

pub fn deleting_a_nonexistent_tag_does_nothing_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) =
    bookmarks.add_tags(bc, bookmark, ["aaa", "bbb", "ccc"])

  let assert Ok(bookmark) = bookmarks.remove_tags(bc, bookmark, ["four"])

  bookmark.tags |> should.equal(["aaa", "bbb", "ccc"])

  let assert Ok([bookmark]) = bookmarks.list_bookmarks(bc)
  bookmark.tags |> should.equal(["aaa", "bbb", "ccc"])
}

pub fn add_archive_to_bookmark_updates_bookmark_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let now = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, now)

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    bookmarks.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )

  bookmark.archives
  |> should.equal([
    bookmarks.Archive(
      host: "web.archive.org",
      url: "http://web.archive.org/1",
      created_at: now,
    ),
  ])
}

pub fn add_archive_replaces_the_archive_for_the_same_host_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

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

  // The single entry proves the upsert replaced rather than appended, and the
  // refreshed `created_at` proves it replaced rather than ignoring the
  // conflict — an ignored insert would have left the original timestamp behind.
  bookmark.archives
  |> should.equal([
    bookmarks.Archive(
      host: "web.archive.org",
      url: "http://web.archive.org/2",
      created_at: updated_at,
    ),
  ])
}

pub fn add_archive_keeps_archives_from_different_hosts_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let now = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, now)

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
  |> should.equal([
    bookmarks.Archive(
      host: "archive.ph",
      url: "http://archive.ph/1",
      created_at: now,
    ),
    bookmarks.Archive(
      host: "web.archive.org",
      url: "http://web.archive.org/1",
      created_at: now,
    ),
  ])
}

pub fn bookmark_archives_are_fetched_fresh_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let now = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, now)

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

  let wayback =
    bookmarks.Archive(
      host: "web.archive.org",
      url: "http://web.archive.org/1",
      created_at: now,
    )
  let archive_ph =
    bookmarks.Archive(
      host: "archive.ph",
      url: "http://archive.ph/1",
      created_at: now,
    )

  bookmark1.archives |> should.equal([wayback])
  bookmark2.archives |> should.equal([archive_ph, wayback])
}

pub fn list_bookmarks_with_archived_entry_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let now = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, now)

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

  archives
  |> should.equal([
    bookmarks.Archive(
      host: "web.archive.org",
      url: "http://web.archive.org/1",
      created_at: now,
    ),
  ])
}

pub fn delete_archive_test() {
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
    bookmarks.remove_archive(bc, bookmark, "web.archive.org")

  bookmark.archives |> should.equal([])
}

pub fn delete_nonexistent_archive_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) =
    bookmarks.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )

  let assert Ok(bookmark) = bookmarks.remove_archive(bc, bookmark, "none.org")

  bookmark.archives
  |> should.equal([
    bookmarks.Archive(
      host: "web.archive.org",
      url: "http://web.archive.org/1",
      created_at: mock_clock.now(clock)(),
    ),
  ])
}

pub fn clear_archives_test() {
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
    bookmarks.add_archive(
      bc,
      bookmark,
      "web.archive.com",
      "http://web.archive.com/1",
    )

  let assert Ok(bookmark) = bookmarks.clear_archives(bc, bookmark)

  bookmark.archives |> should.equal([])
}

pub fn clear_archives_only_affects_one_bookmark_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let assert Ok(b1) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(_) =
    bookmarks.add_archive(bc, b1, "web.archive.org", "http://web.archive.org/1")

  let assert Ok(b2) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(b2) =
    bookmarks.add_archive(bc, b2, "web.archive.org", "http://web.archive.org/1")
  let assert Ok(b2) =
    bookmarks.add_archive(bc, b2, "web.archive.com", "http://web.archive.com/1")

  let assert Ok(_) = bookmarks.clear_archives(bc, b2)

  let assert Ok([b1, b2]) = bookmarks.list_bookmarks(bc)

  b1.archives
  |> should.equal([
    bookmarks.Archive(
      host: "web.archive.org",
      url: "http://web.archive.org/1",
      created_at: mock_clock.now(clock)(),
    ),
  ])

  b2.archives
  |> should.equal([])
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

pub fn set_content_updates_bookmark_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    bookmarks.set_content(bc, bookmark, Some("Page body"))

  bookmark.content |> should.equal(Some("Page body"))
}

pub fn set_content_is_read_out_by_list_bookmarks_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(_) = bookmarks.set_content(bc, bookmark, Some("Page body"))

  let assert Ok([bookmarks.Bookmark(content:, ..)]) =
    bookmarks.list_bookmarks(bc)

  content |> should.equal(Some("Page body"))
}

pub fn set_content_overwrites_existing_content_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = bookmarks.set_content(bc, bookmark, Some("First"))
  let assert Ok(bookmark) = bookmarks.set_content(bc, bookmark, Some("Second"))

  bookmark.content |> should.equal(Some("Second"))
}

pub fn set_content_to_none_clears_the_content_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    bookmarks.set_content(bc, bookmark, Some("Page body"))
  let assert Ok(bookmark) = bookmarks.set_content(bc, bookmark, None)

  bookmark.content |> should.equal(None)

  let assert Ok([bookmarks.Bookmark(content:, ..)]) =
    bookmarks.list_bookmarks(bc)
  content |> should.equal(None)
}

pub fn set_canonical_url_updates_bookmark_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    bookmarks.set_canonical_url(bc, bookmark, Some("http://example.com/page"))

  bookmark.canonical_url |> should.equal(Some("http://example.com/page"))
}

pub fn set_canonical_url_is_read_out_by_list_bookmarks_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(_) =
    bookmarks.set_canonical_url(bc, bookmark, Some("http://example.com/page"))

  let assert Ok([bookmarks.Bookmark(canonical_url:, ..)]) =
    bookmarks.list_bookmarks(bc)

  canonical_url |> should.equal(Some("http://example.com/page"))
}

pub fn set_canonical_url_overwrites_an_existing_canonical_url_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    bookmarks.set_canonical_url(bc, bookmark, Some("http://example.com/first"))
  let assert Ok(bookmark) =
    bookmarks.set_canonical_url(bc, bookmark, Some("http://example.com/second"))

  bookmark.canonical_url |> should.equal(Some("http://example.com/second"))
}

pub fn set_canonical_url_to_none_clears_the_canonical_url_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    bookmarks.set_canonical_url(bc, bookmark, Some("http://example.com/page"))
  let assert Ok(bookmark) = bookmarks.set_canonical_url(bc, bookmark, None)

  bookmark.canonical_url |> should.equal(None)

  let assert Ok([bookmarks.Bookmark(canonical_url:, ..)]) =
    bookmarks.list_bookmarks(bc)
  canonical_url |> should.equal(None)
}

/// A bookmark with every fillable part filled in, so that a clear has
/// something to remove in each of them.
fn bookmark_with_no_holes(bc: BookmarkConn, url: String) -> bookmarks.Bookmark {
  let assert Ok(bm) = bookmarks.add_bookmark(bc, url)
  let assert Ok(bm) = bookmarks.set_title(bc, bm, Some("Example"))
  let assert Ok(bm) = bookmarks.set_content(bc, bm, Some("Page body"))
  let assert Ok(bm) = bookmarks.set_canonical_url(bc, bm, Some(url <> "/page"))
  let assert Ok(bm) = bookmarks.add_tags(bc, bm, ["aaa", "bbb"])
  let assert Ok(bm) =
    bookmarks.add_archive(bc, bm, "web.archive.org", "http://web.archive.org/1")
  bm
}

pub fn clear_bookmark_opens_a_hole_in_every_field_test() {
  use bc, _ <- with_test_conn()

  let bm = bookmark_with_no_holes(bc, "http://example.com")

  let assert Ok(cleared) = bookmarks.clear_bookmark(bc, bm)

  cleared.title |> should.equal(None)
  cleared.content |> should.equal(None)
  cleared.canonical_url |> should.equal(None)
  cleared.tags |> should.equal([])
  cleared.archives |> should.equal([])
}

pub fn clear_bookmark_is_read_out_by_list_bookmarks_test() {
  use bc, _ <- with_test_conn()

  let bm = bookmark_with_no_holes(bc, "http://example.com")

  let assert Ok(cleared) = bookmarks.clear_bookmark(bc, bm)

  // The returned bookmark must be what was stored, not just an emptied copy.
  let assert Ok([fetched]) = bookmarks.list_bookmarks(bc)
  fetched |> should.equal(cleared)
}

/// Clearing opens holes for a later job to fill, so it must leave the parts of
/// a bookmark that identify it — the URL it was saved with, and when.
pub fn clear_bookmark_keeps_the_url_and_creation_time_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let created_at = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, created_at)

  let bm = bookmark_with_no_holes(bc, "http://example.com")

  mock_clock.set(clock, ts("2026-02-01T00:00:00Z"))
  let assert Ok(cleared) = bookmarks.clear_bookmark(bc, bm)

  cleared.id |> should.equal(bm.id)
  cleared.url |> should.equal("http://example.com")
  cleared.created_at |> should.equal(created_at)
}

pub fn clear_bookmark_with_nothing_filled_in_does_nothing_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bm) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(cleared) = bookmarks.clear_bookmark(bc, bm)

  cleared |> should.equal(bm)
}

pub fn clear_bookmark_only_affects_one_bookmark_test() {
  use bc, _ <- with_test_conn()

  let kept = bookmark_with_no_holes(bc, "http://kept.example.com")
  let target = bookmark_with_no_holes(bc, "http://target.example.com")

  let assert Ok(cleared) = bookmarks.clear_bookmark(bc, target)

  let assert Ok([fetched_kept, fetched_target]) = bookmarks.list_bookmarks(bc)

  fetched_kept |> should.equal(kept)
  fetched_target |> should.equal(cleared)
}

/// The canonical URL is advisory only (ADR-0002) — recording one must never
/// rewrite the URL the bookmark was saved with.
pub fn set_canonical_url_leaves_the_url_untouched_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    bookmarks.set_canonical_url(bc, bookmark, Some("http://example.com/page"))

  bookmark.url |> should.equal("http://example.com")

  let assert Ok([bookmarks.Bookmark(url:, ..)]) = bookmarks.list_bookmarks(bc)
  url |> should.equal("http://example.com")
}
