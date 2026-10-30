defmodule Ryker.Operator.FailureDetailTest do
  use ExUnit.Case, async: true
  alias Ryker.Operator.FailureDetail

  test "pending publication exposes its safe retry stage without raw diagnostics" do
    assert FailureDetail.facts(~s({:publication_worker_retry, "publication_grant_failed", 503})) ==
             %{
               code: "publication_grant_failed",
               http_status: 503,
               stage: "requesting a fresh publication token"
             }

    assert FailureDetail.facts(~s({:publication_worker_retry, "secret_payload", 503})) == nil

    assert FailureDetail.facts(
             ~s({:publication_worker_retry, "publication_grant_failed", 503, "private-body"})
           ) == nil
  end

  test "recorded cleanup errors expose known facts without copying provider payloads" do
    fixture = File.read!("testdata/control_plane/legacy_cleanup_failure.json") |> Jason.decode!()

    assert FailureDetail.facts(fixture["error_detail"]) == %{
             http_status: 409,
             code: "invalid_session_state"
           }

    hostile =
      ~s({:coop_error, 409, "invalid_session_state", "xoxb-private-provider-body <script>"})

    assert FailureDetail.facts(hostile) == %{http_status: 409, code: "invalid_session_state"}

    refute inspect(FailureDetail.facts(hostile)) =~ "private-provider-body"

    for unrecognized <- [
          nil,
          "private transport detail",
          ~s({:coop_error, 409, "secret_key", "body"}),
          ~s(prefix {:coop_error, 409, "invalid_session_state", "body"}),
          String.duplicate("x", 4097)
        ] do
      assert FailureDetail.facts(unrecognized) == nil
    end
  end
end
