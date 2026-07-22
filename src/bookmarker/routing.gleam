import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

import mist.{type Connection, type ResponseData}

pub fn handler(req: Request(Connection)) -> Response(ResponseData) {
  case req.method, request.path_segments(req) {
    http.Get, [] ->
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Hello, World!")))
    _, [] ->
      response.new(405)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("Method Not Allowed")),
      )
    http.Post, ["bookmarks"] ->
      response.new(201)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("Bookmark Created")),
      )
    _, _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found")))
  }
}
