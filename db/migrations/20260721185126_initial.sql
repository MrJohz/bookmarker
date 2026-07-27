-- migrate:up
CREATE TABLE
  bookmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT NOT NULL,
    title TEXT,
    created_at INTEGER NOT NULL
  ) strict;

CREATE TABLE
  archives (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookmark_id INTEGER NOT NULL,
    url TEXT NOT NULL,
    host TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id)
  ) strict;

CREATE TABLE
  tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tag TEXT NOT NULL,
    bookmark_id INTEGER NOT NULL,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id),
    UNIQUE (tag, bookmark_id)
  ) strict;

CREATE TABLE
  jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookmark_id INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (
      status IN ('pending', 'running', 'completed', 'errored')
    ),
    created_at INTEGER NOT NULL,
    started_at INTEGER,
    completed_at INTEGER,
    detail TEXT,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id),
    CHECK (
      (
        status = 'pending'
        AND completed_at IS NULL
      )
      OR (
        status = 'running'
        AND STARTED_AT IS NOT NULL
        AND completed_at IS NULL
      )
      OR (
        status = 'completed'
        AND STARTED_AT IS NOT NULL
        AND completed_at IS NOT NULL
      )
      OR (
        status = 'errored'
        AND STARTED_AT IS NOT NULL
        AND completed_at IS NOT NULL
        AND detail IS NOT NULL
      )
    )
  ) strict;

CREATE UNIQUE INDEX one_pending_job_per_bookmark ON jobs (bookmark_id)
WHERE
  status = 'pending';

CREATE TABLE
  changelog (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookmark_id INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    change_kind TEXT NOT NULL,
    change_detail TEXT,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id)
  ) strict;

-- migrate:down
DROP TABLE IF EXISTS jobs;

DROP TABLE IF EXISTS changelog;

DROP TABLE IF EXISTS tags;

DROP TABLE IF EXISTS archives;

DROP TABLE IF EXISTS bookmarks;