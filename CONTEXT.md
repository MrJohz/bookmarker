# Bookmarker

Bookmarker stores URLs you want to keep, and fills in everything else about them — title, readable content, tags, archive snapshots — in the background.

## Bookmarks

**Bookmark**:
A URL someone saved, together with everything derived from it.
_Avoid_: link, entry, item

**Hole**:
A part of a bookmark that has not been filled in yet. Holes are what a job looks for and what it fills.
_Avoid_: gap, missing field, partial data

**Clear**:
Deliberately removing a value from a bookmark, opening a hole for a later job to fill. How someone asks for something to be scraped again.
_Avoid_: reset, blank, invalidate

**Tag**:
A short label on a bookmark. Tags a person wrote and tags the scraper generated are the same thing, and are not told apart.
_Avoid_: label, keyword, category

**Archive**:
A snapshot of a bookmark's page held by an archiving service, identified by that service's host. At most one per service per bookmark.
_Avoid_: snapshot, backup, mirror

**Canonical URL**:
The address a page declares as its own preferred one. Purely informational — a suggestion someone may adopt, never applied automatically.
_Avoid_: normalised URL, real URL, resolved URL

**Changelog Entry**:
An append-only record that something about a bookmark changed, when, and whether a person or a job did it. An audit trail, not an undo history.
_Avoid_: revision, version, history entry, event

## Scraping

**Scraper**:
The background process that runs jobs, one at a time.
_Avoid_: worker, crawler, fetcher

**Job**:
A unit of scraper work covering one bookmark. A job works out what to do when it runs, from that bookmark's holes.
_Avoid_: work item, queue entry

**Task**:
One kind of work a job can do — Title, Content, Canonical URL, Tags, or Archive. Each task fills exactly one kind of hole.
_Avoid_: step, stage, action

**Retry**:
Scheduling a job for a bookmark. It only enqueues; it does not decide what the job will do, and it clears nothing.
_Avoid_: re-scrape, refresh, rerun

**Pending**:
The state of a job that has been scheduled and not yet claimed. At most one job per bookmark is pending at a time.
_Avoid_: queued, waiting

**Running**:
The state of a job the scraper has claimed and is working on.
_Avoid_: started, in progress, active

**Completed**:
The terminal state of a job where every hole it found is now filled — including a job that found none.
_Avoid_: done, finished, succeeded

**Failed**:
The terminal state of a job where at least one task did not succeed. Whatever the other tasks accomplished is kept.
_Avoid_: errored, broken
