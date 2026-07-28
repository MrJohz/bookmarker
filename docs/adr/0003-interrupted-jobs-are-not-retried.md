# Interrupted jobs are failed, not retried

There is only ever one scraper process, so any job still marked `running` at startup belongs to a scraper that died mid-job — nothing else could own it, so no lease or heartbeat is needed to prove it.  Startup marks those jobs `failed` with an "interrupted" reason and does **not** re-queue them.  Recovering the work means asking for a retry, the same as after any other failure.

## Consequences

The tempting alternative — re-queue automatically, so interrupted work resumes without anyone noticing — turns a bookmark that reliably crashes the scraper into an unbounded restart loop: claim, crash, restart, re-queue, claim.  Under the supervisor that exhausts the restart intensity and terminates the whole application, taking the HTTP server down with it.  One bad URL must not be able to stop the server accepting new bookmarks.

Nothing is lost by not resuming, because the work is derived from holes ([ADR-0001](./0001-jobs-derive-work-from-holes.md)): a later job does whatever the interrupted one did not.

Repeated "interrupted" entries are a visible signal that something is crashing, which an automatic re-queue would have hidden.

Marking `failed` rather than resetting to `pending` also avoids colliding with the partial unique index that allows only one pending job per bookmark.
