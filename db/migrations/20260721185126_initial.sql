-- migrate:up
CREATE TABLE
  bookmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

CREATE TABLE
  archives (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookmark_id INTEGER NOT NULL,
    url TEXT NOT NULL,
    host TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id)
  );

CREATE TABLE
  tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tag TEXT NOT NULL,
    bookmark_id INTEGER NOT NULL,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id),
    UNIQUE (tag, bookmark_id)
  );

CREATE TABLE
  changelog (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookmark_id INTEGER NOT NULL,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    change_kind TEXT NOT NULL,
    change_detail TEXT,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id)
  );

-- migrate:down
DROP TABLE IF EXISTS changelog;

DROP TABLE IF EXISTS tags;

DROP TABLE IF EXISTS archives;

DROP TABLE IF EXISTS bookmarks;