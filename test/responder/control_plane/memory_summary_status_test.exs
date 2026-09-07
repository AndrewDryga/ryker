defmodule Responder.ControlPlane.MemorySummaryStatusTest do
  use Responder.DataCase, async: false

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.{ConversationMemory, HTML, Projection}
  alias Responder.Fixtures.Learning, as: LearningFixtures
  alias Responder.Repo
  alias Responder.State.{ConversationSummary, LearningSources}

  setup do
    retention = Application.fetch_env(:responder, :retention)
    Application.put_env(:responder, :retention, %{conversation_memory_seconds: 3_600})

    on_exit(fn ->
      case retention do
        {:ok, value} -> Application.put_env(:responder, :retention, value)
        :error -> Application.delete_env(:responder, :retention)
      end
    end)
  end

  for dependencies <- [[], nil, %{}, "unavailable"] do
    test "a summary with #{inspect(dependencies)} source history remains inspectable with an honest recall label" do
      # The replay retains hundreds of receiptless summaries. Hiding them from
      # model recall must not look like deleted history or usable memory in UI.
      summary = summary!(unquote(Macro.escape(dependencies)))
      [item] = ConversationMemory.project(%{"kind" => "summaries"}).items
      assert item.recall_warning == :missing_source_history
      assert item.expires_at == nil

      html = render_summaries()
      warning = html |> LazyHTML.from_document() |> LazyHTML.query(".memory-unavailable")
      assert LazyHTML.text(warning) =~ "Not used for recall"
      assert LazyHTML.text(warning) =~ "No complete source history was saved"
      assert LazyHTML.text(warning) =~ "Kept for inspection"
      refute LazyHTML.text(warning) =~ "rebuild this topic"
      retention = html |> LazyHTML.from_document() |> LazyHTML.query(".memory-expiry")
      assert LazyHTML.text(retention) =~ "no automatic expiry"
      refute LazyHTML.text(retention) =~ "until"
      assert html =~ "Retained summary text for inspection."
      assert Repo.get!(ConversationSummary, summary.id) == summary
    end
  end

  test "the missing-source label is not applied to a summary with a real source receipt" do
    [entry | _] = LearningFixtures.inputs!()
    assert [_] = dependencies = LearningSources.for_entry(entry)
    summary!(dependencies)

    [item] = ConversationMemory.project(%{"kind" => "summaries"}).items
    assert item.recall_warning == nil
    assert %DateTime{} = item.expires_at
    refute render_summaries() =~ "No complete source history was saved"
  end

  for retained_at <- [nil, "not-a-timestamp"] do
    test "invalid receipt time #{inspect(retained_at)} is not displayed as usable memory with a guessed expiry" do
      # A nonempty array is not proof of usable source history. Do not tell the
      # operator it is recallable, expires on a guessed date, or is kept forever.
      [entry | _] = LearningFixtures.inputs!()
      assert [receipt] = LearningSources.for_entry(entry)
      summary = summary!([Map.put(receipt, "retained_at", unquote(retained_at))])

      [item] = ConversationMemory.project(%{"kind" => "summaries"}).items
      assert item.recall_warning == :invalid_source_history
      assert item.expires_at == nil

      html = render_summaries()
      document = LazyHTML.from_document(html)
      warning = document |> LazyHTML.query(".memory-unavailable") |> LazyHTML.text()
      assert warning =~ "Not used for recall"
      assert warning =~ "Source history is invalid"
      retention = document |> LazyHTML.query(".memory-expiry") |> LazyHTML.text()
      assert retention =~ "unknown"
      refute retention =~ "until"
      refute retention =~ "no automatic expiry"
      assert html =~ "Retained summary text for inspection."
      assert Repo.get!(ConversationSummary, summary.id) == summary
    end
  end

  defp render_summaries do
    Projection.memory(%{"kind" => "summaries"})
    |> HTML.memory("test-secret")
    |> IO.iodata_to_binary()
  end

  defp summary!(dependencies) do
    id = Ecto.UUID.generate()
    state = %{"situation" => "Retained summary text for inspection."}

    summary =
      Repo.insert!(%ConversationSummary{
        id: id,
        ref: "continuity:#{id}",
        identity_key: CanonicalJSON.digest(id),
        transport: "slack",
        workspace_ref: "slack:T123",
        conversation_ref: "slack:T123:C123",
        visibility: :public,
        state: state,
        state_fingerprint: CanonicalJSON.digest(state),
        source_dependencies: dependencies || [],
        source_result_ref: "result:#{id}"
      })

    # Insert uses the schema's [] default. Model retained NULL explicitly, then
    # compare against that actual persisted row when checking audit preservation.
    if is_nil(dependencies),
      do: Repo.update!(Ecto.Changeset.change(summary, source_dependencies: nil)),
      else: summary
  end
end
