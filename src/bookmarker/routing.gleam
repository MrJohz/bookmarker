import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

import mist.{type Connection, type ResponseData}

pub fn handler(req: Request(Connection)) -> Response(ResponseData) {
  case request.path_segments(req) {
    [] ->
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Hello, World!")))
    _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found")))
  }
}
