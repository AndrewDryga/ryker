defmodule Ryker.Evals.EvidenceTest do
  use ExUnit.Case, async: true
  alias Ryker.Evals.Evidence

  test "nested execution and cleanup diagnostics survive JSON report encoding" do
    report = %{
      choices: [%{result: %{reason: {:coop_error, :unavailable}}}],
      quality: %{
        cleanup_error: {:world_eval_cleanup_errors, {:close, :failed}, {:discard, :busy}},
        accepted_decision: %{"overall_pass" => false}
      }
    }

    printable = Evidence.json_value(report)
    decoded = printable |> Jason.encode!() |> Jason.decode!()

    assert get_in(decoded, ["choices", Access.at(0), "result", "reason"]) ==
             "{:coop_error, :unavailable}"

    assert decoded["quality"]["cleanup_error"] =~ "world_eval_cleanup_errors"
    assert decoded["quality"]["accepted_decision"] == %{"overall_pass" => false}
  end

  test "sanitized model-world evidence redacts nested authority and remains JSON-safe" do
    assert Evidence.sanitize(
             %{
               authorization: "Bearer live-secret",
               nested: [
                 %{private_key: "private material", state: :running},
                 %{"cookie" => "session=value", "visible" => true}
               ],
               token_count: 17
             },
             4_096
           ) == %{
             "authorization" => "[REDACTED]",
             "nested" => [
               %{"private_key" => "[REDACTED]", "state" => "running"},
               %{"cookie" => "[REDACTED]", "visible" => true}
             ],
             "token_count" => "[REDACTED]"
           }
  end

  test "oversized evidence keeps only a content-addressed bound" do
    assert %{
             "bytes" => bytes,
             "sha256" => sha256,
             "truncated" => true
           } = Evidence.sanitize(%{"message" => String.duplicate("é", 64)}, 32)

    assert bytes > 32
    assert byte_size(sha256) == 64
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256)
  end
end
