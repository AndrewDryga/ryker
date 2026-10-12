defmodule Ryker.StateTools.WaitPromptTest do
  use ExUnit.Case, async: true
  alias Ryker.StateTools.FixedTools

  setup do
    tools = FixedTools.list(capabilities: [:event_waits])
    %{tool: Enum.find(tools, &(&1["name"] == "wait_for"))}
  end

  test "reliable source notifications may be awaited without any scheduled wake", %{tool: tool} do
    schema = JSV.build!(tool["inputSchema"])

    assert {:ok, _} =
             JSV.validate(
               %{
                 "deadline" => nil,
                 "on_timeout" => nil,
                 "verification" => "Verify this run after its next notification.",
                 "trigger" => %{
                   "type" => "source_event",
                   "source_kind" => "slack",
                   "match" => %{"run_id" => "run-k9CpPp3nWjQrkCMG"},
                   "poll_after" => nil
                 }
               },
               schema
             )

    assert tool["description"] =~ "event-only"
  end

  test "source waits distinguish ingress identity from vendor payload fields", %{tool: tool} do
    # A fresh Terraform replay waited for source_kind=terraform although the
    # actual notification arrived through Slack, so its terminal update never
    # resumed the episode. This pins the tool guidance; real model replay must
    # separately prove that the model uses it correctly.
    source_trigger =
      tool["inputSchema"]["properties"]["trigger"]["oneOf"]
      |> Enum.find(&Map.has_key?(&1["properties"], "source_kind"))

    fields = source_trigger["properties"]

    assert is_binary(fields["source_kind"]["description"]),
           "source-event waits must explain which source identity is matched"

    assert fields["source_kind"]["description"] =~ "input envelope's source.kind"
    assert fields["source_kind"]["description"] =~ "Slack notification uses slack"
    assert fields["source_kind"]["description"] =~ "not a vendor name"
    assert fields["match"]["description"] =~ "input.content"
    assert fields["match"]["description"] =~ "exact values"
    assert fields["match"]["description"] =~ "not JSONPath"
  end

  test "wait matching starts at the raw payload below the Work input envelope", %{tool: tool} do
    # The next real replay selected Slack correctly but wrapped run_id inside
    # content, so the terminal update again could not resume its stored wait.
    trigger =
      Enum.find(
        tool["inputSchema"]["properties"]["trigger"]["oneOf"],
        &Map.has_key?(&1["properties"], "source_kind")
      )

    description = trigger["properties"]["match"]["description"]
    assert description =~ "item.content.content"
    assert description =~ "Do not wrap match in content"
    assert description =~ "within the raw payload"
    assert trigger["properties"]["source_kind"]["description"] =~ "item.content.source.kind"
  end

  test "envelope actor metadata cannot be invented inside a raw-payload matcher", %{tool: tool} do
    # A full-world Terraform run invented actor inside content, then tried
    # changing the durable wait. The conflicting second call did not replace it.
    trigger =
      Enum.find(
        tool["inputSchema"]["properties"]["trigger"]["oneOf"],
        &Map.has_key?(&1["properties"], "source_kind")
      )

    assert trigger["properties"]["match"]["description"] =~
             "Actor metadata belongs to the envelope"

    assert tool["description"] =~ "Choose the matcher before the first call"
    assert tool["description"] =~ "does not amend the existing wait"
  end
end
