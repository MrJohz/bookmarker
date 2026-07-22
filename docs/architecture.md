# Architectural Design

* Two processes under one supervisor:
  * http server (mist)
  * scraper job

The HTTP server handles requests from outside (e.g. adding new bookmarks, listing existing bookmarks, etc).  The scraper job runs periodically in the background, searches for any entries in the database with partial data, and fills in that data.
