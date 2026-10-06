defmodule Ryker.GitHub.AuthTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test
  alias Ryker.GitHub.Auth

  test "matches GitHub's published HMAC-SHA256 verification vector" do
    assert Auth.signature("It's a Secret to Everybody", "Hello, World!") ==
             "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"
  end

  test "requires exactly one constant-time SHA-256 signature over the raw body" do
    secret = String.duplicate("s", 32)
    body = ~s({"action":"created"})
    signature = Auth.signature(secret, body)

    authorized = conn(:post, "/") |> put_req_header("x-hub-signature-256", signature)
    assert Auth.authorize(authorized, secret, body) == :ok

    missing = conn(:post, "/")
    assert Auth.authorize(missing, secret, body) == {:error, :unauthorized}

    changed = conn(:post, "/") |> put_req_header("x-hub-signature-256", signature)
    assert Auth.authorize(changed, secret, body <> " ") == {:error, :unauthorized}

    repeated =
      conn(:post, "/")
      |> put_req_header("x-hub-signature-256", signature)
      |> prepend_req_headers([{"x-hub-signature-256", signature}])

    assert Auth.authorize(repeated, secret, body) == {:error, :unauthorized}
  end
end
