CREATE TABLE "schema_migrations" (version varchar(128) primary key);
CREATE TABLE bookmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT NOT NULL,
    title TEXT,
    created_at DATETIME NOT NULL
  );
CREATE TABLE archives (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookmark_id INTEGER NOT NULL,
    url TEXT NOT NULL,
    host TEXT NOT NULL,
    created_at DATETIME NOT NULL,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id)
  );
CREATE TABLE tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tag TEXT NOT NULL,
    bookmark_id INTEGER NOT NULL,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id),
    UNIQUE (tag, bookmark_id)
  );
CREATE TABLE jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookmark_id INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (
      status IN ('pending', 'running', 'completed', 'errored')
    ),
    created_at DATETIME NOT NULL,
    started_at DATETIME,
    completed_at DATETIME,
    detail TEXT,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id),
    CHECK (
      (
        status = 'pending'
        AND completed_at IS NULL
      )
      OR (
        status = 'running'
        AND completed_at IS NULL
      )
      OR (
        status = 'completed'
        AND completed_at IS NOT NULL
      )
      OR (
        status = 'errored'
        AND completed_at IS NOT NULL
        AND detail IS NOT NULL
      )
    )
  );
CREATE UNIQUE INDEX one_pending_job_per_bookmark ON jobs (bookmark_id)
WHERE
  status = 'pending';
CREATE TABLE changelog (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookmark_id INTEGER NOT NULL,
    updated_at DATETIME NOT NULL,
    change_kind TEXT NOT NULL,
    change_detail TEXT,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id)
  );
-- Dbmate schema migrations
INSERT INTO "schema_migrations" (version) VALUES
  ('20260721185126');
