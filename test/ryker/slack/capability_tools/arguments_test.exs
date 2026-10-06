defmodule Ryker.Slack.CapabilityTools.ArgumentsTest do
  use ExUnit.Case, async: true
  alias Ryker.Slack.CapabilityTools.Arguments

  @arguments %{"query" => "deployment", "content_types" => ["messages"], "limit" => 20}

  # The tool let a query and its filters reach 4,096 bytes and the client sends at most 2,048,
  # so a long query passed here and failed there with nothing the model could act on
  # (2026-10-04 review). The tool holds the client's bound.
  test "a search the tool accepts is one the client sends" do
    filters = %{@arguments | "query" => String.duplicate("a", 2_040)}

    assert {:ok, %{"query" => query}, _conversations} =
             Arguments.search_document(filters, "T123")

    assert byte_size(query) == 2_040

    with_channel = Map.put(filters, "conversation_refs", ["slack:T123:C456"])
    assert Arguments.search_document(with_channel, "T123") == {:error, :invalid_arguments}
  end

  # Time bounds refused an RFC 3339 time that carried an offset, though it names the same
  # moment as its UTC form (2026-10-04 review).
  test "a time bound with an offset is the moment it names" do
    arguments = Map.put(@arguments, "after", "2026-10-05T12:00:00+02:00")

    assert {:ok, %{"after" => after_time}, _conversations} =
             Arguments.search_document(arguments, "T123")

    assert after_time == DateTime.to_unix(~U[2026-10-05 10:00:00Z])
  end
end
