# Archive Links — Research

Research notes to prepare for the "archive links" MVP feature: given a bookmark
URL, produce one or more durable archives of the page so it can be read later
even if the original goes offline.

## How this maps onto what we already have

The schema already anticipates this. The `archives` table stores, per bookmark,
a `url` and a `host`:

```sql
CREATE TABLE archives (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bookmark_id INTEGER NOT NULL,
  url TEXT NOT NULL,
  host TEXT NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (bookmark_id) REFERENCES bookmarks (id)
);
```

That shape — `(url, host)` — is a natural fit for **remote/hosted archives**:
`host = web.archive.org`, `url = https://web.archive.org/web/<ts>/<original>`.
A bookmark can have many archives across many hosts, which is exactly what you
want (no single archive is guaranteed to survive).

**Local archives** (a WARC or single-file HTML we generate ourselves) don't
have a natural remote URL. To fit the same table they'd need us to serve them —
`host = "local"`, `url = /archives/<id>/index.html` served by mist — plus
somewhere to put the bytes (filesystem path or a blob column). That's an
additional design decision, flagged below.

The existing "scraper job runs periodically, fills in partial data" architecture
is the right place to drive archiving: adding a bookmark enqueues archive work,
the background job performs it (submit / poll / download), and writes rows into
`archives` when each one lands.

---

## Category A — Remote / hosted archive services

These do the capture and hosting for us. We make an HTTP call, get back a URL,
store `(url, host)`. Cheapest to implement in Gleam because it's just
`gleam_http`/`mist` client requests — no external binaries, no browser, no
storage. The trade-off is we don't control retention and most have rate limits.

### 1. Internet Archive — Wayback Machine "Save Page Now 2" (SPN2)

The obvious default. Free, enormous, widely trusted, and the resulting URLs are
what most people mean by "an archive link."

- **Submit:** `POST https://web.archive.org/save`
  - Headers: `Accept: application/json`, `Authorization: LOW <access_key>:<secret_key>`
  - Body (form): `url=<target>`, plus optional flags:
    - `capture_all=1` — also capture pages that return 4xx/5xx
    - `skip_first_archive=1` — faster, skips the "is there already a copy" check
    - `capture_outlinks=1`, `capture_screenshot=1` — optional extras
  - Returns JSON `{ "url": "...", "job_id": "..." }`.
- **Poll status:** `GET https://web.archive.org/save/status/<job_id>` →
  `{ "status": "pending" | "success" | "error", "timestamp": "<14-digit>", "original_url": "..." }`.
  On success, the durable link is
  `https://web.archive.org/web/<timestamp>/<original_url>`.
- **Auth:** free archive.org account → S3-style keys at
  `https://archive.org/account/s3.php`. Unauthenticated saves are effectively
  not supported anymore.
- **Rate limits:** yes, per-account; SPN2 is asynchronous precisely because jobs
  queue. Our background job's submit-then-poll model matches this exactly.
- **Lookup existing:** the availability API
  `GET https://archive.org/wayback/available?url=<u>&timestamp=<ts>` cheaply
  tells you whether a snapshot already exists, so we can avoid re-archiving.
- **Fidelity:** good for static/article content; JS-heavy SPAs can capture
  imperfectly.

**Verdict:** best first backend. Well-understood HTTP, async model fits our
scraper, free, permanent-ish.

### 2. archive.today (archive.ph / .is / .li / .md / .vn)

Complements Wayback: it flattens the page to a static screenshot-ish HTML
snapshot and is often better at paywalled/JS-heavy pages that Wayback mangles.

- **No official API.** Submission is a `POST` to `/submit/` with `url=<target>`
  on one of the mirror domains; the response/`Refresh` header points at the
  final `https://archive.ph/<id>` snapshot. Unofficial wrappers exist
  (e.g. `HRDepartment/archivetoday`).
- **Retrieval** is Memento-compatible (TimeGate/TimeMap), so we can look up
  existing snapshots in a standard way even though submission isn't documented.
- **Caveats:** aggressive anti-bot (Cloudflare, occasional CAPTCHA), unstable
  mirror availability, no SLA, and terms that don't really invite automation.
  Treat as a nice-to-have secondary backend, not something to depend on.

**Verdict:** valuable as a second opinion for paywalled content, but brittle to
automate. Ship it after Wayback, behind a "best effort" expectation.

### 3. Perma.cc

The most "official" API of the bunch, aimed at legal/academic citation
permanence.

- **Submit:** `POST https://api.perma.cc/v1/archives/`
  - Header: `Authorization: ApiKey <your-key>`, `Content-Type: application/json`
  - Body: `{ "url": "...", "title": "...", "folder": <id?> }`
  - Returns a GUID; link is `https://perma.cc/<GUID>`.
- **Clean, documented REST API** (create/list/read archives, folders, etc.).
- **Caveats:** free tier is capped (small monthly link quota unless you're
  affiliated with a subscribing library/court). Not suitable as the *primary*
  backend for a personal firehose of bookmarks, but excellent for a curated
  "this one matters" subset.

**Verdict:** cleanest API here; gate it behind a per-bookmark "permanent" flag
because of quotas.

### 4. Others worth knowing

- **Ghostarchive** — good at Twitter/YouTube/JS pages; no public API, manual/
  scraped submission only. Skip for now.
- **Conifer / Webrecorder.net (hosted)** — high-fidelity interactive capture,
  produces WARC/WACZ; more of a manual/session tool than a fire-and-forget API.
- **12ft / freedium-style readers** — not archives (no persistence); ignore.

---

## Category B — Local archives (we generate and keep the bytes)

Here *we* capture the page and own the artifact, so it survives even if every
third-party archive disappears. The cost: we must run an external tool
(none of these are BEAM-native), likely ship a headless Chromium, and decide
where bytes live and how to replay them. In Gleam this means shelling out via an
Erlang **port** / `os:cmd` to a CLI and capturing its exit status + output file.

Two output philosophies:

- **Single self-contained HTML** — one `.html` with every asset inlined as
  data URIs. Trivial to store and to serve back (just return the file). Loses
  some fidelity, no "as browsed" replay guarantees. Great for articles.
- **WARC / WACZ** — the archival standard: records the raw HTTP
  request/response traffic. High fidelity, needs a replay layer (pywb /
  replayweb.page) to view. Heavier, but "proper" web archiving.

### 1. SingleFile CLI (`single-file-cli`) — recommended local option

- Node/Deno CLI built on the SingleFile extension engine. Drives headless
  Chromium, so **JS runs** and the DOM is captured as rendered.
- `single-file <url> output.html` → one self-contained HTML file.
- Needs: Node (or Deno) + a Chromium/Chrome binary. **We already have Chromium
  pre-installed in this environment**, which lowers the barrier.
- AGPL-3.0.

**Why it's the local front-runner:** best fidelity-to-effort ratio, output is a
single file we can drop on disk and serve directly from mist. Storage model is
trivial (`host="local"`, `url="/archives/<id>.html"`).

### 2. monolith

- Single Rust binary, no browser required → tiny, fast, easy to deploy.
- `monolith <url> -o output.html` → self-contained HTML.
- **Does not execute JS** (fetches the initial HTML + assets), so SPAs and
  infinite-scroll pages capture poorly. Can be paired with headless Chromium for
  pre-rendering, which erases its simplicity advantage.

**Verdict:** attractive because it's one static binary with no Node/Chromium,
but the no-JS limitation makes it weaker on the modern web. Good fallback / good
for known-static sources.

### 3. obelisk

- Go equivalent of monolith (single binary, no JS). Same trade-offs as monolith;
  pick one, not both.

### 4. wget `--warc-file`

- Ubiquitous, already-packaged, can emit a standards-compliant WARC.
- No JS execution; struggles with modern sites; requires pywb/replayweb.page to
  view. Fine for a quick "raw bytes" capture, weak as a primary reader
  experience.

### 5. ArchiveBox

- Self-hosted archiving *suite* (Python/Django). Given a URL it runs a whole
  battery: wget, headless-Chrome HTML, PDF, screenshot (PNG), WARC, readability
  article text, favicon, media via yt-dlp, git, etc. Output in HTML/PDF/PNG/
  WARC/JSON/SQLite on the filesystem.
- **Not a library we embed** — it's a separate service with its own DB and
  scheduler. Integrating means either running it alongside and linking to its
  output, or cherry-picking its underlying tools ourselves.

**Verdict:** overlaps heavily with what *we're* building (it has its own DB,
scheduler, and UI). Best used as a reference architecture / menu of extractors
rather than a dependency. If we ever want "capture everything," it's the model
to copy.

### 6. browsertrix-crawler

- Webrecorder's Dockerised, browser-based crawler → high-fidelity **WACZ**.
- The serious choice if we want multi-page, JS-faithful WARC/WACZ captures with
  `replayweb.page` for replay. Heaviest to operate (Docker + browser + replay
  layer). Overkill for single-page bookmark archiving today; keep in mind if the
  product grows toward full-site capture.

---

## Cross-cutting infrastructure

- **WARC** (ISO 28500) is the interchange format if we go the "own the bytes,
  high fidelity" route. **WACZ** is the newer web-friendly package (zipped WARC +
  index) that `replayweb.page` (a static, self-hostable JS viewer) can replay
  with no server. `pywb` is the server-side replay/index option.
- **Memento protocol (RFC 7089)** — a uniform HTTP API (TimeGate/TimeMap) for
  *finding* existing archives of a URL across many archives at once. Wayback and
  archive.today both support it. Aggregators (`MemGator`, the mementoweb.org
  service) let us ask "who already has a copy of this URL?" in one call. Useful
  for a cheap "link an existing archive instead of making a new one" path, and
  for a future "show all known archives" view — independent of which service we
  submit *to*.

---

## Recommendation for the MVP

Phase the work; lead with the low-effort, high-value remote path.

1. **Wayback Machine SPN2 as the first backend.** Pure HTTP, async submit +
   poll maps cleanly onto the existing scraper job, free, trusted, and produces
   exactly a `(url, host)` row. This alone delivers the feature. Add the
   availability-API check to skip re-archiving URLs that already have a snapshot.

2. **Make the backend an interface, not a hardcode.** The `host` column already
   implies multiple providers. Model an "archiver" as something that takes a URL
   and eventually yields `(host, url)`, so backends are pluggable.

3. **Add archive.today and/or Perma.cc as optional secondary backends.**
   archive.today for paywalled/JS pages (best-effort, unofficial), Perma.cc for
   a curated "make this permanent" subset (clean API, but quota-gated).

4. **Add local single-file capture (SingleFile CLI) when we want independence
   from third parties.** This is the first feature that needs: shelling out to a
   CLI from the BEAM (Erlang port), a bundled Chromium, a storage location for
   the artifact, and a mist route to serve it back. Decide storage (filesystem
   path vs. SQLite blob) and the `host="local"` replay URL scheme before
   starting. monolith/obelisk are lighter fallbacks for known-static sources;
   WARC/WACZ + replayweb.page is the upgrade path if we later want full fidelity.

Net: **the MVP is Wayback SPN2 behind a pluggable archiver interface.**
Everything else is an additive backend once that seam exists. Local capture is a
deliberate step-up in operational complexity — worth doing for durability, but
not required to ship the feature.

---

## Sources

- Wayback SPN2 API write-up — <https://foxrow.com/til-api-for-saving-webpages-in-the-wayback-machine>
- Save Page Now help — <https://help.archive.org/help/save-pages-in-the-wayback-machine/>
- SPN2 client library (endpoints, job_id, S3 auth) — <https://github.com/RaghavSood/spn2>
- archive.today unofficial API/CLI — <https://github.com/HRDepartment/archivetoday>
- Perma.cc developer docs — <https://perma.cc/docs/developer>
- ArchiveBox — <https://archivebox.io/> / <https://github.com/archivebox/archivebox>
- SingleFile CLI — <https://github.com/gildas-lormeau/single-file-cli>
- monolith — <https://github.com/Y2Z/monolith>
- pywb / WARC replay — <https://github.com/webrecorder/pywb>
- Memento (RFC 7089) / aggregators — <https://mementoweb.org/about/> / <https://github.com/lanl/TimeStitch-Memento-Aggregator>
