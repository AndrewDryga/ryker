defmodule Ryker.ControlPlane.MemorySummaryStatusTest do
  use Ryker.DataCase, async: false

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{ConversationMemory, LearnedPage, Projection}
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Repo
  alias Ryker.State.{ConversationSummary, LearningSources}

  setup do
    retention = Application.fetch_env(:ryker, :retention)
    Application.put_env(:ryker, :retention, %{conversation_memory_seconds: 3_600})

    on_exit(fn ->
      case retention do
        {:ok, value} -> Application.put_env(:ryker, :retention, value)
        :error -> Application.delete_env(:ryker, :retention)
      end
    end)
  end

  test "the summaries list opens with its search and views, not with help, on a phone" do
    # On the retained replay's 390px page, expanded help consumed the entire
    # first screen before counts, search or a single topic could be reached.
    # The help is gone; the one-line description is the route's own.
    summary!([])
    document = render_summaries() |> LazyHTML.from_document()
    assert Enum.empty?(LazyHTML.query(document, ".page-description, h1, details.page-help"))
    assert Enum.count(LazyHTML.query(document, ".kit-toolbar form.filter-toolbar")) == 1
    assert Enum.count(LazyHTML.query(document, ".kit-toolbar nav.segmented")) == 1

    assert LazyHTML.query(document, ".kit-toolbar + .entity-list article.entity-row")
           |> Enum.count() == 1
  end

  for dependencies <- [[], nil, %{}, "unavailable"] do
    test "a summary with #{inspect(dependencies)} source history remains inspectable with an honest recall label" do
      # The replay retains hundreds of receiptless summaries. Hiding them from
      # model recall must not look like deleted history or usable memory in UI.
      summary = summary!(unquote(Macro.escape(dependencies)))
      [item] = ConversationMemory.project(%{"kind" => "context"}).items
      assert item.recall_warning == :missing_source_history
      assert item.expires_at == nil

      html = render_summaries()
      row = html |> LazyHTML.from_document() |> LazyHTML.query("article.entity-row")
      assert LazyHTML.query(row, ".state-word[data-tone=warn]") |> LazyHTML.text() == "Not used"
      warning = LazyHTML.query(row, ".memory-note") |> LazyHTML.text()
      assert warning =~ "Not used in answers"
      assert warning =~ "no complete record of the messages behind it was saved"
      assert warning =~ "kept so you can read it"
      refute warning =~ "rebuild this topic"
      retention = LazyHTML.query(row, ".entity-meta") |> LazyHTML.text()
      assert retention =~ "No automatic expiry"
      refute retention =~ "Kept until"
      assert html =~ "Retained summary text for inspection."
      assert Repo.get!(ConversationSummary, summary.id) == summary
    end
  end

  test "the missing-source label is not applied to a summary with a real source receipt" do
    [entry | _] = LearningFixtures.inputs!()
    assert [_] = dependencies = LearningSources.for_entry(entry)
    summary!(dependencies)

    [item] = ConversationMemory.project(%{"kind" => "context"}).items
    assert item.recall_warning == nil
    assert %DateTime{} = item.expires_at
    refute render_summaries() =~ "No complete source history was saved"
  end

  test "handover maintenance reports capacity without losing its saved text or confusing source time" do
    [entry | _] = LearningFixtures.inputs!()
    summary = summary!(LearningSources.for_entry(entry))

    Repo.update!(
      Ecto.Changeset.change(summary,
        compaction_error_code: "source_capacity",
        compaction_retry_at: DateTime.add(DateTime.utc_now(), 3600)
      )
    )

    [item] = ConversationMemory.project(%{"kind" => "context"}).items
    assert item.source_at == entry.occurred_at
    assert item.changed_at != item.source_at
    html = render_summaries()
    assert html =~ "source history is too large to combine safely"
    assert html =~ "Retained summary text for inspection."
    # Two dates, two words: when Ryker changed it and when the message was said.
    assert html =~ "Latest message"
    assert html =~ "Updated"
  end

  for retained_at <- [nil, "not-a-timestamp"] do
    test "invalid receipt time #{inspect(retained_at)} is not displayed as usable memory with a guessed expiry" do
      # A nonempty array is not proof of usable source history. Do not tell the
      # operator it is recallable, expires on a guessed date, or is kept forever.
      [entry | _] = LearningFixtures.inputs!()
      assert [receipt] = LearningSources.for_entry(entry)
      summary = summary!([Map.put(receipt, "retained_at", unquote(retained_at))])

      [item] = ConversationMemory.project(%{"kind" => "context"}).items
      assert item.recall_warning == :invalid_source_history
      assert item.expires_at == nil

      html = render_summaries()
      document = LazyHTML.from_document(html)
      warning = document |> LazyHTML.query(".memory-note") |> LazyHTML.text()
      assert warning =~ "Not used in answers"
      assert warning =~ "the record of the messages behind it is invalid"
      retention = document |> LazyHTML.query(".entity-meta") |> LazyHTML.text()
      assert retention =~ "Expiry unknown"
      refute retention =~ "Kept until"
      refute retention =~ "No automatic expiry"
      assert html =~ "Retained summary text for inspection."
      assert Repo.get!(ConversationSummary, summary.id) == summary
    end
  end

  defp render_summaries do
    Projection.learned(%{"kind" => "context"})
    |> LearnedPage.html("test-secret")
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
