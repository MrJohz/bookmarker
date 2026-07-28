# Content is stored inline on bookmarks

Scraped page content is a `content` column on `bookmarks` rather than a table of its own, even though it is by far the largest field and the only one that is not a short string.  This is deliberate, and was made with the cost measured rather than assumed.

## Consequences

Measured at 10,000 bookmarks with ~10KB of content each, 4KiB pages, layouts otherwise identical:

| layout | `bookmarks` leaf pages | warm scan of `url` + `title` |
|---|---|---|
| `content` inline | 5,000 (≈20MB) | ~28ms |
| separate `contents` table | 498 (≈2MB) | ~4.5ms |

Roughly 10x the pages and 6x the time.  SQLite overflows the bulk of a large value to overflow pages, but keeps a minimum portion of the record inline, so rows drop from around 20 per leaf page to 2 — a scan that never reads `content` still walks past it.

We take the 10x because the absolute cost is invisible at the scale this runs at, and because splitting later is cheap and exact.  Creating the table, copying, `ALTER TABLE … DROP COLUMN` and `VACUUM` took ~3 seconds at that size, and produced a `bookmarks` table of exactly 498 leaf pages — the same as one built split from the start.

Full-text search is the reason content exists, and will need its own table whichever layout is used, so this does not constrain it.

The thing to watch is `SELECT *`.  Queries that do not need content must name their columns, as `list_bookmarks` already does.
