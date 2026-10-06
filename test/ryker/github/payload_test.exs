defmodule Ryker.GitHub.PayloadTest do
  use ExUnit.Case, async: true
  alias Ryker.GitHub.Payload

  # A check run's details link leads to the CI provider and its html_url to
  # GitHub's page; only the API link is noise.
  test "only GitHub's API links go, and the links a person follows stay" do
    payload = %{
      "check_run" => %{
        "details_url" => "https://ci.example/runs/7",
        "html_url" => "https://github.com/octo/example/runs/7",
        "url" => "https://api.github.com/repos/octo/example/check-runs/7"
      }
    }

    assert Payload.fit(payload, 48_000) ==
             {:ok,
              %{
                "check_run" => %{
                  "details_url" => "https://ci.example/runs/7",
                  "html_url" => "https://github.com/octo/example/runs/7"
                }
              }}
  end

  # Short text is never cut down to nothing to make room; such a payload is
  # refused instead.
  test "a payload that fits only by cutting short text is refused" do
    payload = Map.new(1..100, &{"field_#{&1}", String.duplicate("x", 1_000)})
    assert Payload.fit(payload, 48_000) == {:error, :too_large}
  end
end
