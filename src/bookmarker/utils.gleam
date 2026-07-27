import cake/param
import gleam/dynamic/decode.{type Decoder}
import gleam/time/timestamp.{type Timestamp}
import sqlight.{type Value}

pub fn timestamp_to_millis(ts: Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(ts)
  seconds * 1000 + nanoseconds / 1_000_000
}

pub fn millis_to_timestamp(total: Int) -> Timestamp {
  timestamp.from_unix_seconds_and_nanoseconds(
    seconds: total / 1000,
    nanoseconds: { total % 1000 } * 1_000_000,
  )
}

pub fn timestamp_decoder() -> Decoder(Timestamp) {
  decode.int |> decode.map(millis_to_timestamp)
}

pub fn param_to_value(p: param.Param) -> Value {
  case p {
    param.StringParam(v) -> sqlight.text(v)
    param.IntParam(v) -> sqlight.int(v)
    param.FloatParam(v) -> sqlight.float(v)
    param.BoolParam(v) -> sqlight.bool(v)
    param.NullParam -> sqlight.null()
    param.DateParam(_) -> panic as "no date columns in this query yet"
  }
}
