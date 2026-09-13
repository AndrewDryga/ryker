defmodule Responder.ControlPlane.KnowledgeRebuildTest do
  use Responder.DataCase, async: false

  alias Phoenix.HTML.Safe
  alias Plug.Conn.Query

  alias Responder.ControlPlane.{
    ConversationMemory,
    CSRF,
    InspectionRedactor,
    MemoryPage,
    RelearnPanel,
    Router,
    SlackMarkdown,
    SourceText
  }

  alias Responder.Episodes.Episode
  alias Responder.Fixtures.DatabaseClock
  alias Responder.Fixtures.Knowledge, as: Fixtures
  alias Responder.Fixtures.Learning, as: LearningFixtures
  alias Responder.Learning.{Batch, Batches}
  alias Responder.Operator.Action

  @settings %{
    policy: "relearn-ui",
    policy_digest: String.duplicate("a", 64),
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16
  }

  test "the source picker fixture stays claimable when the database clock trails the host" do
    # Two full-gate failures came from zero-delay fixture claims comparing host
    # receipt timestamps with a slightly earlier PostgreSQL clock.
    DatabaseClock.behind_host!()
    {id, current} = unavailable_with_current_original!()
    assert is_binary(id)
    assert current.content["text"] =~ "keep"
  end

  test "an unavailable topic offers explicit source selection without changing history on inspection" do
    # Source withdrawal used to leave an unrepairable topic. This renderer
    # fixture uses the retained draft decision; only recovery state is structural.
    destination = %Episode{
      destination_transport: "slack",
      destination_conversation_ref: "slack:TREBUILD:CREBUILD"
    }

    {entry, document} = Fixtures.learn!(destination)
    Fixtures.revoke!(entry)
    id = String.replace_prefix(document["source_ref"], "knowledge:", "")
    view = ConversationMemory.project(%{"kind" => "knowledge", "item" => id})
    assert [%{available: false}] = view.items
    before = view.history

    preview = %{
      topic_id: id,
      version: 1,
      generation: 1,
      available?: false,
      eligible?: true,
      reason: nil,
      existing_batch: nil,
      entries: [
        %{
          input_id: entry.id,
          revision: entry.revision,
          fingerprint: entry.event_fingerprint,
          occurred_at: entry.occurred_at,
          actor_ref: entry.actor_ref,
          content: entry.content,
          source_message_ref: nil,
          suggested?: true
        }
      ],
      page: 1,
      pages: 1,
      total: 1,
      q: ""
    }

    html =
      MemoryPage.render(%{
        view: Map.put(view, :rebuild, preview),
        csrf_secret: String.duplicate("s", 32)
      })
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "Relearn from current sources"
    assert html =~ "Choose up to 16 messages"
    assert html =~ ~s(method="post")
    assert html =~ ~s(name="sources[]")
    assert html =~ "Keep the saved history"
    assert html =~ "draft-ai-suggestions"
    refute html =~ ~r/<details[^>]*class="knowledge-rebuild"[^>]*\bopen\b/
    assert ConversationMemory.project(%{"kind" => "knowledge", "item" => id}).history == before
  end

  test "source selection is explicit and the full retained message is not a search excerpt" do
    preview = preview()
    source = hd(preview.entries)
    assert String.length(SourceText.from_content(source.content)) > 512
    html = render(preview)
    assert html =~ "Read full message"
    assert html =~ "Choose up to 16 messages"
    assert html =~ "Nothing is selected automatically"
    refute html =~ ~r/<input[^>]+type="checkbox"[^>]+checked/

    full =
      source.content
      |> InspectionRedactor.artifact()
      |> Map.fetch!(:text)
      |> Jason.decode!()
      |> SourceText.from_content()
      |> SlackMarkdown.preview(nil)
      |> IO.iodata_to_binary()

    assert html =~ full

    token =
      CSRF.token(secret(), "knowledge:relearn", RelearnPanel.resource(preview.topic_id, 1, 1))

    assert html =~ token

    assert {:ok, encoded} = Base.url_decode64(RelearnPanel.source_value(source), padding: false)

    assert Jason.decode!(encoded) == %{
             "source_input_id" => source.input_id,
             "revision" => source.revision,
             "fingerprint" => source.fingerprint
           }
  end

  test "source inspection escapes markup and redacts secrets before making excerpts" do
    # Structural hostile wrapper around a retained original tests the browser
    # boundary, not a claim that this payload came from the provider.
    preview = preview()
    source = hd(preview.entries)

    source = %{
      source
      | content:
          Map.put(
            source.content,
            "text",
            "<script>alert(1)</script> api_key=must-not-reach-browser " <> source.content["text"]
          )
    }

    html = render(%{preview | entries: [source]})
    assert html =~ "&lt;script&gt;"
    assert html =~ "[redacted]"
    refute html =~ "<script>"
    refute html =~ "must-not-reach-browser"
  end

  test "reselection explains its additional cost and binds the existing budget version" do
    preview = %{
      preview()
      | existing_batch: %{
          id: Ecto.UUID.generate(),
          status: :no_change,
          start_count: 2,
          start_limit: 3,
          budget_version: 4,
          reselect_available?: true
        }
    }

    html = render(preview)
    assert html =~ "Use these messages and grant one more start"
    assert html =~ "/actions/learning/#{preview.existing_batch.id}/reselect"
    assert html =~ ~s(name="budget_version" value="4")
    assert html =~ "does not reset the amount already spent"
  end

  test "busy and disabled states do not offer a source submission" do
    for reason <- [:learning_disabled, :learning_batch_busy, :learning_remote_unresolved] do
      html = render(%{preview() | eligible?: false, reason: reason})
      refute html =~ ~s(method="post")
      refute html =~ ~s(name="sources[]")
      assert html =~ RelearnPanel.reason(reason)
    end
  end

  test "returning from source search or pagination keeps the selector open" do
    html = render(Map.put(preview(), :expanded?, true))
    assert html =~ ~r/<details[^>]*class="knowledge-rebuild"[^>]*\bopen\b/
  end

  test "the source search is the shared toolbar bound to this topic, not the page's own search" do
    # The picker's search used the retired search-form layout with its own
    # visible label and button. It now shares the toolbar contract — search on
    # Enter, hidden fields carrying the topic — while its field name keeps the
    # page search and the source search apart in one URL.
    preview = preview()
    document = preview |> Map.put(:q, "decision") |> render() |> LazyHTML.from_fragment()

    toolbar =
      LazyHTML.query(document, "details.knowledge-rebuild form.filter-toolbar[method=get]")

    assert LazyHTML.attribute(toolbar, "action") == ["/memory#relearn"]

    assert LazyHTML.query(toolbar, "input[type=hidden][name=kind]") |> LazyHTML.attribute("value") ==
             ["knowledge"]

    assert LazyHTML.query(toolbar, "input[type=hidden][name=item]") |> LazyHTML.attribute("value") ==
             [preview.topic_id]

    assert LazyHTML.query(toolbar, "input#relearn-search[type=search][name=rebuild_q]")
           |> LazyHTML.attribute("value") == ["decision"]

    assert Enum.empty?(
             LazyHTML.query(toolbar, "input[name=q], button:not(noscript button), a.filter-clear")
           )

    assert Enum.empty?(LazyHTML.query(document, "form.search-form, .filter-field"))
    # The submission that acts is still the separate POST with the CSRF token.
    assert Enum.count(LazyHTML.query(document, "details.knowledge-rebuild form[method=post]")) ==
             1
  end

  test "relearning forms bind the topic version and generation before any source mutation" do
    preview = preview()
    path = "/actions/knowledge/#{preview.topic_id}/relearn"

    token =
      CSRF.token(secret(), "knowledge:relearn", RelearnPanel.resource(preview.topic_id, 1, 1))

    form = %{
      "_token" => token,
      "version" => "1",
      "generation" => "1",
      "sources" => [RelearnPanel.source_value(hd(preview.entries))]
    }

    for changed <- [%{"version" => "2"}, %{"generation" => "2"}, %{"_token" => "wrong"}] do
      response = post(path, Map.merge(form, changed))
      assert response.status == 403
      assert response.resp_body == "Invalid confirmation token"
    end
  end

  test "relearning rejects malformed and unbounded selections before dispatch" do
    preview = preview()
    path = "/actions/knowledge/#{preview.topic_id}/relearn"
    source = RelearnPanel.source_value(hd(preview.entries))
    form = %{"_token" => "unused", "version" => "1", "generation" => "1", "sources" => [source]}

    for changes <- [
          %{"sources" => []},
          %{"sources" => "not-a-list"},
          %{"sources" => ["not-base64"]},
          %{"sources" => [source, source]},
          %{"sources" => [RelearnPanel.source_value(%{hd(preview.entries) | revision: 0})]},
          %{"sources" => List.duplicate(source, 17)},
          %{"sources" => [%{"revision" => "injected"}]},
          %{"retained_at" => "2099-01-01"},
          %{"version" => "-1"}
        ] do
      response = post(path, Map.merge(form, changes))
      assert response.status == 400
    end

    assert post(path, String.duplicate("a", 16_385)).status == 400
    assert post(path, "sources[bad=1&sources[]=2").status == 400
  end

  test "reselection confirmation binds the existing request budget version" do
    id = Ecto.UUID.generate()
    token = CSRF.token(secret(), "learning:reselect", RelearnPanel.reselect_resource(id, 2, 1, 1))

    form = %{
      "_token" => token,
      "budget_version" => "2",
      "version" => "1",
      "generation" => "1",
      "sources" => [RelearnPanel.source_value(hd(preview().entries))]
    }

    for changed <- [%{"budget_version" => "3"}, %{"version" => "2"}, %{"generation" => "2"}] do
      assert post("/actions/learning/#{id}/reselect", Map.merge(form, changed)).status == 403
    end
  end

  test "the actual picker submits one audited request and repeated clicks cannot reset its budget" do
    {id, current} = unavailable_with_current_original!()

    view =
      ConversationMemory.project(%{"kind" => "knowledge", "item" => id, "rebuild_q" => "keep"})

    assert view.rebuild.eligible?
    assert view.rebuild.expanded?
    assert [source] = view.rebuild.entries
    assert source.input_id == current.id
    before = view.history

    token = CSRF.token(secret(), "knowledge:relearn", RelearnPanel.resource(id, 1, 1))

    form = %{
      "_token" => token,
      "version" => "1",
      "generation" => "1",
      "sources" => [RelearnPanel.source_value(source)]
    }

    first = post("/actions/knowledge/#{id}/relearn", form)
    assert first.status == 303
    assert Repo.aggregate(Action, :count) == 1
    assert Repo.aggregate(Batch, :count) == 2

    repeated = post("/actions/knowledge/#{id}/relearn", form)
    assert repeated.status == 303

    assert Plug.Conn.get_resp_header(first, "location") ==
             Plug.Conn.get_resp_header(repeated, "location")

    assert Repo.aggregate(Action, :count) == 1
    assert Repo.aggregate(Batch, :count) == 2
    assert Enum.all?(Repo.all(Batch), &(&1.start_count == 0))
    assert ConversationMemory.project(%{"kind" => "knowledge", "item" => id}).history == before
  end

  test "a source edited after the picker opened is rejected without an action receipt" do
    {id, current} = unavailable_with_current_original!()

    source =
      hd(ConversationMemory.project(%{"kind" => "knowledge", "item" => id}).rebuild.entries)

    Fixtures.revoke!(current)
    token = CSRF.token(secret(), "knowledge:relearn", RelearnPanel.resource(id, 1, 1))

    form = %{
      "_token" => token,
      "version" => "1",
      "generation" => "1",
      "sources" => [RelearnPanel.source_value(source)]
    }

    response = post("/actions/knowledge/#{id}/relearn", form)
    assert response.status == 409
    assert response.resp_body =~ "no longer eligible"
    assert Repo.aggregate(Action, :count) == 0
    assert Repo.aggregate(Batch, :count) == 1
  end

  defp unavailable_with_current_original! do
    previous = Application.get_env(:responder, :learning)

    Application.put_env(:responder, :learning, %{
      api: __MODULE__,
      client: %{},
      worker_ref: "relearn-ui",
      policy: @settings.policy,
      policy_digest: @settings.policy_digest
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:responder, :learning, previous),
        else: Application.delete_env(:responder, :learning)
    end)

    raw =
      "testdata/learning/retained-draft-keep-thread.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> List.last()

    current = LearningFixtures.retained_input!(raw, @settings)

    destination = %Episode{
      destination_transport: current.destination_transport,
      destination_conversation_ref: current.destination_conversation_ref
    }

    # Existing captured draft topic, structurally withdrawn; the selectable
    # original is the separately retained human keep decision, not derived prose.
    {old, document} = Fixtures.learn!(destination, current.repository_ref)
    Fixtures.revoke!(old)
    [current] = LearningFixtures.normalize_queue_timestamps!([current])
    assert {:ok, %{batch: %Batch{}} = claim} = Batches.claim("relearn-ui-fixture", @settings)
    assert {:ok, _} = Batches.finish(claim, :no_change)
    {String.replace_prefix(document["source_ref"], "knowledge:", ""), current}
  end

  defp post(path, form) do
    body = if is_map(form), do: Query.encode(form), else: form

    options =
      Router.init(%{
        csrf_secret: secret(),
        actions: %{},
        observability: %{},
        projection: %{}
      })

    Plug.Test.conn(:post, path, body)
    |> Map.put(:host, "localhost")
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(options)
  end

  defp preview do
    input =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> hd()

    {:ok, at, _} = DateTime.from_iso8601(input["occurred_at"] <> "Z")

    %{
      topic_id: Ecto.UUID.generate(),
      version: 1,
      generation: 1,
      available?: false,
      eligible?: true,
      reason: nil,
      existing_batch: nil,
      entries: [
        %{
          input_id: Ecto.UUID.generate(),
          revision: input["revision"],
          fingerprint: input["event_fingerprint"],
          occurred_at: at,
          actor_ref: input["actor_ref"],
          content: input["content"],
          source_message_ref: input["source_item_ref"],
          suggested?: true
        }
      ],
      page: 1,
      pages: 1,
      total: 1,
      q: ""
    }
  end

  defp render(preview) do
    RelearnPanel.render(%{__changed__: nil, preview: preview, csrf_secret: secret()})
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp secret, do: String.duplicate("s", 32)
end
