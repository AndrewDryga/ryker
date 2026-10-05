defmodule Ryker.ControlPlane.LearningTimelineTest do
  @moduledoc """
  Background learning, read on the Timeline of the messages it read.

  Andrew, 2026-09-26, of a request's "B1 Learning — Learning · No change ·
  Nothing new to save from these messages · Details": "this sections should
  also be fornestic and detailed like everything else. Like building model
  prompt, responses, token usage, what models did, etc — making this page
  obsolete" (the Learning page's `#learning-receipt`). The chapter said what
  happened and nothing about how: no briefing, no prompt, no response, no
  tokens or cost, no link to the topic it wrote. The exact request and answer
  lived on a second page that the Learning and Learned pages linked to.

  Each learning attempt is now a model call on the Timeline like routing and
  work: a briefing card and a result card, and every link that used to open
  the receipt opens that card.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{
    ConversationMemory,
    EpisodePage,
    EpisodeProjection,
    LearnedPage,
    LearningActivity,
    LearningPage,
    ModelRequests,
    WorkbenchLive
  }

  alias Ryker.Fixtures.Learning, as: Fixtures
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Knowledge.KnowledgeRevision
  alias Ryker.Learning.{Batch, Dispatcher, LearningRun}
  alias Ryker.TestSupport.FakeCoopAPI

  defmodule API do
    @moduledoc false
    alias Ryker.TestSupport.FakeCoopAPI, as: Fake

    defdelegate operation_by_key(client, key), to: Fake
    defdelegate get_session(client, id), to: Fake
    defdelegate get_turn(client, sid, tid), to: Fake
    defdelegate create_session(client, key, policy, ref, source), to: Fake
    defdelegate fence_create_session(client, key, policy, ref, source), to: Fake
    defdelegate cancel_turn(client, sid, tid, key, revision), to: Fake

    def submit_frozen_turn(client, sid, key, revision, submission, nil, []),
      do:
        Fake.submit_turn(
          client,
          sid,
          key,
          revision,
          submission["prompt"],
          submission["output_schema"]
        )

    def fence_frozen_turn(client, sid, key, revision, submission, nil, []),
      do: Fake.fence_frozen_turn(client, sid, key, revision, submission, nil, [])

    def validate_frozen_candidate(client, sid, tid, key, _attempt, sha, :accept),
      do: Fake.validate_candidate(client, sid, tid, key, sha, :accept)
  end

  @settings %{
    policy: "recorded-read-only-policy",
    policy_digest: String.duplicate("a", 64),
    worker_ref: "learning-timeline-test",
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16,
    step_delay_seconds: 0,
    execution_timeout_seconds: 600,
    api: API
  }

  @target "codex:gpt-5.6-luna/low@oncall"

  # The worker's own report of the turn, in the shape the learning accounting
  # test meters: 4,100 fresh and 900 cached input tokens, and a reported cost.
  @report %{
    "usage" => %{
      "input_tokens" => 4_100,
      "cached_input_tokens" => 900,
      "output_tokens" => 640,
      "reasoning_tokens" => 120,
      "cost_recorded" => true,
      "cost_usd" => 0.0123
    },
    "queued_at" => "2026-09-11T10:00:00.000000Z",
    "started_at" => "2026-09-11T10:00:02.000000Z",
    "finished_at" => "2026-09-11T10:00:09.500000Z"
  }

  # Andrew, 2026-09-26: the Learning card said "Knowledge saved" and linked
  # to a receipt page for everything else. The prompt it built, the answer it
  # got, what it cost and the topic it wrote belong on the card, the way the
  # routing and work cards beside it show theirs.
  test "a request's learning card shows the learning prompt, the model's response, tokens and cost, and what changed" do
    [first, _second] = entries = inputs!()
    run = learn!(entries, saved(entries))
    topic = Repo.one!(from(revision in KnowledgeRevision, select: revision.knowledge_id))

    page = timeline(first, %{"disclosed" => ["learning-#{run.id}-request"]})
    chapter = chapter(page, "Learning")

    briefing = LazyHTML.query(chapter, "#learning-#{run.id}")
    assert text(briefing, "h3") == "Learning briefing"
    assert text(briefing, ".request-model-section") =~ "gpt-5.6-luna"

    # The briefing sources: what the pass was told and the messages it read.
    sources = text(briefing, ".prompt-assembly")
    assert sources =~ "System prompt"
    assert sources =~ "Source messages"
    assert sources =~ "Prior knowledge"
    assert sources =~ "website/haproxy-edge"

    # The prompt exactly as it was sent, and the response format beside it.
    prompt = text(briefing, ".final-prompt")
    assert prompt =~ "Full submitted request"
    assert prompt =~ "Response format"
    assert prompt =~ "Learn from these chronologically ordered conversation messages"
    assert prompt =~ first.id

    result = LazyHTML.query(chapter, "#learning-#{run.id}-result")
    assert text(result, "h3") == "Knowledge updated"

    assert text(result, ".request-rationale") =~
             "Maintain the reported condition with uncertainty."

    # What it changed, linked to the topic it wrote.
    decision = LazyHTML.query(result, ".request-decision")
    assert text(decision, "") =~ "1 of 2 from this request"
    link = LazyHTML.query(decision, "a[href='/memory/learned?item=#{topic}#update-1']")
    assert LazyHTML.text(link) =~ "Website HAProxy memory limit"

    # Tokens, cost and where the time went, as the worker reported them.
    run_facts = text(result, ".call-run")
    assert run_facts =~ "gpt-5.6-luna"
    assert run_facts =~ "5,000 in · 18% cached · 640 out · 120 reasoning"
    assert run_facts =~ "$0.012"
    assert run_facts =~ "Passed first time"
    assert run_facts =~ "7.5 s"

    # The model's own answer, word for word, and the proof behind it in Details.
    raw = text(result, ".routing-evidence")
    assert raw =~ "Raw model response"
    assert raw =~ "website-haproxy-oom"
    assert result |> LazyHTML.query(".request-identity") |> LazyHTML.to_html() =~ run.id

    # Ryker's own words on the cards are plain; the prompt and response keep theirs.
    words =
      text(
        chapter,
        ".chapter-heading, .case-card-heading, .request-decision dt, .call-run dt, .ui-disclosure-label"
      )

    refute words =~ ~r/\b(episode|turn|host|admission|lease|digest|manifest|batch)\b/i
  end

  # The Learning chapter reads learning's passes, and learning announces them
  # on a topic of its own that the Timeline did not listen to. Until setup is
  # finished every page also hears the setup topics, which hid it; after that
  # a pass finishing under an open Timeline never showed there.
  test "a learning pass that finishes is heard by its request's open Timeline" do
    [first, _second] = entries = inputs!()
    id = first.episode_id

    for {module, function, arguments} <-
          WorkbenchLive.page_subscriptions("/timeline/" <> id, %{"id" => id}, nil),
        do: :ok = apply(module, function, arguments)

    learn!(entries, saved(entries))

    assert_received {:learning_updated, _id}
  end

  # The chapter said "No change · Nothing new to save from these messages",
  # which is the outcome, not the reason; the model's reason was only on the
  # receipt page.
  test "a learning pass that saved nothing says why, in the model's own words" do
    [first | _] = entries = inputs!()

    recorded =
      "testdata/learning/recorded-no-change-result.json" |> File.read!() |> Jason.decode!()

    run = learn!(entries, recorded["result"])

    result =
      timeline(first) |> chapter("Learning") |> LazyHTML.query("#learning-#{run.id}-result")

    assert text(result, "h3") == "No change needed"

    assert text(result, ".request-rationale") =~
             "The message is a brief acknowledgment with no substantive information to retain."

    assert text(result, ".request-decision") =~ "Nothing saved"
  end

  # Retention removes a learning attempt's prompt and response after the
  # memory limit. The receipt said so; a card that drew its briefing rows and
  # raw response anyway would show empty boxes that look like missing data.
  test "a pruned learning run says retention removed its content, rather than showing empty boxes" do
    [first | _] = entries = inputs!()
    run = learn!(entries, saved(entries))
    {:ok, _pruned} = Repo.transaction(fn -> Ryker.Learning.prune_in_transaction(0) end)
    assert %LearningRun{pruned_at: %DateTime{}, prompt: nil} = Repo.get!(LearningRun, run.id)

    chapter = timeline(first) |> chapter("Learning")
    briefing = LazyHTML.query(chapter, "#learning-#{run.id}")
    result = LazyHTML.query(chapter, "#learning-#{run.id}-result")

    assert text(briefing, "") =~ "Retention removed"
    assert text(result, "") =~ "Retention removed"

    for card <- [briefing, result],
        selector <- [
          ".prompt-assembly",
          ".final-prompt",
          ".routing-evidence",
          ".briefing-unavailable",
          "[data-revoked]"
        ] do
      assert Enum.empty?(LazyHTML.query(card, selector)), "#{selector} drawn for pruned content"
    end

    # What survives retention stays: the outcome, the spend and the topic.
    # The Learning page calls a pruned attempt complete, and so does its card.
    assert text(result, "h3") == "Learning completed"
    assert text(result, ".call-run") =~ "5,000 in"
    assert text(result, ".request-decision") =~ "Website HAProxy memory limit"
  end

  # The Learning page linked each attempt, and Learned each topic update, to
  # a receipt section of their own page (`#learning-receipt`). The Timeline
  # card is now the one place an attempt is read, so both lead there.
  test "the Learning and Learned pages link each attempt or update to its Timeline card" do
    entries = inputs!()
    run = learn!(entries, saved(entries))
    batch = Repo.one!(Batch)
    revision = Repo.one!(KnowledgeRevision)
    # The attempt opens beside the first message it read.
    first = Enum.find(entries, &(&1.id == hd(run.inputs)["source_input_id"]))
    card = "/timeline/#{first.episode_id}#learning-#{run.id}-result"

    learning =
      %{"batch" => batch.id}
      |> LearningActivity.project()
      |> LearningPage.html([], String.duplicate("s", 32))
      |> IO.iodata_to_binary()

    assert learning |> LazyHTML.from_document() |> hrefs("#attempts a") == [card]

    learned =
      %{"item" => revision.knowledge_id}
      |> ConversationMemory.project()
      |> LearnedPage.html("test-secret")
      |> IO.iodata_to_binary()

    assert learned |> LazyHTML.from_document() |> hrefs("#history a", "How this was learned") ==
             [card]

    for html <- [learning, learned], do: refute(html =~ "learning-receipt")

    # The card the links name is on that page.
    assert timeline(first) |> LazyHTML.query("#learning-#{run.id}-result") |> Enum.count() == 1

    # Nothing Ryker serves still points at the retired receipt.
    for path <- Path.wildcard("lib/**/*.{ex,heex}") ++ Path.wildcard("priv/static/*.{css,js}"),
        do: refute(File.read!(path) =~ "learning-receipt", "#{path} links the retired receipt")
  end

  # Learning reads messages routing left alone, which have no request and so
  # no request Timeline. Their attempts open on the message's own page, which
  # draws the same cards.
  test "a learning attempt over a message with no request opens on that message's page" do
    ignored = ignored_input!()
    run = learn!([ignored], "{\"reason\":\"Nothing durable here.\",\"updates\":[]}")
    batch = Repo.one!(from(b in Batch, where: b.id == ^run.batch_id))

    path = "/timeline/#{ignored.id}"

    assert %{"batch" => batch.id}
           |> LearningActivity.project()
           |> LearningPage.html([], String.duplicate("s", 32))
           |> IO.iodata_to_binary()
           |> LazyHTML.from_document()
           |> hrefs("#attempts a") == [path <> "#learning-#{run.id}-result"]

    {:ok, view} = ModelRequests.project_input(ignored.id, %{})
    page = render_component(&EpisodePage.message_page/1, view: view) |> LazyHTML.from_fragment()
    result = page |> chapter("Learning") |> LazyHTML.query("#learning-#{run.id}-result")
    assert text(result, "h3") == "No change needed"
    assert text(result, ".request-rationale") =~ "Nothing durable here."
  end

  # Carried from the retired receipt page (2026-09-26): a learning attempt is
  # read as it was sent. Settings changed afterwards must not rewrite what the
  # card says the model was told.
  test "a learning briefing shows the custom instructions it was sent, not today's settings" do
    assert {:ok, _} =
             Ryker.Instructions.save(:global, "Saved learning instructions", 0, "operator:test")

    [first | _] = entries = inputs!()
    run = learn!(entries, saved(entries))

    assert {:ok, _} =
             Ryker.Instructions.save(
               :global,
               "New settings must not rewrite history",
               1,
               "operator:test"
             )

    sources = timeline(first) |> LazyHTML.query("#learning-#{run.id} .prompt-assembly")
    assert text(sources, "") =~ "Saved learning instructions"
    refute text(sources, "") =~ "New settings must not rewrite history"
  end

  # Carried from the retired receipt page: every part of an attempt crosses
  # the same secret redaction boundary as the rest of the Timeline.
  test "every field of a learning card crosses the secret redaction boundary" do
    [first | _] = entries = inputs!()
    run = learn!(entries, saved(entries))

    prompt =
      run.prompt |> Jason.decode!() |> Map.put("instructions", "password=card-private-password")

    result = run.result |> Jason.decode!() |> Map.put("reason", "token=card-private-token")

    Repo.update!(
      Ecto.Changeset.change(run,
        prompt: Jason.encode!(prompt),
        result: Jason.encode!(result),
        producer: %{"model" => "Bearer card-private-bearer"}
      )
    )

    html =
      first
      |> timeline(%{"disclosed" => ["learning-#{run.id}-request"]})
      |> LazyHTML.to_html()

    assert html =~ "learning-#{run.id}-result"

    for secret <- ~w(card-private-password card-private-token card-private-bearer),
        do: refute(html =~ secret)
  end

  # Carried from the retired receipt page: an update names how it was learned
  # only through the attempt whose exact response wrote it, never through a
  # run id the page was handed.
  test "an update links to how it was learned only when its attempt's response wrote it" do
    [_first | _] = entries = inputs!()
    run = learn!(entries, saved(entries))
    revision = Repo.one!(KnowledgeRevision)

    links = fn ->
      %{"item" => revision.knowledge_id}
      |> ConversationMemory.project()
      |> LearnedPage.html("test-secret")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()
      |> hrefs("#history a", "How this was learned")
    end

    assert [_card] = links.()

    Repo.update!(Ecto.Changeset.change(revision, source_result_ref: "learning:#{run.id}:wrong"))
    assert links.() == []
  end

  defp learn!(entries, result) do
    {:ok, fake} = FakeCoopAPI.start_link([result], turn_report: @report)
    Agent.update(fake, &put_in(&1, [:session, "target"], @target))
    drive!(Map.put(@settings, :client, fake), 6)
    run = Repo.one!(from(r in LearningRun, order_by: [desc: r.inserted_at], limit: 1))
    assert Enum.map(run.inputs, & &1["source_input_id"]) -- Enum.map(entries, & &1.id) == []
    run
  end

  defp drive!(settings, left) when left > 0 do
    Repo.update_all(Batch, set: [next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]])

    case Dispatcher.run_once(settings) do
      {:ok, %Batch{status: status}} when status in [:applied, :no_change] -> :ok
      {:ok, _running} -> drive!(settings, left - 1)
    end
  end

  defp drive!(_settings, _left), do: flunk("learning did not finish")

  defp saved(entries) do
    # Constructed host-contract result over the harvested HAProxy inputs, as
    # the learning accounting test uses: this tests the page, not a judgment.
    Jason.encode!(%{
      "reason" => "Maintain the reported condition with uncertainty.",
      "updates" => [
        %{
          "action" => "create",
          "source_input_ids" => Enum.map(entries, & &1.id),
          "topic_key" => "website-haproxy-oom",
          "title" => "Website HAProxy memory limit",
          "summary" => "Grafana reported the OOM warning resolved; recovery remains unverified.",
          "topics" => ["website", "OOM"],
          "anchors" => [],
          "target_ref" => nil,
          "expected_version" => 0
        }
      ]
    })
  end

  defp inputs! do
    entries = Fixtures.inputs!(isolate: true)
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    Repo.update_all(
      from(e in Entry, where: e.id in ^Enum.map(entries, & &1.id)),
      set: [inserted_at: DateTime.add(now, -1), updated_at: DateTime.add(now, -1)]
    )

    entries
  end

  # A harvested message routing left alone: decided, with no request of its own.
  defp ignored_input! do
    entry =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> hd()
      |> Fixtures.isolate_retained_input()
      |> Fixtures.retained_input!(@settings)

    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    {1, _} =
      Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
        set: [inserted_at: DateTime.add(now, -1), updated_at: DateTime.add(now, -1)]
      )

    assert %Entry{episode_id: nil} = Repo.get!(Entry, entry.id)
  end

  defp episode_key(entry) do
    Repo.one!(from(e in Ryker.Episodes.Episode, where: e.id == ^entry.episode_id, select: e.key))
  end

  defp timeline(entry, params \\ %{}) do
    key = episode_key(entry)
    {:ok, snapshot} = EpisodeProjection.fetch(key, params)
    {:ok, timeline} = ModelRequests.timeline(key, params)

    render_component(&EpisodePage.render/1,
      snapshot: snapshot,
      timeline: timeline,
      params: params
    )
    |> LazyHTML.from_fragment()
  end

  defp chapter(page, title) do
    chapter =
      page
      |> LazyHTML.query("section.background-chapter")
      |> Enum.find(&(text(&1, ".chapter-heading h3") == title))

    assert chapter, "no #{title} chapter"
    chapter
  end

  defp hrefs(document, selector, label \\ nil) do
    document
    |> LazyHTML.query(selector)
    |> Enum.filter(&(is_nil(label) or LazyHTML.text(&1) =~ label))
    |> Enum.flat_map(&LazyHTML.attribute(&1, "href"))
  end

  defp text(node, ""), do: node |> LazyHTML.text() |> squish()
  defp text(node, selector), do: node |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()
  defp squish(value), do: value |> String.split() |> Enum.join(" ")
end
