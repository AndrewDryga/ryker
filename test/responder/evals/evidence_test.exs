defmodule Responder.Evals.EvidenceTest do
  use ExUnit.Case, async: true

  alias Responder.Evals.Evidence

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
