import bookmarker/bookmarks.{type BookmarkConn}
import bookmarker/db
import bookmarker/jobs.{type JobsConn}
import gleam/option
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

fn with_test_conn(f: fn(JobsConn, BookmarkConn, Deps) -> a) -> a {
  use conn <- db.with_connection(":memory:")
  let assert Ok(schema) = simplifile.read("db/schema.sql")
  let assert Ok(Nil) = sqlight.exec(schema, on: conn)

  let clock = mock_clock.new(timestamp.from_unix_seconds(0))
  let now = mock_clock.now(clock)
  f(jobs.new(conn, now), bookmarks.new(conn, now), Deps(conn:, clock:))
}

pub fn list_pending_empty_test() {
  use jc, _bc, _ <- with_test_conn()

  jobs.list_pending(jc) |> should.equal(Ok([]))
}

pub fn schedule_job_returns_job_test() {
  use jc, bc, Deps(clock:, ..) <- with_test_conn()

  let now = ts("2026-01-05T00:05:10Z")
  mock_clock.set(clock, now)

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job) = jobs.schedule_job(jc, bookmark)

  job.bookmark |> should.equal(bookmark.id)
  job.created_at |> should.equal(now)
  job.status |> should.equal(jobs.Pending)
}

pub fn schedule_job_appears_in_list_pending_test() {
  use jc, bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job) = jobs.schedule_job(jc, bookmark)

  jobs.list_pending(jc) |> should.equal(Ok([job]))
}

pub fn start_job_marks_running_test() {
  use jc, bc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10Z"))
  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job) = jobs.schedule_job(jc, bookmark)

  let started_at = ts("2026-01-05T00:06:00Z")
  mock_clock.set(clock, started_at)

  let assert Ok(option.Some(started)) = jobs.start_job(jc, job)

  started.id |> should.equal(job.id)
  started.bookmark |> should.equal(bookmark.id)
  started.created_at |> should.equal(job.created_at)
  started.status |> should.equal(jobs.Started(started_at:))

  // Started jobs are no longer pending.
  jobs.list_pending(jc) |> should.equal(Ok([]))
}

pub fn start_job_returns_none_when_not_pending_test() {
  use jc, bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job) = jobs.schedule_job(jc, bookmark)

  // First start wins; a second start finds no pending row and returns None.
  let assert Ok(option.Some(_)) = jobs.start_job(jc, job)
  jobs.start_job(jc, job) |> should.equal(Ok(option.None))
}

pub fn complete_job_marks_completed_test() {
  use jc, bc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10Z"))
  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job) = jobs.schedule_job(jc, bookmark)

  let started_at = ts("2026-01-05T00:06:00Z")
  mock_clock.set(clock, started_at)
  let assert Ok(option.Some(started)) = jobs.start_job(jc, job)

  let completed_at = ts("2026-01-05T00:07:00Z")
  mock_clock.set(clock, completed_at)
  let assert Ok(option.Some(completed)) =
    jobs.complete_job(jc, started, option.Some("all good"))

  completed.id |> should.equal(job.id)
  completed.bookmark |> should.equal(bookmark.id)
  completed.created_at |> should.equal(job.created_at)
  // `started_at` is read back from the row, not carried from the in-memory job.
  completed.status
  |> should.equal(jobs.Completed(
    started_at:,
    completed_at:,
    detail: option.Some("all good"),
  ))
}

pub fn complete_job_returns_none_when_not_running_test() {
  use jc, bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job) = jobs.schedule_job(jc, bookmark)

  // A pending job that was never started can't be completed.
  jobs.complete_job(jc, job, option.None) |> should.equal(Ok(option.None))
}

pub fn fail_job_marks_errored_test() {
  use jc, bc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10Z"))
  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job) = jobs.schedule_job(jc, bookmark)

  let started_at = ts("2026-01-05T00:06:00Z")
  mock_clock.set(clock, started_at)
  let assert Ok(option.Some(started)) = jobs.start_job(jc, job)

  let completed_at = ts("2026-01-05T00:07:00Z")
  mock_clock.set(clock, completed_at)
  let assert Ok(option.Some(failed)) = jobs.fail_job(jc, started, "boom")

  failed.id |> should.equal(job.id)
  failed.status
  |> should.equal(jobs.Errored(started_at:, completed_at:, error: "boom"))
}

pub fn fail_job_returns_none_when_not_running_test() {
  use jc, bc, _ <- with_test_conn()

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job) = jobs.schedule_job(jc, bookmark)

  // Completing wins; a subsequent fail finds no running row and returns None.
  let assert Ok(option.Some(started)) = jobs.start_job(jc, job)
  let assert Ok(option.Some(_)) = jobs.complete_job(jc, started, option.None)
  jobs.fail_job(jc, started, "boom") |> should.equal(Ok(option.None))
}

pub fn schedule_job_is_idempotent_test() {
  use jc, bc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10Z"))

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(first) = jobs.schedule_job(jc, bookmark)

  // Advancing the clock proves the second call returns the *existing* job
  // unchanged, rather than rescheduling it with a fresh timestamp.
  mock_clock.set(clock, ts("2026-02-01T00:00:00Z"))
  let assert Ok(second) = jobs.schedule_job(jc, bookmark)

  first |> should.equal(second)
  jobs.list_pending(jc) |> should.equal(Ok([first]))
}

pub fn created_at_is_stable_across_reads_test() {
  use jc, bc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:05:10.123456789Z"))

  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job1) = jobs.schedule_job(jc, bookmark)
  let assert Ok([job2]) = jobs.list_for_bookmark(jc, bookmark)

  job1.created_at |> should.equal(job2.created_at)
  job1 |> should.equal(job2)
}

pub fn started_at_is_stable_across_reads_test() {
  use jc, bc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:06:00.123456789Z"))
  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job) = jobs.schedule_job(jc, bookmark)

  let assert Ok(option.Some(job1)) = jobs.start_job(jc, job)
  let assert jobs.Started(started_at: job1_started_at) = job1.status
  let assert Ok([job2]) = jobs.list_for_bookmark(jc, bookmark)
  let assert jobs.Started(started_at: job2_started_at) = job2.status

  job1_started_at |> should.equal(job2_started_at)
  job1 |> should.equal(job2)
}

pub fn completed_at_is_stable_across_reads_test() {
  use jc, bc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:06:00.123456789Z"))
  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job) = jobs.schedule_job(jc, bookmark)
  let assert Ok(option.Some(_)) = jobs.start_job(jc, job)

  let assert Ok(option.Some(job1)) = jobs.complete_job(jc, job, option.None)
  let assert jobs.Completed(completed_at: job1_completed_at, ..) = job1.status
  let assert Ok([job2]) = jobs.list_for_bookmark(jc, bookmark)
  let assert jobs.Completed(completed_at: job2_completed_at, ..) = job2.status

  job1_completed_at |> should.equal(job2_completed_at)
  job1 |> should.equal(job2)
}

pub fn completed_at_is_stable_across_reads_test_on_error_test() {
  use jc, bc, Deps(clock:, ..) <- with_test_conn()

  mock_clock.set(clock, ts("2026-01-05T00:06:00.123456789Z"))
  let assert Ok(bookmark) = bookmarks.add_bookmark(bc, "http://example.com")
  let assert Ok(job) = jobs.schedule_job(jc, bookmark)
  let assert Ok(option.Some(_)) = jobs.start_job(jc, job)

  let assert Ok(option.Some(job1)) = jobs.fail_job(jc, job, "err")
  let assert jobs.Errored(completed_at: job1_completed_at, ..) = job1.status
  let assert Ok([job2]) = jobs.list_for_bookmark(jc, bookmark)
  let assert jobs.Errored(completed_at: job2_completed_at, ..) = job2.status

  job1_completed_at |> should.equal(job2_completed_at)
  job1 |> should.equal(job2)
}
