import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option.{type Option}
import gleam/result
import gleam/time/timestamp
import glogg/handler
import glogg/logger
import mist.{type Connection, type ResponseData}
import youid/uuid

pub fn main() {
  handler.setup_default_handler()
  let log =
    logger.new("bookmarker")
    |> logger.add_hook(fn(event) {
      let ts = timestamp.system_time() |> timestamp.to_unix_seconds
      option.Some(
        logger.LogEvent(..event, fields: [
          logger.float("ts", ts),
          ..event.fields
        ]),
      )
    })

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      use req <- req_logger(log, req)
      case request.path_segments(req) {
        [] ->
          response.new(200)
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string("Hello, World!")),
          )
        _ ->
          response.new(404)
          |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found")))
      }
    }
    |> mist.new
    |> mist.bind("localhost")
    |> mist.port(4000)
    |> mist.start

  process.sleep_forever()
}

fn req_logger(
  log: logger.Logger,
  req: Request(Connection),
  handler: fn(Request(Connection)) -> Response(ResponseData),
) -> Response(ResponseData) {
  let req_id =
    req
    |> request.get_header("x-request-id")
    |> result.lazy_unwrap(uuid.v7_string)

  let clientip =
    mist.get_connection_info(req.body)
    |> result.map(mist.connection_info_to_string)
    |> result.unwrap("unknown")
  let clientua =
    req |> request.get_header("user-agent") |> result.unwrap("unknown")

  let method = req.method |> http.method_to_string
  let path = req.path
  let scheme = req.scheme |> http.scheme_to_string

  logger.debug(log, "incoming request", [
    logger.string("req", req_id),
    logger.string("method", method),
    logger.string("path", path),
    logger.string("scheme", scheme),
    logger.string("clientip", clientip),
    logger.string("clientua", clientua),
  ])

  let start = timestamp.system_time()
  let res = handler(req)
  let duration = timestamp.difference(start, timestamp.system_time())

  logger.info(log, "request handled", [
    logger.string("req", req_id),
    logger.string("method", method),
    logger.string("path", path),
    logger.string("scheme", scheme),
    logger.string("clientip", clientip),
    logger.string("clientua", clientua),
    logger.int("status", res.status),
    logger.duration("duration", duration),
    logger.string(
      "size",
      response_size(res) |> option.map(int.to_string) |> option.unwrap("?"),
    ),
  ])

  res
}

fn response_size(res: Response(ResponseData)) -> Option(Int) {
  case res.body {
    mist.Bytes(body) -> body |> bytes_tree.byte_size |> option.Some
    mist.File(length:, ..) -> length |> option.Some
    _ -> option.None
  }
}
