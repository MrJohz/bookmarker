import bookmarker/utils
import cake
import cake/dialect/sqlite_dialect
import cake/select as s
import cake/update as u
import cake/where as w
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import sqlight.{type Connection, type Error}

import bookmarker/bookmarks

pub opaque type JobsConn {
  JobsConn(db: Connection, now: fn() -> Timestamp)
}

pub fn new(db: Connection, now: fn() -> Timestamp) -> JobsConn {
  JobsConn(db, now)
}

pub opaque type JobId {
  JobId(Int)
}

pub type Job {
  Job(
    id: JobId,
    bookmark: bookmarks.BookmarkId,
    created_at: Timestamp,
    status: JobStatus,
  )
}

pub type JobStatus {
  Pending
  Started(started_at: Timestamp)
  Completed(
    started_at: Timestamp,
    completed_at: Timestamp,
    detail: Option(String),
  )
  Errored(started_at: Timestamp, completed_at: Timestamp, error: String)
}

pub fn list_pending(jc: JobsConn) -> Result(List(Job), Error) {
  let prepared =
    s.new()
    |> s.from_table("jobs")
    |> s.selects([
      s.col("jobs.id"),
      s.col("jobs.bookmark_id"),
      s.col("jobs.created_at"),
    ])
    |> s.where(w.col("jobs.status") |> w.eq(w.string("pending")))
    |> s.to_query
    |> sqlite_dialect.read_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(utils.param_to_value)

  sqlight.query(sql, on: jc.db, with:, expecting: pending_job_decoder())
}

pub fn list_for_bookmark(
  jc: JobsConn,
  bm: bookmarks.Bookmark,
) -> Result(List(Job), Error) {
  let prepared =
    s.new()
    |> s.from_table("jobs")
    |> s.selects([
      s.col("jobs.id"),
      s.col("jobs.bookmark_id"),
      s.col("jobs.status"),
      s.col("jobs.created_at"),
      s.col("jobs.started_at"),
      s.col("jobs.completed_at"),
      s.col("jobs.detail"),
    ])
    |> s.where(
      w.col("jobs.bookmark_id") |> w.eq(w.int(bookmarks.id_to_int(bm.id))),
    )
    |> s.to_query
    |> sqlite_dialect.read_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(utils.param_to_value)

  sqlight.query(sql, on: jc.db, with:, expecting: {
    use id <- decode.field(0, decode.int)
    use bookmark <- decode.field(1, bookmarks.id_decoder())
    use status <- decode.field(2, decode.string)
    use created_at <- decode.field(3, utils.timestamp_decoder())
    use started_at <- decode.field(
      4,
      utils.timestamp_decoder() |> decode.optional,
    )
    use completed_at <- decode.field(
      5,
      utils.timestamp_decoder() |> decode.optional,
    )
    use detail <- decode.field(6, decode.string |> decode.optional)

    case status, started_at, completed_at, detail {
      "pending", _, _, _ ->
        Job(JobId(id), bookmark:, created_at:, status: Pending)
        |> decode.success
      "running", Some(started_at), _, _ ->
        Job(JobId(id), bookmark:, created_at:, status: Started(started_at:))
        |> decode.success
      "completed", Some(started_at), Some(completed_at), detail ->
        Job(
          JobId(id),
          bookmark:,
          created_at:,
          status: Completed(started_at:, completed_at:, detail:),
        )
        |> decode.success
      "failed", Some(started_at), Some(completed_at), Some(error) ->
        Job(
          JobId(id),
          bookmark:,
          created_at:,
          status: Errored(started_at:, completed_at:, error:),
        )
        |> decode.success
      _, _, _, _ ->
        decode.failure(
          Job(JobId(id), bookmark:, created_at:, status: Pending),
          "Job",
        )
    }
  })
}

pub fn schedule_job(
  jc: JobsConn,
  bm: bookmarks.Bookmark,
) -> Result(Job, Error) {
  // Create the pending job, or return the one already scheduled — in a single
  // statement. The trick is the no-op `DO UPDATE` (rather than `DO NOTHING`):
  // SQLite's `RETURNING` only emits rows that were inserted or updated, so
  // touching the conflicting row is what surfaces the existing job. On conflict
  // `created_at` is left untouched, so we get back the original schedule time.
  //
  // Hand-written rather than built with cake: cake emits the conflict-target
  // `WHERE` on the `DO UPDATE` instead of the target, so it can't address the
  // partial `one_pending_job_per_bookmark` index this relies on.
  let created_at = jc.now()
  let sql =
    "
    INSERT INTO jobs (bookmark_id, status, created_at)
    VALUES (?, 'pending', ?)
    ON CONFLICT (bookmark_id) WHERE status = 'pending'
    DO UPDATE SET bookmark_id = excluded.bookmark_id
    RETURNING id, created_at
    "

  use entries <- result.try(
    sqlight.query(
      sql,
      on: jc.db,
      with: [
        sqlight.int(bookmarks.id_to_int(bm.id)),
        sqlight.int(created_at |> utils.timestamp_to_millis),
      ],
      expecting: {
        use id <- decode.field(0, decode.int)
        use created_at <- decode.field(1, utils.timestamp_decoder())

        decode.success(Job(
          id: JobId(id),
          bookmark: bm.id,
          created_at:,
          status: Pending,
        ))
      },
    ),
  )

  let assert [job] = entries

  Ok(job)
}

pub fn start_job(jc: JobsConn, job: Job) -> Result(Option(Job), Error) {
  // Move the job to `running`, but only if it's still `pending`. The
  // `status = 'pending'` guard makes this atomic: if another worker already
  // started (or finished) the job, zero rows match and we never clobber an
  // in-flight job's timestamps. We reconstruct the returned job from `job`
  // rather than reading columns back, so `RETURNING id` exists only to sense
  // whether a row was updated — no rows means someone else got there first.
  let JobId(id) = job.id
  let started_at = jc.now()

  let prepared =
    u.new()
    |> u.table("jobs")
    |> u.sets([
      u.set_string("status", "running"),
      u.set_int("started_at", started_at |> utils.timestamp_to_millis),
    ])
    |> u.where(
      w.and([
        w.col("jobs.id") |> w.eq(w.int(id)),
        w.col("jobs.status") |> w.eq(w.string("pending")),
      ]),
    )
    |> u.returning(["started_at"])
    |> u.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(utils.param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: jc.db, with:, expecting: {
      use started_at <- decode.field(0, utils.timestamp_decoder())
      decode.success(started_at)
    }),
  )

  case entries {
    [] -> Ok(option.None)
    [started_at, ..] ->
      Ok(option.Some(Job(..job, status: Started(started_at:))))
  }
}

pub fn complete_job(
  jc: JobsConn,
  job: Job,
  detail: Option(String),
) -> Result(Option(Job), Error) {
  // Move the job to `completed`, but only if it's currently `running` — the
  // status guard keeps this atomic against a competing worker, just like
  // `start_job`. Unlike `start_job` we don't own `started_at`, so we read it
  // back: `RETURNING` both surfaces the stored value we need for `Completed`
  // and senses whether a row matched. No rows means someone else moved it on.
  let JobId(id) = job.id
  let completed_at = jc.now()

  let prepared =
    u.new()
    |> u.table("jobs")
    |> u.sets([
      u.set_string("status", "completed"),
      u.set_int("completed_at", completed_at |> utils.timestamp_to_millis),
      case detail {
        option.Some(detail) -> u.set_string("detail", detail)
        option.None -> u.set_null("detail")
      },
    ])
    |> u.where(
      w.and([
        w.col("jobs.id") |> w.eq(w.int(id)),
        w.col("jobs.status") |> w.eq(w.string("running")),
      ]),
    )
    |> u.returning(["started_at", "completed_at"])
    |> u.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(utils.param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: jc.db, with:, expecting: {
      use started_at <- decode.field(0, utils.timestamp_decoder())
      use completed_at <- decode.field(1, utils.timestamp_decoder())
      decode.success(#(started_at, completed_at))
    }),
  )

  case entries {
    [] -> Ok(option.None)
    [#(started_at, completed_at), ..] ->
      Ok(option.Some(
        Job(..job, status: Completed(started_at:, completed_at:, detail:)),
      ))
  }
}

pub fn fail_job(
  jc: JobsConn,
  job: Job,
  error: String,
) -> Result(Option(Job), Error) {
  let JobId(id) = job.id
  let completed_at = jc.now()

  let prepared =
    u.new()
    |> u.table("jobs")
    |> u.sets([
      u.set_string("status", "errored"),
      u.set_int("completed_at", completed_at |> utils.timestamp_to_millis),
      u.set_string("detail", error),
    ])
    |> u.where(
      w.and([
        w.col("jobs.id") |> w.eq(w.int(id)),
        w.col("jobs.status") |> w.eq(w.string("running")),
      ]),
    )
    |> u.returning(["started_at", "completed_at"])
    |> u.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(utils.param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: jc.db, with:, expecting: {
      use started_at <- decode.field(0, utils.timestamp_decoder())
      use completed_at <- decode.field(1, utils.timestamp_decoder())
      decode.success(#(started_at, completed_at))
    }),
  )

  case entries {
    [] -> Ok(option.None)
    [#(started_at, completed_at), ..] ->
      Ok(option.Some(
        Job(..job, status: Errored(started_at:, completed_at:, error:)),
      ))
  }
}

fn pending_job_decoder() -> decode.Decoder(Job) {
  use id <- decode.field(0, decode.int)
  use bookmark <- decode.field(1, bookmarks.id_decoder())
  use created_at <- decode.field(2, utils.timestamp_decoder())

  decode.success(Job(id: JobId(id), bookmark:, created_at:, status: Pending))
}
