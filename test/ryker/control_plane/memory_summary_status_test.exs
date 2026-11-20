defmodule Ryker.ControlPlane.MemorySummaryStatusTest do
  use Ryker.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ryker.ConsoleSignIn, only: [signed_in_conn: 0]
  alias Ryker.CanonicalJSON
  alias Ryker.Config
  alias Ryker.Continuity.ConversationSummary
  alias Ryker.ControlPlane.{Actions, ConversationMemory, Endpoint, LearnedPage, Projection}
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Learning.LearningSources
  alias Ryker.Repo

  @endpoint Endpoint

  setup do
    Config.put_override(:retention, %{conversation_memory_seconds: 3_600})
  end

  # The topics index expanded every compact source reference twice for its expiry.
  test "a topic row uses the oldest receipt already counted for its frozen generation" do
    {:ok, %{episode: episode}} = Ryker.Episodes.apply(Ryker.Fixtures.Episodes.admit_input())
    {_entry, document} = Ryker.Fixtures.Knowledge.learn!(episode)
    "knowledge:" <> id = document["source_ref"]
    topic = Repo.get!(Ryker.Knowledge.ConversationKnowledge, id)
    expected = topic.source_dependencies |> LearningSources.oldest() |> DateTime.add(3_600)

    {page, statements} = Ryker.QueryWork.statements(fn -> ConversationMemory.project(%{}) end)
    row = Enum.find(page.items, &(&1.id == id))
    assert row.source_count == 1
    assert DateTime.compare(row.expires_at, expected) == :eq
    refute Enum.any?(statements, &String.contains?(&1.sql, "FROM ryker_learning_roots($1) r"))

    # A concurrent rebuild between reading the page and loading source counts
    # must not replace the displayed generation with the new head's receipts.
    Repo.update!(Ecto.Changeset.change(topic, source_generation: topic.source_generation + 1))

    assert [{^id, {1, 1, retained_at}}] =
             Repo.all(Ryker.ControlPlane.Learned.Query.source_counts([topic]))

    assert DateTime.compare(DateTime.add(retained_at, 3_600), expected) == :eq
  end

  # Thirty displayed summaries each scanned the observation table, adding 17 seconds to the first response.
  test "the summary evidence clock can look up an exact observation by primary key" do
    [entry | _] = LearningFixtures.inputs!()
    roots = CanonicalJSON.encode!(LearningSources.for_entry(entry))
    query = Ryker.ControlPlane.Learned.Query.latest_source_at(roots)
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)
    Repo.query!("SET LOCAL enable_seqscan = off")

    plan =
      Repo.query!("EXPLAIN (COSTS OFF) " <> sql, params).rows |> List.flatten() |> Enum.join("\n")

    assert plan =~
             ~r/Index Scan using conversation_observations_pkey[^\n]*\n\s+Index Cond: \(id =/,
           plan
  end

  test "a saved summary resolves a shared source graph only once for its details" do
    # The same frozen references were expanded separately for counts, expiry,
    # the recall warning and the evidence clock on both visits to the page.
    {:ok, %{episode: episode}} = Ryker.Episodes.apply(Ryker.Fixtures.Episodes.admit_input())
    {entry, %{"source_ref" => "knowledge:" <> id}} = Ryker.Fixtures.Knowledge.learn!(episode)
    topic = Repo.get!(Ryker.Knowledge.ConversationKnowledge, id)
    reference = LearningSources.knowledge_reference(id, topic.source_generation, topic.version)
    summary = summary!([reference])

    {page, statements} =
      Ryker.QueryWork.statements(fn ->
        ConversationMemory.project(%{"kind" => "context", "item" => summary.id})
      end)

    assert [item] = page.items
    assert item.source_count == 1
    assert item.source_at == entry.occurred_at
    assert item.expires_at != nil
    assert item.recall_warning == nil
    assert Enum.count(statements, &String.contains?(&1.sql, "ryker_learning_roots(")) == 1
  end

  test "a summary directory is searchable before source history has finished checking" do
    # Thirty retained histories made the page wait twelve seconds before its search could be used.
    {:ok, %{episode: episode}} = Ryker.Episodes.apply(Ryker.Fixtures.Episodes.admit_input())
    {_entry, %{"source_ref" => "knowledge:" <> id}} = Ryker.Fixtures.Knowledge.learn!(episode)
    topic = Repo.get!(Ryker.Knowledge.ConversationKnowledge, id)

    summary =
      summary!([LearningSources.knowledge_reference(id, topic.source_generation, topic.version)])

    {view, statements} =
      Ryker.QueryWork.statements(fn ->
        ConversationMemory.project(%{"kind" => "context", :checking_summary_history => true})
      end)

    assert [%{id: selected, recall_warning: :checking}] = view.items
    assert selected == summary.id
    refute Enum.any?(statements, &String.contains?(&1.sql, "ryker_learning_roots("))
    html = view |> LearnedPage.html(nil) |> IO.iodata_to_binary()
    assert html =~ "Checking source history"
    assert html =~ ~s(name="q")
    assert [%{recall_warning: nil}] = ConversationMemory.project(%{"kind" => "context"}).items
  end

  test "the connected directory marks unsourced summaries after its first render" do
    summary = summary!([])

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "summary-directory"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         projection: Projection.callbacks(),
         actions: Actions.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("f", 32)
       }}
    )

    conn = signed_in_conn() |> Map.put(:host, "localhost") |> get("/memory/learned?kind=context")
    assert html_response(conn, 200) =~ "Checking source history"
    {:ok, view, _} = live(conn)
    render_async(view)
    assert has_element?(view, "#summary-#{summary.id} .state-word", "Not used")
    refute has_element?(view, "main [role=status]", "Checking source history")
    render_patch(view, "/memory/learned?kind=context&q=nonexistent")
    refute has_element?(view, "#summary-#{summary.id}")
  end

  test "the conversation summaries directory does not resolve detail-only message times" do
    # A populated directory took 37 seconds to connect. Rows show their update
    # time; resolving the latest source for every row delayed both renders.
    [entry | _] = LearningFixtures.inputs!()
    summary = summary!(LearningSources.for_entry(entry))

    {page, statements} =
      Ryker.QueryWork.statements(fn ->
        ConversationMemory.project(%{"kind" => "context"})
      end)

    assert Enum.map(page.items, & &1.id) == [summary.id]
    refute Enum.any?(statements, &String.contains?(&1.sql, "matched.occurred_at"))
    [detail] = ConversationMemory.project(%{"kind" => "context", "item" => summary.id}).items
    assert detail.source_at == entry.occurred_at
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

      # The list says it is not used, and why on hover; its page says why in
      # words and what it keeps.
      row = render_summaries() |> LazyHTML.from_document() |> LazyHTML.query("article.entity-row")
      state = LazyHTML.query(row, ".state-word[data-tone=warn]")
      assert LazyHTML.text(state) == "Not used"
      assert [hint] = LazyHTML.attribute(state, "title")
      assert hint =~ "Not used in answers"

      page = render_summary(summary.id) |> LazyHTML.from_document()
      warning = LazyHTML.query(page, ".memory-note") |> LazyHTML.text()
      assert warning =~ "Not used in answers"
      assert warning =~ "no complete record of the messages behind it was saved"
      assert warning =~ "kept so you can read it"
      refute warning =~ "rebuild this topic"
      assert LazyHTML.query(page, "#summary-facts") |> LazyHTML.text() =~ "No automatic expiry"
      assert LazyHTML.text(page) =~ "Retained summary text for inspection."
      assert Repo.get!(ConversationSummary, summary.id) == summary
    end
  end

  test "the missing-source label is not applied to a summary with a real source receipt" do
    [entry | _] = LearningFixtures.inputs!()
    assert [_] = dependencies = LearningSources.for_entry(entry)
    summary = summary!(dependencies)

    [item] = ConversationMemory.project(%{"kind" => "context"}).items
    assert item.recall_warning == nil
    [detail] = ConversationMemory.project(%{"kind" => "context", "item" => summary.id}).items
    assert %DateTime{} = detail.expires_at
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

    [item] = ConversationMemory.project(%{"kind" => "context", "item" => summary.id}).items
    assert item.source_at == entry.occurred_at
    assert item.changed_at != item.source_at
    html = render_summary(summary.id)
    assert html =~ "too many to read together"
    assert html =~ "Retained summary text for inspection."
    # Two dates, two words: when Ryker changed it and when the message was said.
    assert html =~ "Latest message"
    assert html =~ "updated just now"
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

      html = render_summary(summary.id)
      document = LazyHTML.from_document(html)
      warning = document |> LazyHTML.query(".memory-note") |> LazyHTML.text()
      assert warning =~ "Not used in answers"
      assert warning =~ "the record of the messages behind it is invalid"

      retention =
        document
        |> LazyHTML.query("#summary-facts")
        |> LazyHTML.text()
        |> String.split()
        |> Enum.join(" ")

      assert retention =~ "Kept until Unknown"
      refute retention =~ "No automatic expiry"
      assert html =~ "Retained summary text for inspection."
      assert Repo.get!(ConversationSummary, summary.id) == summary
    end
  end

  defp render_summary(id) do
    ConversationMemory.project(%{"kind" => "context", "item" => id})
    |> LearnedPage.html("test-secret")
    |> IO.iodata_to_binary()
  end

  defp render_summaries do
    ConversationMemory.project(%{"kind" => "context"})
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
