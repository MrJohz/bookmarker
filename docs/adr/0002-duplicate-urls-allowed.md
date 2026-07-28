# Duplicate URLs are allowed; the canonical URL is advisory

Nothing constrains `bookmarks.url` to be unique, and URLs are stored exactly as submitted — no normalisation on the way in.  The scraper records a `canonical_url` alongside, which is informational only: it can be adopted by editing the URL, but nothing applies it automatically.

## Considered Options

Enforcing uniqueness means normalising before insert, and normalising properly means following redirects — a network call on the write path.  That makes saving a bookmark slow, fallible, and impossible offline, which is unacceptable for the one operation that must always succeed; it is also the moment you are least able to retry, because you are about to close the tab.

Normalising after the fact instead avoids the network call, but means a saved URL silently changes underneath you, and creates collisions when two bookmarks converge on the same address — which then needs either a merge or a failure path before any of this is worth having.

Treating canonicalisation as advice avoids both.  Deduplication becomes a feature to build later on top of `canonical_url` — "this looks similar to…", and an explicit merge combining the metadata of both — rather than a constraint that has to be right at the moment of the first insert.

## Consequences

The same page can be bookmarked twice and will be scraped twice, including two archive submissions and two LLM calls.  Nothing detects this until the similarity feature exists.

Every change to a URL goes through an edit and lands in the changelog, so there is no point at which a URL is altered without a record.
