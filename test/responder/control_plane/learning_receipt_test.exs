defmodule Responder.ControlPlane.LearningReceiptTest do
  use Responder.DataCase, async: false
  alias Responder.ControlPlane.{ConversationMemory, HTML, InspectionRedactor, Projection}
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Repo
  alias Responder.State.{KnowledgeRevision, Learning}

  @policy %{policy: "receipt-test", policy_digest: String.duplicate("a", 64)}

  # The replay had hundreds of notes without an inspectable explanation of how
  # knowledge changed. The source pair is harvested; this candidate tests the host contract.
  test "a knowledge update opens its own complete grouped learning receipt" do
    assert {:ok, _} =
             Responder.Instructions.save(
               :global,
               "Saved learning instructions",
               0,
               "operator:test"
             )

    {run, revision} = learned!()

    assert {:ok, _} =
             Responder.Instructions.save(
               :global,
               "New settings must not rewrite history",
               1,
               "operator:test"
             )

    view = ConversationMemory.project(params(revision))
    assert view.learning.id == run.id
    assert view.learning.version == revision.version
    assert view.learning.input_count == 2
    assert view.learning.reason == "Merge the firing and resolved reports."
    assert view.learning.target == "receipt-test-model"

    assert Enum.map(view.learning.sections, & &1.id) ==
             ~w(inputs knowledge instructions custom_instructions contract prompt result validation)

    custom = Enum.find(view.learning.sections, &(&1.id == "custom_instructions"))
    assert custom.artifact.text =~ "Saved learning instructions"
    refute custom.artifact.text =~ "New settings must not rewrite history"

    assert Enum.all?(view.learning.sections, &(!&1.artifact.truncated))
    expected = InspectionRedactor.artifact(run.prompt, preserve_format: true).text
    assert Enum.find(view.learning.sections, &(&1.id == "prompt")).artifact.text == expected
    assert [%{learning_path: path}] = view.history
    assert path =~ "update=1"

    html =
      HTML.memory(Projection.memory(params(revision)), "test-secret") |> IO.iodata_to_binary()

    doc = LazyHTML.from_document(html)
    assert doc |> LazyHTML.query(".learning-receipt details[open]") |> LazyHTML.to_tree() == []
    assert doc |> LazyHTML.query(".learning-receipt > details") |> Enum.count() == 8
    assert html =~ "How update 1 was learned"
    assert html =~ "Source messages"
    assert html =~ "Response format"
    assert html =~ "estimated tokens"
    assert html =~ "2 messages"
    assert html =~ "No reply was sent by this learning pass."

    for {source, label} <- [
          {"$.inputs", "Source messages"},
          {"$.knowledge", "Prior knowledge"},
          {"$.instructions", "Responder instructions"}
        ] do
      fragment = LazyHTML.query(doc, ".learning-receipt [data-source='#{source}']")
      assert [labelled] = LazyHTML.attribute(fragment, "data-source-label")
      assert labelled =~ label
    end
  end

  test "a receipt is selected by the topic revision not an arbitrary model run id" do
    {run, revision} = learned!()

    for extra <- ["0", "-1", "99999999999999999999999", [], %{}, "2"] do
      view = ConversationMemory.project(Map.put(params(revision), "update", extra))
      assert view.learning == nil
    end

    view = ConversationMemory.project(%{"kind" => "knowledge", "item" => run.id, "update" => "1"})
    assert view.learning == nil
    Repo.update!(Ecto.Changeset.change(revision, source_result_ref: "learning:#{run.id}:wrong"))
    assert ConversationMemory.project(params(revision)).learning == nil
  end

  test "expired learning copies keep the outcome but never reconstruct the old prompt" do
    {run, revision} = learned!()

    Repo.update!(
      Ecto.Changeset.change(run,
        pruned_at: DateTime.utc_now(),
        prompt: nil,
        result: nil,
        knowledge: [],
        producer: %{}
      )
    )

    view = ConversationMemory.project(params(revision))
    assert view.learning.expired
    assert view.learning.sections == []

    html =
      HTML.memory(Projection.memory(params(revision)), "test-secret") |> IO.iodata_to_binary()

    assert html =~ "learning-receipt"

    assert html =~ "The saved request and response expired"
    refute html =~ "Merge the firing and resolved reports."
  end

  test "every receipt field crosses the same secret redaction boundary" do
    {run, revision} = learned!()
    prompt = Jason.decode!(run.prompt)
    prompt = Map.put(prompt, "instructions", "password=receipt-private-password")
    candidate = Jason.decode!(run.result) |> Map.put("reason", "token=receipt-private-token")

    Repo.update!(
      Ecto.Changeset.change(run,
        prompt: Jason.encode!(prompt),
        result: Jason.encode!(candidate),
        producer: %{"model" => "Bearer receipt-private-bearer"}
      )
    )

    html =
      HTML.memory(Projection.memory(params(revision)), "test-secret") |> IO.iodata_to_binary()

    for secret <- ~w(receipt-private-password receipt-private-token receipt-private-bearer),
        do: refute(html =~ secret)
  end

  defp params(revision),
    do: %{"kind" => "knowledge", "item" => revision.knowledge_id, "update" => "1"}

  defp learned! do
    entries = Fixtures.inputs!()
    {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)

    result =
      Jason.encode!(%{
        "reason" => "Merge the firing and resolved reports.",
        "updates" => [
          %{
            "source_input_ids" => Enum.map(entries, & &1.id),
            "topic_key" => "website-haproxy-edge-oom",
            "title" => "Website HAProxy memory limit",
            "summary" => "Grafana reported resolution; application recovery remains unverified.",
            "topics" => ["website", "OOM"],
            "target_ref" => nil,
            "action" => "create",
            "anchors" => [],
            "expected_version" => 0
          }
        ]
      })

    {:ok, applied} =
      Responder.Fixtures.Learning.accept(run.id, result, %{"model" => "receipt-test-model"})

    {applied, Repo.one!(KnowledgeRevision)}
  end
end
