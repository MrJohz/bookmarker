# Jobs derive their work from holes in the bookmark

A job covers a whole bookmark rather than a single scraping task, and works out what to do when it runs by looking at what that bookmark is missing.  No job records which tasks it intends to perform.  The alternative was a job per `(bookmark, task)`, which makes the queue self-describing but needs dependency handling between tasks, a scheduling rule for each one, and reconciliation when some of them succeed.

## Consequences

Retrying is resumable for nothing.  Anything a previous attempt managed to fill is no longer a hole, so a re-run does strictly the remaining work — no per-task progress has to be tracked, and an interrupted job needs no special handling.

"Have we done this yet?" must be observable on the bookmark itself.  Where a task can legitimately produce nothing, that is indistinguishable from never having run — most visibly for tags, where a page the LLM finds nothing for stays a hole forever.  We accept this, because jobs run only when explicitly scheduled, so the repeated work is bounded by how often it is asked for.

A job for a bookmark with no holes does nothing at all.  Refreshing a value that is already present therefore requires clearing it first, and clearing is a separate user-facing action from scheduling a job.  This is a feature rather than a workaround: it is what makes targeted re-scrapes possible without adding a second kind of job or a scope flag.
