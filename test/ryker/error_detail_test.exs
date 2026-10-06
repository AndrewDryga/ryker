defmodule Ryker.ErrorDetailTest do
  use ExUnit.Case, async: true
  alias Ryker.ErrorDetail

  # A provider's answer can quote the request it refused, credentials and all, and the lanes
  # stored and logged it as they got it (2026-10-04 review).
  test "a failure's detail keeps what went wrong and none of the credentials it quotes" do
    reason =
      {:coop_error, 500, "internal",
       "POST https://coop.example/v1/turns?signature=link-secret failed: " <>
         "Authorization: Bearer bearer-secret-value, token=assigned-secret, ghp_githubsecret123"}

    detail = ErrorDetail.detail(reason)

    assert detail =~ ~s({:coop_error, 500, "internal", "POST https://coop.example/v1/turns)
    assert detail =~ "[redacted]"

    for secret <- ~w(link-secret bearer-secret-value assigned-secret ghp_githubsecret123) do
      refute detail =~ secret
    end
  end

  test "a long detail is cut to 4 KiB on a character boundary and says so" do
    detail = ErrorDetail.detail({:remote_failed, String.duplicate("é", 5_000)})

    assert byte_size(detail) <= 4_096
    assert String.valid?(detail)
    assert String.ends_with?(detail, "...")
  end

  test "the code is the reason's leading atom, or the lane's own when it has none" do
    assert ErrorDetail.code(:coop_unavailable, :work_execution_failed) == "coop_unavailable"

    assert ErrorDetail.code({:coop_error, 503, "busy", "later"}, :work_execution_failed) ==
             "coop_error"

    assert ErrorDetail.code({"text", :reason}, :work_execution_failed) == "work_execution_failed"
    assert ErrorDetail.code("text", :delivery_failed) == "delivery_failed"
    assert ErrorDetail.code(nil, :delivery_failed) == "delivery_failed"

    assert ErrorDetail.describe({:coop_unavailable, :econnrefused}, :work_execution_failed) ==
             {"coop_unavailable", "{:coop_unavailable, :econnrefused}"}
  end
end
