import bookmarker/db
import cake
import cake/delete as d
import cake/dialect/sqlite_dialect
import cake/insert as i
import cake/param
import cake/select as s
import cake/update as u
import cake/where as w
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import sqlight.{type Connection, type Error, type Value}

pub opaque type StoreConn {
  StoreConn(db: Connection, now: fn() -> Timestamp)
}

pub opaque type BookmarkId {
  BookmarkId(Int)
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

pub opaque type JobId {
  JobId(Int)
}

pub type Job {
  Job(id: JobId, bookmark: BookmarkId, created_at: Timestamp, status: JobStatus)
}

pub type JobStatus {
  Pending
  Running(started_at: Timestamp)
  Completed(started_at: Timestamp, completed_at: Timestamp)
  Failed(started_at: Timestamp, completed_at: Timestamp, error: String)
}

pub fn new(db: Connection, now: fn() -> Timestamp) -> StoreConn {
  StoreConn(db, now)
}

pub fn list_bookmarks(conn: StoreConn) -> Result(List(Bookmark), Error) {
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
    query(prepared, on: conn, expecting: {
      use id <- decode.field(0, decode.int |> decode.map(BookmarkId))
      use url <- decode.field(1, decode.string)
      use title <- decode.field(2, decode.string |> decode.optional)
      use created_at <- decode.field(3, timestamp_decoder())
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
    use tags <- result.try(list_tags(conn, bm.id))
    use archives <- result.try(list_archives(conn, bm.id))
    Ok(Bookmark(..bm, tags:, archives:))
  })
}

pub fn add_bookmark(conn: StoreConn, url: String) -> Result(Bookmark, Error) {
  let prepared =
    [i.row([i.string(url), i.int(conn.now() |> timestamp_to_millis)])]
    |> i.from_values(table_name: "bookmarks", columns: ["url", "created_at"])
    |> i.returning(["id", "url", "created_at"])
    |> i.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  use entries <- result.try(
    query(prepared, on: conn, expecting: {
      use id <- decode.field(0, decode.int |> decode.map(BookmarkId))
      use url <- decode.field(1, decode.string)
      use created_at <- decode.field(2, timestamp_decoder())

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
  conn: StoreConn,
  bm: Bookmark,
) -> Result(Bookmark, Error) {
  use <- db.transaction(conn.db)

  use bm <- result.try(clear_tags(conn, bm))
  use bm <- result.try(clear_archives(conn, bm))

  use _ <- result.try(
    update_bookmark(conn, bm.id, [
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
  conn: StoreConn,
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

      query(prepared, on: conn, expecting: decode.success(Nil))
      |> result.replace(Nil)
    }
  })

  use tags <- result.try(list_tags(conn, bm.id))
  Ok(Bookmark(..bm, tags:))
}

pub fn remove_tags(
  conn: StoreConn,
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

  use _ <- result.try(query(prepared, on: conn, expecting: decode.success(Nil)))

  use tags <- result.try(list_tags(conn, bm.id))
  Ok(Bookmark(..bm, tags:))
}

pub fn clear_tags(conn: StoreConn, bm: Bookmark) -> Result(Bookmark, Error) {
  let BookmarkId(id) = bm.id
  let prepared =
    d.new()
    |> d.table("tags")
    |> d.where(w.col("bookmark_id") |> w.eq(w.int(id)))
    |> d.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  use _ <- result.try(query(prepared, on: conn, expecting: decode.success(Nil)))

  Ok(Bookmark(..bm, tags: []))
}

pub fn add_archive(
  conn: StoreConn,
  bm: Bookmark,
  host: String,
  url: String,
) -> Result(Bookmark, Error) {
  let BookmarkId(id) = bm.id
  let created_at = conn.now() |> timestamp_to_millis

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

  use _ <- result.try(query(prepared, on: conn, expecting: decode.success(Nil)))

  use archives <- result.try(list_archives(conn, bm.id))
  Ok(Bookmark(..bm, archives:))
}

pub fn remove_archive(
  conn: StoreConn,
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

  use _ <- result.try(query(prepared, on: conn, expecting: decode.success(Nil)))

  use archives <- result.try(list_archives(conn, bm.id))
  Ok(Bookmark(..bm, archives:))
}

pub fn clear_archives(
  conn: StoreConn,
  bm: Bookmark,
) -> Result(Bookmark, Error) {
  let BookmarkId(id) = bm.id
  let prepared =
    d.new()
    |> d.table("archives")
    |> d.where(w.col("bookmark_id") |> w.eq(w.int(id)))
    |> d.to_query
    |> sqlite_dialect.write_query_to_prepared_statement

  use _ <- result.try(query(prepared, on: conn, expecting: decode.success(Nil)))

  Ok(Bookmark(..bm, archives: []))
}

pub fn set_title(
  conn: StoreConn,
  bm: Bookmark,
  title: Option(String),
) -> Result(Bookmark, Error) {
  use _ <- result.try(
    update_bookmark(conn, bm.id, [set_nullable_string("title", title)]),
  )

  Ok(Bookmark(..bm, title:))
}

pub fn set_content(
  conn: StoreConn,
  bm: Bookmark,
  content: Option(String),
) -> Result(Bookmark, Error) {
  use _ <- result.try(
    update_bookmark(conn, bm.id, [set_nullable_string("content", content)]),
  )

  Ok(Bookmark(..bm, content:))
}

pub fn set_canonical_url(
  conn: StoreConn,
  bm: Bookmark,
  canonical_url: Option(String),
) -> Result(Bookmark, Error) {
  use _ <- result.try(
    update_bookmark(conn, bm.id, [
      set_nullable_string("canonical_url", canonical_url),
    ]),
  )

  Ok(Bookmark(..bm, canonical_url:))
}

pub fn list_pending_jobs(conn: StoreConn) -> Result(List(Job), Error) {
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
  let with = cake.get_params(prepared) |> list.map(param_to_value)

  sqlight.query(sql, on: conn.db, with:, expecting: {
    use id <- decode.field(0, decode.int)
    use bookmark <- decode.field(1, decode.int |> decode.map(BookmarkId))
    use created_at <- decode.field(2, timestamp_decoder())

    decode.success(Job(id: JobId(id), bookmark:, created_at:, status: Pending))
  })
}

pub fn list_jobs_for_bookmark(
  conn: StoreConn,
  bm: Bookmark,
) -> Result(List(Job), Error) {
  let BookmarkId(id) = bm.id
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
      s.col("jobs.error"),
    ])
    |> s.where(w.col("jobs.bookmark_id") |> w.eq(w.int(id)))
    |> s.to_query
    |> sqlite_dialect.read_query_to_prepared_statement

  let sql = cake.get_sql(prepared)
  let with = cake.get_params(prepared) |> list.map(param_to_value)

  sqlight.query(sql, on: conn.db, with:, expecting: {
    use id <- decode.field(0, decode.int)
    use bookmark <- decode.field(0, decode.int |> decode.map(BookmarkId))
    use status <- decode.field(2, decode.string)
    use created_at <- decode.field(3, timestamp_decoder())
    use started_at <- decode.field(4, timestamp_decoder() |> decode.optional)
    use completed_at <- decode.field(5, timestamp_decoder() |> decode.optional)
    use error <- decode.field(6, decode.string |> decode.optional)

    case status, started_at, completed_at, error {
      "pending", _, _, _ ->
        Job(JobId(id), bookmark:, created_at:, status: Pending)
        |> decode.success
      "running", Some(started_at), _, _ ->
        Job(JobId(id), bookmark:, created_at:, status: Running(started_at:))
        |> decode.success
      "completed", Some(started_at), Some(completed_at), _ ->
        Job(
          JobId(id),
          bookmark:,
          created_at:,
          status: Completed(started_at:, completed_at:),
        )
        |> decode.success
      "failed", Some(started_at), Some(completed_at), Some(error) ->
        Job(
          JobId(id),
          bookmark:,
          created_at:,
          status: Failed(started_at:, completed_at:, error:),
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

pub fn schedule_job(conn: StoreConn, bm: Bookmark) -> Result(Job, Error) {
  // Create the pending job, or return the one already scheduled — in a single
  // statement. The trick is the no-op `DO UPDATE` (rather than `DO NOTHING`):
  // SQLite's `RETURNING` only emits rows that were inserted or updated, so
  // touching the conflicting row is what surfaces the existing job. On conflict
  // `created_at` is left untouched, so we get back the original schedule time.
  //
  // Hand-written rather than built with cake: cake emits the conflict-target
  // `WHERE` on the `DO UPDATE` instead of the target, so it can't address the
  // partial `one_pending_job_per_bookmark` index this relies on.
  let created_at = conn.now()
  let BookmarkId(id) = bm.id
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
      on: conn.db,
      with: [
        sqlight.int(id),
        sqlight.int(created_at |> timestamp_to_millis),
      ],
      expecting: {
        use id <- decode.field(0, decode.int)
        use created_at <- decode.field(1, timestamp_decoder())

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

pub fn start_job(conn: StoreConn, job: Job) -> Result(Option(Job), Error) {
  // Move the job to `running`, but only if it's still `pending`. The
  // `status = 'pending'` guard makes this atomic: if another worker already
  // started (or finished) the job, zero rows match and we never clobber an
  // in-flight job's timestamps. We reconstruct the returned job from `job`
  // rather than reading columns back, so `RETURNING id` exists only to sense
  // whether a row was updated — no rows means someone else got there first.
  let JobId(id) = job.id
  let started_at = conn.now()

  let prepared =
    u.new()
    |> u.table("jobs")
    |> u.sets([
      u.set_string("status", "running"),
      u.set_int("started_at", started_at |> timestamp_to_millis),
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
  let with = cake.get_params(prepared) |> list.map(param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: conn.db, with:, expecting: {
      use started_at <- decode.field(0, timestamp_decoder())
      decode.success(started_at)
    }),
  )

  case entries {
    [] -> Ok(option.None)
    [started_at, ..] ->
      Ok(option.Some(Job(..job, status: Running(started_at:))))
  }
}

pub fn complete_job(conn: StoreConn, job: Job) -> Result(Option(Job), Error) {
  // Move the job to `completed`, but only if it's currently `running` — the
  // status guard keeps this atomic against a competing worker, just like
  // `start_job`. Unlike `start_job` we don't own `started_at`, so we read it
  // back: `RETURNING` both surfaces the stored value we need for `Completed`
  // and senses whether a row matched. No rows means someone else moved it on.
  let JobId(id) = job.id
  let completed_at = conn.now()

  let prepared =
    u.new()
    |> u.table("jobs")
    |> u.sets([
      u.set_string("status", "completed"),
      u.set_int("completed_at", completed_at |> timestamp_to_millis),
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
  let with = cake.get_params(prepared) |> list.map(param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: conn.db, with:, expecting: {
      use started_at <- decode.field(0, timestamp_decoder())
      use completed_at <- decode.field(1, timestamp_decoder())
      decode.success(#(started_at, completed_at))
    }),
  )

  case entries {
    [] -> Ok(option.None)
    [#(started_at, completed_at), ..] ->
      Ok(option.Some(Job(..job, status: Completed(started_at:, completed_at:))))
  }
}

pub fn fail_job(
  conn: StoreConn,
  job: Job,
  error: String,
) -> Result(Option(Job), Error) {
  let JobId(id) = job.id
  let completed_at = conn.now()

  let prepared =
    u.new()
    |> u.table("jobs")
    |> u.sets([
      u.set_string("status", "failed"),
      u.set_int("completed_at", completed_at |> timestamp_to_millis),
      u.set_string("error", error),
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
  let with = cake.get_params(prepared) |> list.map(param_to_value)

  use entries <- result.try(
    sqlight.query(sql, on: conn.db, with:, expecting: {
      use started_at <- decode.field(0, timestamp_decoder())
      use completed_at <- decode.field(1, timestamp_decoder())
      decode.success(#(started_at, completed_at))
    }),
  )

  case entries {
    [] -> Ok(option.None)
    [#(started_at, completed_at), ..] ->
      Ok(option.Some(
        Job(..job, status: Failed(started_at:, completed_at:, error:)),
      ))
  }
}

/// Apply `sets` to the `bookmarks` row for `bookmark`.
///
/// The caller already knows the values it asked for, so this reads nothing
/// back — but it does insist the row was there. An update against a bookmark
/// that has since been deleted matches nothing, and without the `RETURNING`
/// row to count we would hand back a `Bookmark` describing a row that no
/// longer exists.
fn update_bookmark(
  conn: StoreConn,
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

  use rows <- result.try(query(
    prepared,
    on: conn,
    expecting: decode.success(Nil),
  ))

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
  conn: StoreConn,
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

  query(prepared, on: conn, expecting: {
    use host <- decode.field(0, decode.string)
    use url <- decode.field(1, decode.string)
    use created_at <- decode.field(2, timestamp_decoder())
    decode.success(Archive(host:, url:, created_at:))
  })
}

fn list_tags(
  conn: StoreConn,
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

  query(prepared, on: conn, expecting: {
    use tag <- decode.field(0, decode.string)
    decode.success(tag)
  })
}

/// Run a cake-prepared statement against `bc`'s connection.
///
/// The only place cake's params are translated into sqlight values.
fn query(
  prepared: cake.PreparedStatement,
  on conn: StoreConn,
  expecting decoder: decode.Decoder(a),
) -> Result(List(a), Error) {
  sqlight.query(
    cake.get_sql(prepared),
    on: conn.db,
    with: cake.get_params(prepared) |> list.map(param_to_value),
    expecting: decoder,
  )
}

fn timestamp_to_millis(ts: Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(ts)
  seconds * 1000 + nanoseconds / 1_000_000
}

fn millis_to_timestamp(total: Int) -> Timestamp {
  timestamp.from_unix_seconds_and_nanoseconds(
    seconds: total / 1000,
    nanoseconds: { total % 1000 } * 1_000_000,
  )
}

fn timestamp_decoder() -> Decoder(Timestamp) {
  decode.int |> decode.map(millis_to_timestamp)
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
