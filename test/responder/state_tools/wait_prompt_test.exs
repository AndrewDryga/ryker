defmodule Responder.StateTools.WaitPromptTest do
  use ExUnit.Case, async: true

  alias Responder.StateTools.FixedTools

  test "source waits distinguish ingress identity from vendor payload fields" do
    # A fresh Terraform replay waited for source_kind=terraform although the
    # actual notification arrived through Slack, so its terminal update never
    # resumed the episode. This pins the tool guidance; real model replay must
    # separately prove that the model uses it correctly.
    tool = Enum.find(FixedTools.list(capabilities: [:event_waits]), &(&1["name"] == "wait_for"))

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

  test "wait matching starts at the raw payload below the Work input envelope" do
    # The next real replay selected Slack correctly but wrapped run_id inside
    # content, so the terminal update again could not resume its stored wait.
    tool = Enum.find(FixedTools.list(capabilities: [:event_waits]), &(&1["name"] == "wait_for"))

    trigger =
      Enum.find(tool["inputSchema"]["properties"]["trigger"]["oneOf"], fn schema ->
        Map.has_key?(schema["properties"], "source_kind")
      end)

    description = trigger["properties"]["match"]["description"]
    assert description =~ "item.content.content"
    assert description =~ "Do not wrap match in content"
    assert description =~ "within the raw payload"
    assert trigger["properties"]["source_kind"]["description"] =~ "item.content.source.kind"
  end
end
