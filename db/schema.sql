CREATE TABLE "schema_migrations" (version varchar(128) primary key);
CREATE TABLE bookmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
CREATE TABLE archives (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookmark_id INTEGER NOT NULL,
    url TEXT NOT NULL,
    host TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id)
  );
CREATE TABLE tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tag TEXT NOT NULL
  );
CREATE TABLE tag_bookmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tag_id INTEGER NOT NULL,
    bookmark_id INTEGER NOT NULL,
    FOREIGN KEY (tag_id) REFERENCES tags (id),
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id)
  );
CREATE TABLE changelog (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookmark_id INTEGER NOT NULL,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    change_kind TEXT NOT NULL,
    change_detail TEXT,
    FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id)
  );
-- Dbmate schema migrations
INSERT INTO "schema_migrations" (version) VALUES
  ('20260721185126');
