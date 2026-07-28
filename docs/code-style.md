# Code Style

## Foundational Principles

* **Invalid states should be unrepresentable** — define types, schemas, functions, etc such that they can only represent valid data and behaviour.  Push parsing or potential invalid states as close to a boundary as possible, don't let invalid data infect the whole application.
* **Repetition isn't the enemy, coupling is** — always be careful of coupling unrelated types.  Generally, only attempt to reduce repetition if the result is a cleaner abstraction (not just less code), and only if the pattern has been repeated 3+ times in the exisiting codebase.

## Principles of Testing

* **Use dependency injection/IoC to make testing easy** — for example, if a function uses the current date/time and we need to test that function, we should inject a `now()` function rather than writing tests that depend on the current system time.
* **Always test domain objects, never private/underlying values** — tests should be written at the level of the domain exposed by the subject being tested.  For example, when testing a `users.gleam` module, tests must exclusively use the public methods exposed by the module, and not independently check the contents of the database or expose test-only private methods.

## Syntactical Code Style

* **Variable names should match their scope** — short-lived variables (e.g. in callbacks) should have short names, 1-3 characters.  Longer-lived variables should have longer names.  But even then, avoid redundancy, and favour common abbreviations (`conn` instead of `connection`, `ctx` instead of `context`).