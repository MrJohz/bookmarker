import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

import mist.{type Connection, type ResponseData}

import bookmarker/logging
import bookmarker/routing

pub fn main() {
  let log = logging.setup()

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      use req <- logging.req_logger(log, req)

      routing.handler(req)
    }
    |> mist.new
    |> mist.bind("localhost")
    |> mist.port(4000)
    |> mist.start

  process.sleep_forever()
}
