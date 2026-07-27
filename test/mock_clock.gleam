import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}

/// A controllable test clock, à la Jest's mocked timers.
///
/// The "current time" lives in an Erlang `atomics` cell, so the `now` closure
/// you hand to production code and the `set`/`advance` controls you call from
/// the test share the same mutable value (even across processes).
pub opaque type Clock {
  Clock(cell: Atomics)
}

/// Create a clock frozen at `start`.
pub fn new(start: Timestamp) -> Clock {
  let clock = Clock(atomics_new(1, []))
  set(clock, start)
  clock
}

/// The `fn() -> Timestamp` to pass where production expects `timestamp.system_time`.
pub fn now(clock: Clock) -> fn() -> Timestamp {
  fn() { read(clock) }
}

/// Jump to an absolute instant.
pub fn set(clock: Clock, to instant: Timestamp) -> Nil {
  let #(seconds, nanos) = timestamp.to_unix_seconds_and_nanoseconds(instant)
  let _ = atomics_put(clock.cell, 1, seconds * 1_000_000_000 + nanos)
  Nil
}

/// Move the clock forward — or backward, with a negative duration.
pub fn advance(clock: Clock, by amount: Duration) -> Nil {
  set(clock, timestamp.add(read(clock), amount))
}

fn read(clock: Clock) -> Timestamp {
  let total = atomics_get(clock.cell, 1)
  timestamp.from_unix_seconds_and_nanoseconds(
    seconds: total / 1_000_000_000,
    nanoseconds: total % 1_000_000_000,
  )
}

/// Opaque handle to an OTP `atomics` array (a mutable, signed 64-bit cell).
type Atomics

@external(erlang, "atomics", "new")
fn atomics_new(arity: Int, opts: List(a)) -> Atomics

@external(erlang, "atomics", "put")
fn atomics_put(ref: Atomics, index: Int, value: Int) -> Nil

@external(erlang, "atomics", "get")
fn atomics_get(ref: Atomics, index: Int) -> Int
