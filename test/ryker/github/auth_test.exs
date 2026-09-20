defmodule Ryker.GitHub.AuthTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Ryker.GitHub.{Auth, Binding}

  test "matches GitHub's published HMAC-SHA256 verification vector" do
    assert Auth.signature("It's a Secret to Everybody", "Hello, World!") ==
             "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"
  end

  test "requires exactly one constant-time SHA-256 signature over the raw body" do
    binding = binding!()
    body = ~s({"action":"created"})
    signature = Auth.signature(binding.secret, body)

    authorized = conn(:post, "/") |> put_req_header("x-hub-signature-256", signature)
    assert Auth.authorize(authorized, binding, body) == :ok

    missing = conn(:post, "/")
    assert Auth.authorize(missing, binding, body) == {:error, :unauthorized}

    changed = conn(:post, "/") |> put_req_header("x-hub-signature-256", signature)
    assert Auth.authorize(changed, binding, body <> " ") == {:error, :unauthorized}

    repeated =
      conn(:post, "/")
      |> put_req_header("x-hub-signature-256", signature)
      |> prepend_req_headers([{"x-hub-signature-256", signature}])

    assert Auth.authorize(repeated, binding, body) == {:error, :unauthorized}
  end

  defp binding! do
    assert {:ok, binding} =
             Binding.new(%{
               installation_id: 41,
               name: "github-main",
               repository_full_name: "octo/example",
               repository_id: 99,
               ryker_actor_id: 99,
               secret: String.duplicate("s", 32)
             })

    binding
  end
end
