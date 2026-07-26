# Architectural Design

* Two processes under one supervisor:
  * http server (mist)
  * scraper job

The HTTP server handles requests from outside (e.g. adding new bookmarks, listing existing bookmarks, etc).  The scraper job runs periodically in the background, searches for any entries in the database with partial data, and fills in that data.

## Database Structure

* `bookmarks` -> main table with all bookmarks, urls, optional titles, optional content
* `archives` -> archive URLs (e.g. wayback machine) for each bookmark
* `tags` -> tags for each bookmark, combination of `(bm, tag)` is unique
* `changelog` -> changes made to each bookmark, append-only, updated whenever a bookmark is created or modified

## Scraping Tasks

* **Title** — fetch the page title (simple http fetch + html parse)
* **Content** — fetch markdown-y version of content suitable for searching and LLM'ing
* **Tags** — pass content to (v. small) LLM to generate a list of tags relevant to that page
* **Archive** — post request to wayback machine, store generated URL
