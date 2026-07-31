import bookmarker/db
import bookmarker/store.{type StoreConn}
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

fn with_test_conn(f: fn(StoreConn, Deps) -> a) -> a {
  use conn <- db.with_connection(":memory:")
  let assert Ok(schema) = simplifile.read("db/schema.sql")
  let assert Ok(Nil) = sqlight.exec(schema, on: conn)

  let clock = mock_clock.new(timestamp.from_unix_seconds(0))
  f(store.new(conn, mock_clock.now(clock)), Deps(conn:, clock:))
}

pub fn list_bookmarks_empty_test() {
  use bc, _ <- with_test_conn()

  store.list_bookmarks(bc) |> should.equal(Ok([]))
}

pub fn list_bookmarks_with_unarchived_entry_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let now = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, now)

  let assert Ok(_) = store.add_bookmark(bc, "http://example.com")

  let assert Ok([
    store.Bookmark(
      id: _,
      created_at:,
      url:,
      canonical_url: None,
      content: None,
      title: None,
      tags: [],
      archives: [],
    ),
  ]) = store.list_bookmarks(bc)

  created_at |> should.equal(now)
  url |> should.equal("http://example.com")
}

pub fn create_bookmark_returns_bookmark_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let now = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, now)

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert store.Bookmark(
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

  let assert Ok([fetched_bookmark]) = store.list_bookmarks(bc)

  bookmark |> should.equal(fetched_bookmark)
}

pub fn add_tags_to_bookmark_updates_bookmark_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = store.add_tags(bc, bookmark, ["tag1", "tag2"])

  bookmark.tags |> should.equal(["tag1", "tag2"])
}

pub fn add_tags_to_bookmark_is_idempotent_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(_) = store.add_tags(bc, bookmark, ["tag1", "tag2"])
  let assert Ok(bookmark) = store.add_tags(bc, bookmark, ["tag1", "tag2"])

  bookmark.tags |> should.equal(["tag1", "tag2"])
}

pub fn add_tags_to_bookmark_merges_with_existing_tags_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = store.add_tags(bc, bookmark, ["tag1", "tag2"])
  let assert Ok(bookmark) = store.add_tags(bc, bookmark, ["tag2", "tag3"])

  bookmark.tags |> should.equal(["tag1", "tag2", "tag3"])
}

pub fn add_no_tags_produces_an_unchanged_bookmark_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark2) = store.add_tags(bc, bookmark, [])

  bookmark |> should.equal(bookmark2)
  bookmark.tags |> should.equal([])
}

pub fn bookmark_tags_are_fetched_fresh_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(original) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark1) = store.add_tags(bc, original, ["tag1", "tag2"])
  let assert Ok(bookmark2) = store.add_tags(bc, original, ["tag2", "tag3"])

  bookmark1.tags |> should.equal(["tag1", "tag2"])
  bookmark2.tags |> should.equal(["tag1", "tag2", "tag3"])
}

pub fn deleting_added_tags_removes_those_tags_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) = store.add_tags(bc, bookmark, ["aaa", "bbb", "ccc"])

  let assert Ok(bookmark) = store.remove_tags(bc, bookmark, ["aaa", "bbb"])

  bookmark.tags |> should.equal(["ccc"])

  let assert Ok([bookmark]) = store.list_bookmarks(bc)
  bookmark.tags |> should.equal(["ccc"])
}

pub fn deleting_all_tags_clears_tag_list_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) = store.add_tags(bc, bookmark, ["aaa", "bbb", "ccc"])

  let assert Ok(bookmark) = store.clear_tags(bc, bookmark)

  bookmark.tags |> should.equal([])

  let assert Ok([bookmark]) = store.list_bookmarks(bc)
  bookmark.tags |> should.equal([])
}

pub fn deleting_an_empty_list_of_tags_does_nothing_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) = store.add_tags(bc, bookmark, ["aaa", "bbb", "ccc"])

  let assert Ok(bookmark) = store.remove_tags(bc, bookmark, [])

  bookmark.tags |> should.equal(["aaa", "bbb", "ccc"])

  let assert Ok([bookmark]) = store.list_bookmarks(bc)
  bookmark.tags |> should.equal(["aaa", "bbb", "ccc"])
}

pub fn deleting_a_nonexistent_tag_does_nothing_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) = store.add_tags(bc, bookmark, ["aaa", "bbb", "ccc"])

  let assert Ok(bookmark) = store.remove_tags(bc, bookmark, ["four"])

  bookmark.tags |> should.equal(["aaa", "bbb", "ccc"])

  let assert Ok([bookmark]) = store.list_bookmarks(bc)
  bookmark.tags |> should.equal(["aaa", "bbb", "ccc"])
}

pub fn add_archive_to_bookmark_updates_bookmark_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let now = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, now)

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    store.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )

  bookmark.archives
  |> should.equal([
    store.Archive(
      host: "web.archive.org",
      url: "http://web.archive.org/1",
      created_at: now,
    ),
  ])
}

pub fn add_archive_replaces_the_archive_for_the_same_host_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10Z"))

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) =
    store.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )

  let updated_at = ts("2026-02-01T00:00:00Z")
  mock_clock.set(clock, updated_at)
  let assert Ok(bookmark) =
    store.add_archive(
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
    store.Archive(
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

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    store.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )
  let assert Ok(bookmark) =
    store.add_archive(bc, bookmark, "archive.ph", "http://archive.ph/1")

  // Ordered by host, so `archive.ph` sorts before `web.archive.org`.
  bookmark.archives
  |> should.equal([
    store.Archive(
      host: "archive.ph",
      url: "http://archive.ph/1",
      created_at: now,
    ),
    store.Archive(
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

  let assert Ok(original) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark1) =
    store.add_archive(
      bc,
      original,
      "web.archive.org",
      "http://web.archive.org/1",
    )
  let assert Ok(bookmark2) =
    store.add_archive(bc, original, "archive.ph", "http://archive.ph/1")

  let wayback =
    store.Archive(
      host: "web.archive.org",
      url: "http://web.archive.org/1",
      created_at: now,
    )
  let archive_ph =
    store.Archive(
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

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(_) =
    store.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )

  let assert Ok([store.Bookmark(archives:, ..)]) = store.list_bookmarks(bc)

  archives
  |> should.equal([
    store.Archive(
      host: "web.archive.org",
      url: "http://web.archive.org/1",
      created_at: now,
    ),
  ])
}

pub fn delete_archive_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) =
    store.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )

  let assert Ok(bookmark) =
    store.remove_archive(bc, bookmark, "web.archive.org")

  bookmark.archives |> should.equal([])
}

pub fn delete_nonexistent_archive_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) =
    store.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )

  let assert Ok(bookmark) = store.remove_archive(bc, bookmark, "none.org")

  bookmark.archives
  |> should.equal([
    store.Archive(
      host: "web.archive.org",
      url: "http://web.archive.org/1",
      created_at: mock_clock.now(clock)(),
    ),
  ])
}

pub fn clear_archives_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(bookmark) =
    store.add_archive(
      bc,
      bookmark,
      "web.archive.org",
      "http://web.archive.org/1",
    )
  let assert Ok(bookmark) =
    store.add_archive(
      bc,
      bookmark,
      "web.archive.com",
      "http://web.archive.com/1",
    )

  let assert Ok(bookmark) = store.clear_archives(bc, bookmark)

  bookmark.archives |> should.equal([])
}

pub fn clear_archives_only_affects_one_bookmark_test() {
  use bc, Deps(clock:, ..) <- with_test_conn()

  let assert Ok(b1) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(_) =
    store.add_archive(bc, b1, "web.archive.org", "http://web.archive.org/1")

  let assert Ok(b2) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(b2) =
    store.add_archive(bc, b2, "web.archive.org", "http://web.archive.org/1")
  let assert Ok(b2) =
    store.add_archive(bc, b2, "web.archive.com", "http://web.archive.com/1")

  let assert Ok(_) = store.clear_archives(bc, b2)

  let assert Ok([b1, b2]) = store.list_bookmarks(bc)

  b1.archives
  |> should.equal([
    store.Archive(
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

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = store.set_title(bc, bookmark, Some("Example"))

  bookmark.title |> should.equal(Some("Example"))
}

pub fn set_title_is_read_out_by_list_bookmarks_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(_) = store.set_title(bc, bookmark, Some("Example"))

  let assert Ok([store.Bookmark(title:, ..)]) = store.list_bookmarks(bc)

  title |> should.equal(Some("Example"))
}

pub fn set_title_overwrites_an_existing_title_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = store.set_title(bc, bookmark, Some("First"))
  let assert Ok(bookmark) = store.set_title(bc, bookmark, Some("Second"))

  bookmark.title |> should.equal(Some("Second"))
}

pub fn set_title_to_none_clears_the_title_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = store.set_title(bc, bookmark, Some("Example"))
  let assert Ok(bookmark) = store.set_title(bc, bookmark, None)

  bookmark.title |> should.equal(None)

  let assert Ok([store.Bookmark(title:, ..)]) = store.list_bookmarks(bc)
  title |> should.equal(None)
}

pub fn set_content_updates_bookmark_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = store.set_content(bc, bookmark, Some("Page body"))

  bookmark.content |> should.equal(Some("Page body"))
}

pub fn set_content_is_read_out_by_list_bookmarks_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(_) = store.set_content(bc, bookmark, Some("Page body"))

  let assert Ok([store.Bookmark(content:, ..)]) = store.list_bookmarks(bc)

  content |> should.equal(Some("Page body"))
}

pub fn set_content_overwrites_existing_content_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = store.set_content(bc, bookmark, Some("First"))
  let assert Ok(bookmark) = store.set_content(bc, bookmark, Some("Second"))

  bookmark.content |> should.equal(Some("Second"))
}

pub fn set_content_to_none_clears_the_content_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) = store.set_content(bc, bookmark, Some("Page body"))
  let assert Ok(bookmark) = store.set_content(bc, bookmark, None)

  bookmark.content |> should.equal(None)

  let assert Ok([store.Bookmark(content:, ..)]) = store.list_bookmarks(bc)
  content |> should.equal(None)
}

pub fn set_canonical_url_updates_bookmark_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    store.set_canonical_url(bc, bookmark, Some("http://example.com/page"))

  bookmark.canonical_url |> should.equal(Some("http://example.com/page"))
}

pub fn set_canonical_url_is_read_out_by_list_bookmarks_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")
  let assert Ok(_) =
    store.set_canonical_url(bc, bookmark, Some("http://example.com/page"))

  let assert Ok([store.Bookmark(canonical_url:, ..)]) = store.list_bookmarks(bc)

  canonical_url |> should.equal(Some("http://example.com/page"))
}

pub fn set_canonical_url_overwrites_an_existing_canonical_url_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    store.set_canonical_url(bc, bookmark, Some("http://example.com/first"))
  let assert Ok(bookmark) =
    store.set_canonical_url(bc, bookmark, Some("http://example.com/second"))

  bookmark.canonical_url |> should.equal(Some("http://example.com/second"))
}

pub fn set_canonical_url_to_none_clears_the_canonical_url_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    store.set_canonical_url(bc, bookmark, Some("http://example.com/page"))
  let assert Ok(bookmark) = store.set_canonical_url(bc, bookmark, None)

  bookmark.canonical_url |> should.equal(None)

  let assert Ok([store.Bookmark(canonical_url:, ..)]) = store.list_bookmarks(bc)
  canonical_url |> should.equal(None)
}

/// A bookmark with every fillable part filled in, so that a clear has
/// something to remove in each of them.
fn bookmark_with_no_holes(bc: StoreConn, url: String) -> store.Bookmark {
  let assert Ok(bm) = store.add_bookmark(bc, url)
  let assert Ok(bm) = store.set_title(bc, bm, Some("Example"))
  let assert Ok(bm) = store.set_content(bc, bm, Some("Page body"))
  let assert Ok(bm) = store.set_canonical_url(bc, bm, Some(url <> "/page"))
  let assert Ok(bm) = store.add_tags(bc, bm, ["aaa", "bbb"])
  let assert Ok(bm) =
    store.add_archive(bc, bm, "web.archive.org", "http://web.archive.org/1")
  bm
}

pub fn clear_bookmark_opens_a_hole_in_every_field_test() {
  use bc, _ <- with_test_conn()

  let bm = bookmark_with_no_holes(bc, "http://example.com")

  let assert Ok(cleared) = store.clear_bookmark(bc, bm)

  cleared.title |> should.equal(None)
  cleared.content |> should.equal(None)
  cleared.canonical_url |> should.equal(None)
  cleared.tags |> should.equal([])
  cleared.archives |> should.equal([])
}

pub fn clear_bookmark_is_read_out_by_list_bookmarks_test() {
  use bc, _ <- with_test_conn()

  let bm = bookmark_with_no_holes(bc, "http://example.com")

  let assert Ok(cleared) = store.clear_bookmark(bc, bm)

  // The returned bookmark must be what was stored, not just an emptied copy.
  let assert Ok([fetched]) = store.list_bookmarks(bc)
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
  let assert Ok(cleared) = store.clear_bookmark(bc, bm)

  cleared.id |> should.equal(bm.id)
  cleared.url |> should.equal("http://example.com")
  cleared.created_at |> should.equal(created_at)
}

pub fn clear_bookmark_with_nothing_filled_in_does_nothing_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bm) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(cleared) = store.clear_bookmark(bc, bm)

  cleared |> should.equal(bm)
}

pub fn clear_bookmark_only_affects_one_bookmark_test() {
  use bc, _ <- with_test_conn()

  let kept = bookmark_with_no_holes(bc, "http://kept.example.com")
  let target = bookmark_with_no_holes(bc, "http://target.example.com")

  let assert Ok(cleared) = store.clear_bookmark(bc, target)

  let assert Ok([fetched_kept, fetched_target]) = store.list_bookmarks(bc)

  fetched_kept |> should.equal(kept)
  fetched_target |> should.equal(cleared)
}

/// The canonical URL is advisory only (ADR-0002) — recording one must never
/// rewrite the URL the bookmark was saved with.
pub fn set_canonical_url_leaves_the_url_untouched_test() {
  use bc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(bc, "http://example.com")

  let assert Ok(bookmark) =
    store.set_canonical_url(bc, bookmark, Some("http://example.com/page"))

  bookmark.url |> should.equal("http://example.com")

  let assert Ok([store.Bookmark(url:, ..)]) = store.list_bookmarks(bc)
  url |> should.equal("http://example.com")
}

pub fn list_pending_empty_test() {
  use sc, _ <- with_test_conn()

  store.list_pending_jobs(sc) |> should.equal(Ok([]))
}

pub fn schedule_job_returns_job_test() {
  use sc, Deps(clock:, ..) <- with_test_conn()

  let now = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, now)

  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job) = store.schedule_job(sc, bookmark)

  job.bookmark |> should.equal(bookmark.id)
  job.created_at |> should.equal(now)
  job.status |> should.equal(store.Pending)
}

pub fn schedule_job_appears_in_list_pending_test() {
  use sc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job) = store.schedule_job(sc, bookmark)

  store.list_pending_jobs(sc) |> should.equal(Ok([job]))
}

pub fn start_job_marks_running_test() {
  use sc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10Z"))
  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job) = store.schedule_job(sc, bookmark)

  let started_at = ts("2026-01-05T00:06:00Z")
  mock_clock.set(clock, started_at)

  let assert Ok(option.Some(started)) = store.start_job(sc, job)

  started.id |> should.equal(job.id)
  started.bookmark |> should.equal(bookmark.id)
  started.created_at |> should.equal(job.created_at)
  started.status |> should.equal(store.Running(started_at:))

  // Started jobs are no longer pending.
  store.list_pending_jobs(sc) |> should.equal(Ok([]))
}

pub fn start_job_returns_none_when_not_pending_test() {
  use sc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job) = store.schedule_job(sc, bookmark)

  // First start wins; a second start finds no pending row and returns None.
  let assert Ok(option.Some(_)) = store.start_job(sc, job)
  store.start_job(sc, job) |> should.equal(Ok(option.None))
}

pub fn complete_job_marks_completed_test() {
  use sc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10Z"))
  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job) = store.schedule_job(sc, bookmark)

  let started_at = ts("2026-01-05T00:06:00Z")
  mock_clock.set(clock, started_at)
  let assert Ok(option.Some(started)) = store.start_job(sc, job)

  let completed_at = ts("2026-01-05T00:07:00Z")
  mock_clock.set(clock, completed_at)
  let assert Ok(option.Some(completed)) = store.complete_job(sc, started)

  completed.id |> should.equal(job.id)
  completed.bookmark |> should.equal(bookmark.id)
  completed.created_at |> should.equal(job.created_at)
  // `started_at` is read back from the row, not carried from the in-memory job.
  completed.status
  |> should.equal(store.Completed(started_at:, completed_at:))
}

pub fn complete_job_returns_none_when_not_running_test() {
  use sc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job) = store.schedule_job(sc, bookmark)

  // A pending job that was never started can't be completed.
  store.complete_job(sc, job) |> should.equal(Ok(option.None))
}

pub fn fail_job_marks_failed_test() {
  use sc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10Z"))
  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job) = store.schedule_job(sc, bookmark)

  let started_at = ts("2026-01-05T00:06:00Z")
  mock_clock.set(clock, started_at)
  let assert Ok(option.Some(started)) = store.start_job(sc, job)

  let completed_at = ts("2026-01-05T00:07:00Z")
  mock_clock.set(clock, completed_at)
  let assert Ok(option.Some(failed)) = store.fail_job(sc, started, "boom")

  failed.id |> should.equal(job.id)
  failed.status
  |> should.equal(store.Failed(started_at:, completed_at:, error: "boom"))
}

pub fn fail_job_returns_none_when_not_running_test() {
  use sc, _ <- with_test_conn()

  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job) = store.schedule_job(sc, bookmark)

  // Completing wins; a subsequent fail finds no running row and returns None.
  let assert Ok(option.Some(started)) = store.start_job(sc, job)
  let assert Ok(option.Some(_)) = store.complete_job(sc, started)
  store.fail_job(sc, started, "boom") |> should.equal(Ok(option.None))
}

pub fn schedule_job_is_idempotent_test() {
  use sc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10Z"))

  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(first) = store.schedule_job(sc, bookmark)

  // Advancing the clock proves the second call returns the *existing* job
  // unchanged, rather than rescheduling it with a fresh timestamp.
  mock_clock.set(clock, ts("2026-02-01T00:00:00Z"))
  let assert Ok(second) = store.schedule_job(sc, bookmark)

  first |> should.equal(second)
  store.list_pending_jobs(sc) |> should.equal(Ok([first]))
}

pub fn created_at_is_stable_across_reads_test() {
  use sc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10.123456789Z"))

  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job1) = store.schedule_job(sc, bookmark)
  let assert Ok([job2]) = store.list_jobs_for_bookmark(sc, bookmark)

  job1.created_at |> should.equal(job2.created_at)
  job1 |> should.equal(job2)
}

pub fn started_at_is_stable_across_reads_test() {
  use sc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:06:00.123456789Z"))
  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job) = store.schedule_job(sc, bookmark)

  let assert Ok(option.Some(job1)) = store.start_job(sc, job)
  let assert store.Running(started_at: job1_started_at) = job1.status
  let assert Ok([job2]) = store.list_jobs_for_bookmark(sc, bookmark)
  let assert store.Running(started_at: job2_started_at) = job2.status

  job1_started_at |> should.equal(job2_started_at)
  job1 |> should.equal(job2)
}

pub fn completed_at_is_stable_across_reads_test() {
  use sc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:06:00.123456789Z"))
  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job) = store.schedule_job(sc, bookmark)
  let assert Ok(option.Some(_)) = store.start_job(sc, job)

  let assert Ok(option.Some(job1)) = store.complete_job(sc, job)
  let assert store.Completed(completed_at: job1_completed_at, ..) = job1.status
  let assert Ok([job2]) = store.list_jobs_for_bookmark(sc, bookmark)
  let assert store.Completed(completed_at: job2_completed_at, ..) = job2.status

  job1_completed_at |> should.equal(job2_completed_at)
  job1 |> should.equal(job2)
}

pub fn completed_at_is_stable_across_reads_test_on_error_test() {
  use sc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:06:00.123456789Z"))
  let assert Ok(bookmark) = store.add_bookmark(sc, "http://example.com")
  let assert Ok(job) = store.schedule_job(sc, bookmark)
  let assert Ok(option.Some(_)) = store.start_job(sc, job)

  let assert Ok(option.Some(job1)) = store.fail_job(sc, job, "err")
  let assert store.Failed(completed_at: job1_completed_at, ..) = job1.status
  let assert Ok([job2]) = store.list_jobs_for_bookmark(sc, bookmark)
  let assert store.Failed(completed_at: job2_completed_at, ..) = job2.status

  job1_completed_at |> should.equal(job2_completed_at)
  job1 |> should.equal(job2)
}
