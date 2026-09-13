defmodule Ryker.Operator.FailureDetailTest do
  use ExUnit.Case, async: true
  alias Ryker.Operator.FailureDetail

  test "retrying the recorded legacy cleanup error cannot hide its ownership blocker" do
    # September 5 retries prepended the protocol code to the same error message;
    # both leftover checkouts lost their recovery guidance and offered retries again.
    fixture =
      File.read!("testdata/control_plane/legacy_cleanup_retry_failure.json") |> Jason.decode!()

    assert FailureDetail.facts(fixture["error_detail"]) == %{
             http_status: 409,
             code: "invalid_session_state",
             reason: :missing_ownership
           }

    # A recognized phrase embedded in an arbitrary provider body is not proof of
    # this exact error, and the provider text must never be reflected into the UI.
    hostile = String.replace(fixture["error_detail"], "workspace", "workspace xoxb-private")
    assert FailureDetail.facts(hostile).reason == nil
    refute inspect(FailureDetail.facts(hostile)) =~ "xoxb-private"
  end

  test "recorded cleanup errors expose known facts without copying provider payloads" do
    fixture = File.read!("testdata/control_plane/legacy_cleanup_failure.json") |> Jason.decode!()

    assert FailureDetail.facts(fixture["error_detail"]) == %{
             http_status: 409,
             code: "invalid_session_state",
             reason: :missing_ownership
           }

    hostile =
      ~s({:coop_error, 409, "invalid_session_state", "xoxb-private-provider-body <script>"})

    assert FailureDetail.facts(hostile) == %{
             http_status: 409,
             code: "invalid_session_state",
             reason: nil
           }

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
