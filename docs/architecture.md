# Architectural Design

* Two processes under one supervisor:
  * http server (mist)
  * scraper

The HTTP server handles requests from outside — adding bookmarks, listing them, editing and clearing fields, scheduling jobs.  The scraper runs jobs in the background, one at a time.

See [CONTEXT.md](../CONTEXT.md) for the vocabulary used throughout.

## Database Structure

* `bookmarks` -> main table: url, optional title, optional content, optional canonical url, `deleted_at` for soft deletion
* `archives` -> archive URLs (e.g. wayback machine) for each bookmark, one per archiving service, `(bookmark_id, host)` is unique
* `tags` -> tags for each bookmark, combination of `(bm, tag)` is unique
* `jobs` -> scraper jobs, can be in state `pending`, `running`, `completed`, `failed`, at most one job per bookmark can be in `pending`
* `changelog` -> changes made to each bookmark, append-only, updated whenever a bookmark is created or modified.  `job_id` is null when a person made the change, and names the job otherwise

URLs are stored exactly as submitted, and are not unique — duplicate bookmarks are always allowed ([ADR-0002](./adr/0002-duplicate-urls-allowed.md)).  Content lives inline on `bookmarks` despite its size ([ADR-0004](./adr/0004-content-stored-inline.md)).

Changelog entries carry a `change_kind` and a human-readable `change_detail`.  The kind is not constrained by the schema, so adding one needs no migration, and is parsed into a type with an `Unknown` variant so retired kinds still read back.  The detail is prose for a person to read — it is not designed to reconstruct previous values.

## Jobs

A job covers one bookmark, not one task.  Jobs are created when a bookmark is added, or when someone asks for a retry; nothing scans the database looking for work.

When the scraper claims a job, it looks at the bookmark and works out what to do from the holes it finds ([ADR-0001](./adr/0001-jobs-derive-work-from-holes.md)):

| Task | Hole | How |
|---|---|---|
| **Title** | no title | simple http fetch + html parse |
| **Content** | no content | markdown-y version of content suitable for searching and LLM'ing |
| **Canonical URL** | no canonical url | the page's own `<link rel="canonical">` if it declares one, otherwise the URL the fetch landed on after redirects |
| **Tags** | no tags at all | pass content to a (v. small) LLM to generate a list of tags relevant to that page |
| **Archive** | no archive for a configured archiving service | post request to the service, store the generated URL |

Title, Content and Canonical URL all come out of a single fetch of the page.  Tags takes the stored content as its only input, and is skipped when there is none.

Deriving the work this way makes retrying resumable for nothing: whatever a previous job managed to fill is no longer a hole, so a re-run does strictly what is left.  It also means a job for a bookmark with no holes does nothing.  Refreshing a value that is already present is therefore done by clearing it first — clearing and scheduling are separate actions, which is what makes targeted re-scrapes ("those tags aren't good enough") possible without a second kind of job.

A job that fills every hole it found is `completed`.  If any task fails the whole job is `failed` and the reason is recorded in `jobs.error`; whatever the other tasks accomplished is kept, and the corresponding holes are closed.

## The scraper loop

The scraper waits on a subject with a timeout.  The HTTP server notifies it when something is enqueued, so an idle scraper starts almost immediately; the timeout re-checks the queue regardless, so a restart or a lost message costs at most one interval.

Jobs run strictly one at a time.  This is deliberate: every task talks to a rate-limited third party — the page itself, the archiving service, the LLM — and running sequentially keeps us polite without any rate-limiting machinery.

On startup, any job still marked `running` belongs to a scraper that died mid-job, since there is only ever one scraper and nothing else could own it.  Those jobs are marked `failed` and are deliberately *not* re-queued ([ADR-0003](./adr/0003-interrupted-jobs-are-not-retried.md)).

Bookmarks are soft-deleted.  When the scraper claims a job whose bookmark has since been deleted, it skips the work and completes the job.
