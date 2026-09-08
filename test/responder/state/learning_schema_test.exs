defmodule Responder.State.LearningSchemaTest do
  use Responder.DataCase, async: false
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.State.Learning

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}

  test "learning action schemas agree with target and version semantics" do
    [entry | _] = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare([entry.id], @policy)
    schema = JSV.build!(run.output_schema)

    # Structural contract variants over an unchanged harvested input. These
    # are not purported model judgments or a model-quality evaluation.
    create = %{
      "action" => "create",
      "source_input_ids" => [entry.id],
      "topic_key" => "website-haproxy-oom",
      "title" => "Website HAProxy OOM",
      "summary" => "Grafana reported a workload memory-limit breach.",
      "topics" => [],
      "anchors" => [],
      "target_ref" => nil,
      "expected_version" => 0
    }

    update =
      Map.merge(create, %{
        "action" => "update",
        "target_ref" => "knowledge:#{Ecto.UUID.generate()}",
        "expected_version" => 1
      })

    for proposal <- [create, update] do
      document = document(proposal)
      assert {:ok, ^document} = JSV.validate(document, schema, cast: false)
    end

    for invalid <- [
          %{create | "action" => "update"},
          %{update | "action" => "create"},
          %{create | "expected_version" => 1},
          %{update | "expected_version" => 0},
          %{update | "target_ref" => nil}
        ] do
      assert {:error, _} = JSV.validate(document(invalid), schema, cast: false)
    end

    [item, _defer] = run.output_schema["properties"]["updates"]["items"]["oneOf"]

    assert item["oneOf"] == [
             %{
               "properties" => %{
                 "action" => %{"const" => "create"},
                 "target_ref" => %{"type" => "null"},
                 "expected_version" => %{"const" => 0}
               }
             },
             %{
               "properties" => %{
                 "action" => %{"const" => "update"},
                 "target_ref" => %{"type" => "string"},
                 "expected_version" => %{"minimum" => 1}
               }
             }
           ]
  end

  defp document(proposal), do: %{"reason" => "Contract qualification.", "updates" => [proposal]}
end
