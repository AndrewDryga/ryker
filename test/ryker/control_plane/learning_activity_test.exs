defmodule Ryker.ControlPlane.LearningActivityTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [digest: 1]
  import Ecto.Query
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias Ryker.CanonicalJSON
  alias Ryker.Config
  alias Ryker.ControlPlane.{Actions, ConversationMemory, CSRF, EpisodePage, EpisodeProjection}
  alias Ryker.ControlPlane.{FailureProjection, LearningActivity, LearningPage, ModelRequests}
  alias Ryker.ControlPlane.{Projection, Router}
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: Fixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Knowledge.{ConversationKnowledge, KnowledgeRevision}
  alias Ryker.Learning.{Batch, Batches, InputMembership}
  alias Ryker.Learning.LearningRun
  alias Ryker.Operator.Action
  alias Ryker.Settings
  alias Ryker.Work.{Custody, Turn}

  @settings %{
    policy: "inspection-policy",
    policy_digest: String.duplicate("a", 64),
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16
  }

  setup do
    Config.put_override(:learning, %{
      api: __MODULE__,
      client: %{},
      worker_ref: "inspection-test",
      policy: @settings.policy,
      policy_digest: @settings.policy_digest
    })

    :ok
  end

  test "disabled learning is explicit and retained waiting messages are visible without claiming knowledge" do
    Config.put_override(:learning, nil)
    inputs!()
    view = LearningActivity.project(%{})
    refute view.enabled
    assert view.state == :off
    assert view.waiting_inputs == 2
    assert view.oldest_waiting_at
    assert view.counts.no_change == 0
    html = render(%{})
    assert html =~ "Learning is off"
    assert html =~ "2 messages waiting"
    assert html =~ "learns nothing from them until learning is on"
    refute html =~ "Knowledge updated"
    refute html =~ "A new source can rebuild this topic"
  end

  test "learning turned on in settings but unable to run says so instead of reading as off" do
    # The saved choice and the runtime disagree when learning has no worker or
    # model yet; "Learning is off" beside a switch that reads "on" misleads.
    # Until the runtime has applied the choice it is starting, not broken.
    Config.put_override(:learning, nil)

    assert {:ok, %{learning: %{enabled: true}, installation: installation}} =
             Ryker.Settings.initialize("control-plane:local")

    assert LearningActivity.project(%{}).state == :starting
    assert render(%{}) =~ "Learning is starting"

    assert :ok = Ryker.Settings.record_application(installation.revision, :ok)
    assert LearningActivity.project(%{}).state == :cannot_start
    assert render(%{}) =~ "Learning can&#39;t start"

    Config.put_override(:learning, %{policy: @settings.policy})
    assert LearningActivity.project(%{}).state == :not_running
    assert render(%{}) =~ "Learning is not running here"
  end

  @tag :learning_count_labels
  test "a single message and model start use singular labels in learning activity" do
    # The live learning page showed "1 messages" and "1 model starts" in its
    # batch list and selected batch, obscuring an otherwise simple progress view.
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", %{@settings | batch_size: 1})
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)

    html = render(%{"batch" => claim.batch.id})

    assert html =~ "1 message"
    assert html =~ "1 of 3 model starts used"
    refute html =~ "1 messages"
    refute html =~ "1 model starts"
  end

  test "a batch's page says what Ryker learned: the model's reason and each topic with its key" do
    # Andrew, 2026-09-28: the page said "Each attempt below shows what it
    # changed" above an attempt that showed nothing; it "should show how
    # knowledge was updated, link to referred learning, Model's reason …,
    # summary, link to topic, topic key".
    [old, _current] = inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)

    proposal = %{
      "topic_key" => "checkout-readiness-history",
      "title" => "Checkout readiness history",
      "summary" => "Checkout readiness alerted once after a deploy and recovered.",
      "topics" => ["checkout"],
      "anchors" => [],
      "target_ref" => nil,
      "expected_version" => 0
    }

    assert {:ok, :ok} =
             Repo.transaction(fn -> KnowledgeFixtures.record_topic(old, proposal, []) end)

    topic = Repo.one!(ConversationKnowledge)

    Repo.update_all(KnowledgeRevision,
      set: [source_result_ref: "learning:#{run.id}:" <> String.duplicate("a", 64)]
    )

    result =
      Jason.encode!(%{
        "reason" => "Kept the checkout readiness history. Left the deploy chatter out.",
        "updates" => [
          Map.put(proposal, "action", "create"),
          %{"action" => "defer", "topic_key" => "deploy-chatter", "title" => "Deploy chatter"}
        ]
      })

    Repo.update!(Ecto.Changeset.change(run, status: :applied, result: result))
    assert {:ok, _} = Batches.finish(claim, :applied, nil)

    learned = claim.batch.id |> page() |> LazyHTML.query("#learned")

    assert text(learned, "#learned-reason") ==
             "Reason Kept the checkout readiness history. Left the deploy chatter out."

    assert learned
           |> LazyHTML.query("article.entity-row h3.entity-name")
           |> Enum.map(&squish/1) == ["Checkout readiness history", "Deploy chatter"]

    assert learned
           |> LazyHTML.query("article.entity-row .entity-side .state-word")
           |> Enum.map(&squish/1) == ["Created", "Left as it was"]

    assert learned
           |> LazyHTML.query("article.entity-row h3.entity-name a")
           |> LazyHTML.attribute("href") ==
             [ConversationMemory.topic_path(topic.id)]

    assert text(learned, "#learned-1") =~ "Checkout readiness alerted once after a deploy"
    assert text(learned, "#learned-1") =~ "key checkout-readiness-history"

    [attempt] = LearningActivity.project(%{"batch" => claim.batch.id}).selected.attempts

    assert learned |> LazyHTML.query(".section-head a") |> LazyHTML.attribute("href") ==
             [attempt.path]
  end

  test "learning from a removed repository still names it owner/repo, as on GitHub" do
    # Andrew, 2026-09-28: "repos must be named like on GH". A removed
    # repository's learning passes keep its ref, and the page printed it:
    # "Repository andrewdryga-andrewdryga".
    actor = "control-plane:local"
    {:ok, settings} = Settings.initialize(actor)

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "tenant-infra", github_repository: "Tenant/infra"},
        settings.installation.revision,
        actor
      )

    {:ok, _} = Settings.delete_repository("tenant-infra", settings.installation.revision, actor)

    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert claim.batch.repository_ref == "tenant-infra"

    html = render(%{"batch" => claim.batch.id})
    assert html =~ "Tenant/infra"
    refute html =~ "tenant-infra"
    assert render(%{}) =~ "Tenant/infra"
  end

  @tag :policy_recovery_ui
  test "retry says it uses the settings in place now and is unavailable when learning has none" do
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_retry_exhausted")
    configuration = Config.fetch_env!(:learning)
    Config.put_override(:learning, %{configuration | policy: "available-account"})
    params = %{"batch" => claim.batch.id}

    html = render(params)

    # It uses the learning settings in place now, said in those words; the
    # worker's name for its policy stays off the page (QA re-test,
    # 2026-09-26: "the current learning policy, ryker-learning").
    assert html =~ "using the learning settings in place now"
    refute html =~ "available-account"

    Config.put_override(:learning, nil)
    selected = LearningActivity.project(params).selected
    refute selected.retry_available
    assert selected.retry_blocked =~ "Learning is off"
    Config.put_override(:learning, %{})
    selected = LearningActivity.project(params).selected
    refute selected.retry_available
    assert selected.retry_blocked =~ "settings aren't valid"
  end

  test "a batch stopped by a topic that lost its sources points to relearning it, not another start" do
    # QA, 2026-09-25, batch 96368bd7: a learned topic's own messages were gone,
    # so every attempt stopped on it. The page offered "Grant one more start",
    # which ran again and stopped the same way. Relearning the topic from the
    # messages that still exist is what lets these messages update it.
    topic = stale_topic!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, _} = Batches.finish(claim, :deferred, "knowledge_target_unavailable")
    params = %{"batch" => claim.batch.id}

    selected = LearningActivity.project(params).selected
    refute selected.retry_available
    relearn = ConversationMemory.topic_path(topic.id) <> "#relearn"
    assert [%{title: "Checkout readiness history", path: ^relearn}] = selected.relearn

    document = params |> render() |> LazyHTML.from_fragment()
    assert LazyHTML.query(document, "#retry") |> Enum.empty?()
    refute LazyHTML.text(document) =~ "Grant one more start"

    assert LazyHTML.query(document, "#what-you-can-do #relearn-#{topic.id} a[href='#{relearn}']")
           |> LazyHTML.text() == "Relearn"

    # Once the topic is relearned the cause is gone, and one more start can
    # update it.
    Repo.delete_all(ConversationKnowledge)
    selected = LearningActivity.project(params).selected
    assert selected.relearn == []
    assert selected.retry_available
  end

  test "a batch stuck on a topic that lost its messages can forget that topic or be dropped, not only relearn it" do
    # Andrew, 2026-09-27: a batch stopped on "Relearn the topic first" offered
    # only Relearn; "I also need any other option than simply relearning, why
    # I can't just forget/delete it?"
    topic = stale_topic!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, _} = Batches.finish(claim, :deferred, "knowledge_target_unavailable")
    batch = claim.batch.id
    batch_page = LearningActivity.path(batch)
    waiting = LearningActivity.project(%{}).waiting_inputs

    options = LazyHTML.query(page(batch), "section#what-you-can-do")

    forget =
      LazyHTML.query(
        options,
        "article#forget-#{topic.id} form[method=get][action='/actions/knowledge/#{topic.id}/forget']"
      )

    # The way back rides in the form: a GET form's action drops its query.
    assert LazyHTML.query(forget, "input[type=hidden][name=back]") |> LazyHTML.attribute("value") ==
             [batch_page]

    assert LazyHTML.query(forget, "button") |> LazyHTML.text() == "Forget topic"

    assert LazyHTML.query(
             options,
             "article#drop form[action='/actions/learning/#{batch}/drop'] button"
           )
           |> LazyHTML.text() == "Drop batch"

    # Forgetting the topic asks first and comes back to the batch, where
    # nothing is left to relearn and one more start can read these messages.
    forgotten = confirm("/actions/knowledge/#{topic.id}/forget", %{"back" => batch_page})
    assert forgotten.status == 303
    assert Plug.Conn.get_resp_header(forgotten, "location") == [batch_page]
    assert Repo.get!(ConversationKnowledge, topic.id).forgotten_at

    selected = LearningActivity.project(%{"batch" => batch}).selected
    assert selected.relearn == []
    assert selected.retry_available
    assert Enum.empty?(LazyHTML.query(page(batch), "article[id^=forget-], article[id^=relearn-]"))

    # Dropping it asks first too: it stops needing a person, leaves Failures,
    # and its messages no longer wait. Its cost stays recorded.
    dropped = confirm("/actions/learning/#{batch}/drop")
    assert dropped.status == 303
    assert Plug.Conn.get_resp_header(dropped, "location") == [batch_page]

    assert %{status: :dropped, start_count: 0, start_limit: 3} = Repo.get!(Batch, batch)
    activity = LearningActivity.project(%{"batch" => batch})
    assert activity.attention.items == []
    assert activity.waiting_inputs < waiting
    assert activity.selected.label == "Dropped"
    assert FailureProjection.fetch("learning", batch) == :not_found

    assert [%{action: :discard, kind: "learning", resource_ref: ^batch}] = Repo.all(Action)

    assert LazyHTML.query(page(batch), "p.kit-status-line .state-word") |> LazyHTML.text() ==
             "Dropped"

    assert Enum.empty?(LazyHTML.query(page(batch), "section#what-you-can-do"))
  end

  test "a batch whose model run is not confirmed stopped cannot be dropped" do
    # Dropping it would leave the unconfirmed run with no stopped batch to
    # reconcile it, and every later batch in the conversation waits on it.
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_remote_unresolved")

    refute LearningActivity.project(%{"batch" => claim.batch.id}).selected.drop_available
    assert confirmation("/actions/learning/#{claim.batch.id}/drop").status == 404

    assert Ryker.Operator.Learning.drop(claim.batch.id, 0, "control-plane:local", "test-drop") ==
             {:error, :learning_remote_outstanding}

    assert Repo.get!(Batch, claim.batch.id).status == :deferred
  end

  test "a batch that used every start on a topic that lost its sources points to relearning it" do
    # QA re-test, 2026-09-26, batch 96368bd7: stopped before batches carried
    # the stale topic's own code, it read "every start was used" and offered
    # "Grant one more start", though both attempts had stopped on the topic.
    # Its attempts carry the cause, so the same rule applies to it.
    topic = stale_topic!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)

    Repo.update!(
      Ecto.Changeset.change(run, status: :rejected, error_code: "knowledge_target_unavailable")
    )

    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_retry_exhausted")
    params = %{"batch" => claim.batch.id}

    selected = LearningActivity.project(params).selected
    refute selected.retry_available
    relearn = ConversationMemory.topic_path(topic.id) <> "#relearn"
    assert [%{path: ^relearn}] = selected.relearn
    assert selected.error =~ "The messages behind a topic it would update changed or are gone"

    [listed] = LearningActivity.project(%{}).attention.items
    assert listed.error =~ "The messages behind a topic it would update changed or are gone"

    # Failures says the same and points to the topic.
    assert {:ok, row} = FailureProjection.fetch("learning", claim.batch.id)
    assert row.summary == "knowledge_target_unavailable"
    assert row.relearn_path == relearn
  end

  test "a stopped batch says the starts it used, and a next check is never in the past" do
    # QA, 2026-09-25: a stopped batch read "1 of 3 model starts used", then
    # "2 of 2" after one more start was granted, and "Next check 58 min ago"
    # for a batch nothing checks again. The limit only matters while the batch
    # can still start, and a check is shown only when one is scheduled ahead.
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    assert render(%{"batch" => claim.batch.id}) =~ "1 of 3 model starts used"

    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_judgment_deferred")

    Repo.update_all(Batch,
      set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -58 * 60)]
    )

    for html <- [render(%{}), render(%{"batch" => claim.batch.id})] do
      assert html =~ "1 model start used"
      refute html =~ "of 3 model starts"
      refute html =~ ~r/next check/i
    end

    set_batch_status!(Repo.get!(Batch, claim.batch.id), :queued)

    Repo.update_all(Batch,
      set: [next_attempt_at: DateTime.add(DateTime.utc_now(), 30 * 60)]
    )

    assert render(%{"batch" => claim.batch.id}) =~ ~r/next check in (29|30) min/i
  end

  test "learning from a chat is named by that chat, not only as a direct conversation" do
    # QA, 2026-09-25: every Learning row from Chat read "Direct conversation",
    # so no two of them could be told apart, least of all on a phone.
    conversation = "control-plane:lab:" <> Ecto.UUID.generate()

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "local-operator"},
        content: %{"text" => "Weekday incident status"},
        destination: %{
          transport: "control_plane",
          conversation_ref: conversation,
          thread_ref: conversation
        },
        event_kind: :message,
        event_ref: "chat-title",
        native_input_id: "chat-title:" <> conversation,
        occurred_at: DateTime.utc_now(),
        occurred_at_source: :ingress,
        revision: 1,
        source: %{kind: "control_plane", ref: "local"},
        source_capabilities: %{},
        source_item_ref: "chat-title"
      })

    {:ok, _} = Inbox.record(input)

    Repo.insert!(%Batch{
      id: Ecto.UUID.generate(),
      scope_key: "chat-title:" <> conversation,
      transport: "control_plane",
      conversation_ref: conversation,
      execution_mode: :live,
      policy: @settings.policy,
      policy_digest: @settings.policy_digest,
      status: :applied,
      input_count: 1,
      completed_at: DateTime.utc_now()
    })

    assert render(%{}) =~ "Direct conversation · Weekday incident status"
  end

  test "no-change batches and every rejected frozen attempt remain inspectable without a topic revision" do
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)

    body =
      "testdata/learning/retained-output-contract-failure.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("public_responses")
      |> hd()
      |> Map.fetch!("text")

    Repo.update!(
      Ecto.Changeset.change(run,
        status: :rejected,
        result: body,
        error_code: "invalid_learning_result"
      )
    )

    assert {:ok, _} = Batches.finish(claim, :no_change, nil)

    view = LearningActivity.project(%{"batch" => claim.batch.id})
    assert view.counts.no_change == 1
    assert view.selected.id == claim.batch.id
    assert [attempt] = view.selected.attempts
    assert attempt.id == run.id

    # The rejected attempt opens on its Timeline card, which keeps the exact
    # response and says why it was rejected.
    result = timeline_card(attempt.path)
    assert text(result, "h3") == attempt.label
    assert text(result, ".request-decision") =~ "wasn't in the form Ryker needs"
    assert text(result, ".routing-evidence") =~ "Raw model response"

    briefing = timeline_card(String.replace_suffix(attempt.path, "-result", ""))
    assert text(briefing, ".final-prompt") =~ "Prompt text"

    html = render(%{"batch" => claim.batch.id})
    assert html =~ "No change needed"
    assert html =~ "Response rejected"
    refute html =~ "learning-receipt"
  end

  test "learning attempt history is chronological even when a new source selection restarts generation numbers" do
    # Reselection preserves the same budget and old runs, but uses a new frozen
    # request key. Sorting only by its local generation puts old attempts first.
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-chronology", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    older = Repo.update!(Ecto.Changeset.change(run, generation: 3, status: :rejected))

    newer =
      older
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id])
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        batch_key: CanonicalJSON.digest(%{"selection" => "structural-second-request"}),
        generation: 1,
        inserted_at: DateTime.add(older.inserted_at, 1, :second)
      })
      |> then(&Repo.insert!(struct!(LearningRun, &1)))

    view = LearningActivity.project(%{"batch" => claim.batch.id})
    assert Enum.map(view.selected.attempts, & &1.id) == [newer.id, older.id]
    assert Enum.map(view.selected.attempts, & &1.number) == [2, 1]

    # The Timeline numbers the attempts the way this page does.
    for attempt <- view.selected.attempts do
      assert text(timeline_card(attempt.path), ".case-card-heading-detail") ==
               "Attempt #{attempt.number}"
    end
  end

  test "a saved no-change attempt never becomes knowledge updated when its batch is reselected" do
    # Rebuild reselection reuses the batch. Using its latest status relabelled
    # earlier no-change attempts as successful updates. The result below is an
    # exact captured acknowledgement result; batch lifecycle here is structural.
    inputs!()
    assert {:ok, claim} = Batches.claim("immutable-attempt-label", @settings)
    assert {:ok, run} = Batches.prepare(claim)

    captured =
      "testdata/learning/recorded-no-change-result.json" |> File.read!() |> Jason.decode!()

    assert digest(captured["result"]) ==
             captured["result_sha256"]

    assert CanonicalJSON.digest(captured["result"]) == captured["retained_run_result_sha256"]

    Repo.update!(Ecto.Changeset.change(run, status: :applied, result: captured["result"]))

    for status <- [:no_change, :queued, :running, :deferred, :applied] do
      set_batch_status!(claim.batch, status)
      assert [attempt] = LearningActivity.project(%{"batch" => claim.batch.id}).selected.attempts
      assert attempt.label == "No change needed", "batch #{status} rewrote the old outcome"
      refute Map.has_key?(attempt, :result)
      assert text(timeline_card(attempt.path), "h3") == attempt.label
    end
  end

  test "pruned attempt results keep a neutral completion label instead of borrowing the batch outcome" do
    inputs!()
    assert {:ok, claim} = Batches.claim("pruned-attempt-label", @settings)
    assert {:ok, run} = Batches.prepare(claim)

    Repo.update!(
      Ecto.Changeset.change(run,
        status: :applied,
        result: nil,
        pruned_at: DateTime.utc_now()
      )
    )

    for status <- [:no_change, :applied] do
      set_batch_status!(claim.batch, status)
      assert [attempt] = LearningActivity.project(%{"batch" => claim.batch.id}).selected.attempts
      assert attempt.label == "Learning completed"
      assert text(timeline_card(attempt.path), "h3") == attempt.label
    end
  end

  test "unresolved remote work blocks retry even when it belongs to another batch in the same scope" do
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_remote_unresolved")

    second =
      Repo.insert!(%Batch{
        scope_key: claim.batch.scope_key,
        transport: claim.batch.transport,
        conversation_ref: claim.batch.conversation_ref,
        repository_ref: claim.batch.repository_ref,
        execution_mode: claim.batch.execution_mode,
        policy: @settings.policy,
        policy_digest: @settings.policy_digest,
        status: :deferred,
        input_count: 1
      })

    view = LearningActivity.project(%{"batch" => second.id})
    refute view.selected.retry_available
    assert view.selected.retry_blocked =~ "earlier model execution"

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(LearningRun, run.id),
        remote_stopped_at: DateTime.utc_now(),
        stop_receipt: %{
          "id" => "host-contract-turn:#{run.id}",
          "session_id" => "host-contract-session:#{run.id}",
          "state" => "cancelled"
        }
      )
    )

    assert LearningActivity.project(%{"batch" => second.id}).selected.retry_available
  end

  test "retry form binds the exact budget version and repeated submission grants only one start" do
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_capacity_exceeded")
    secret = String.duplicate("s", 32)

    token =
      CSRF.token(
        secret,
        "learning:retry",
        LearningActivity.retry_resource(claim.batch.id, 0)
      )

    path = "/actions/learning/#{claim.batch.id}/retry"

    options =
      Router.init(%{
        csrf_secret: secret,
        actions: %{},
        observability: %{},
        projection: %{}
      })

    post = fn fields ->
      Plug.Test.conn(:post, path, URI.encode_query(fields))
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Router.call(options)
    end

    assert post.(%{"_token" => token, "budget_version" => "1"}).status == 403
    assert Repo.aggregate(Action, :count) == 0

    for _ <- 1..2 do
      response = post.(%{"_token" => token, "budget_version" => "0"})
      assert response.status == 303

      assert Plug.Conn.get_resp_header(response, "location") == [
               LearningActivity.path(claim.batch.id)
             ]
    end

    assert %{start_count: 0, start_limit: 1, budget_version: 1} = Repo.get!(Batch, claim.batch.id)
    assert [audit] = Repo.all(Action)
    assert audit.actor_ref == "control-plane:local"
    assert audit.action_ref == "control-plane:learning-retry:#{claim.batch.id}:0"
  end

  test "retry retires a withdrawn source while preserving the valid sibling and spending history" do
    # One withdrawn original used to strand all retained siblings in its batch.
    # Retrying must not resurrect it or prevent the surviving message learning.
    [first, second] = inputs!()
    {claim, response} = retry_with_withdrawn_sources([first])

    assert response.status == 303
    assert Repo.aggregate(Action, :count) == 1

    assert %{budget_version: 1, start_count: 0, start_limit: 1} =
             Repo.get!(Batch, claim.batch.id)

    assert Repo.get!(InputMembership, first.id).terminal_reason == "source_unavailable"
    assert Repo.get!(InputMembership, second.id).terminal_reason == nil
    assert {:ok, resumed} = Batches.claim("inspection-survivor", @settings)
    assert Enum.map(resumed.inputs, & &1.id) == [second.id]
  end

  test "withdrawing every source rejects retry without a grant or success audit" do
    {claim, response} = retry_with_withdrawn_sources(inputs!())
    assert response.status == 409
    assert response.resp_body =~ "can't run again as it was"
    assert Repo.aggregate(Action, :count) == 0
    assert Repo.get!(Batch, claim.batch.id).budget_version == 0
  end

  defp retry_with_withdrawn_sources(withdrawn) do
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_capacity_exceeded")
    secret = String.duplicate("s", 32)

    token =
      CSRF.token(
        secret,
        "learning:retry",
        LearningActivity.retry_resource(claim.batch.id, 0)
      )

    Enum.each(withdrawn, fn entry ->
      Repo.update!(
        Ecto.Changeset.change(entry,
          operational_pruned_at: DateTime.utc_now(),
          content: %{"retention" => "pruned"}
        )
      )
    end)

    options =
      Router.init(%{
        csrf_secret: secret,
        actions: %{},
        observability: %{},
        projection: %{}
      })

    response =
      Plug.Test.conn(
        :post,
        "/actions/learning/#{claim.batch.id}/retry",
        URI.encode_query(%{"_token" => token, "budget_version" => "0"})
      )
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Router.call(options)

    {claim, response}
  end

  test "an attempt closed without its worker session says nothing was sent to the model" do
    # Seven attempts on the Compose install read "The model execution may still
    # be running" for days about a model they had never sent anything. Once the
    # attempt has stop proof that nothing was submitted, the page says that.
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)

    Repo.update!(
      Ecto.Changeset.change(run,
        status: :rejected,
        error_code: "learning_remote_unresolved",
        remote_stopped_at: DateTime.utc_now(),
        stop_receipt: %{
          "kind" => "never_submitted",
          "reason" => "coop_session_replacement_required",
          "session" => "unaddressable",
          "session_id" => nil
        }
      )
    )

    assert {:ok, _} = Batches.release(claim, :learning_session_unconfirmed, 0)
    params = %{"batch" => claim.batch.id}
    assert [attempt] = LearningActivity.project(params).selected.attempts
    assert attempt.error =~ "nothing was sent to the model"
    assert text(timeline_card(attempt.path), ".request-decision") =~ attempt.error
    html = render(params)
    assert html =~ "The worker session could not be confirmed"
    refute html =~ "has not confirmed that this attempt stopped"
  end

  test "learning held for a policy whose sessions are not isolated says so and what to change" do
    # A held policy leaves every conversation's messages waiting. The page has
    # to say why and what to change, or it reads as learning simply being slow.
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    assert LearningActivity.project(%{}).state != :paused

    Repo.update!(
      Ecto.Changeset.change(run,
        status: :rejected,
        error_code: "learning_session_not_isolated",
        remote_stopped_at: DateTime.utc_now(),
        stop_receipt: %{"kind" => "never_submitted", "session_id" => "remote_recorded"}
      )
    )

    start_supervised!(%{
      id: :learning_runtime,
      start: {Agent, :start_link, [fn -> :running end, [name: Ryker.Learning.Runtime]]}
    })

    assert LearningActivity.project(%{}).state == :paused
    html = render(%{})
    assert html =~ "Learning is paused"
    assert html =~ "Check the worker&#39;s version"
    refute html =~ "project_env: false and project_mcp: false"

    # A different configured policy is a new digest: nothing holds it.
    configuration = Config.fetch_env!(:learning)

    Config.put_override(:learning, %{
      configuration
      | policy_digest: String.duplicate("c", 64)
    })

    assert LearningActivity.project(%{}).state == :on
  end

  test "a failed conversation handover remains visible without marking a delivered response failed" do
    # Source-capacity failures intentionally preserve an accepted response. The
    # operator must see the missing handover instead of assuming learning succeeded.
    [entry | _] = inputs!()

    {:ok, _} =
      WorkSessions.pin_episode(entry.episode_id, "inspection-policy", @settings.policy_digest)

    {:ok, claim} = Custody.claim_next("inspection-handover", 60, :work)

    document =
      File.read!("testdata/elixir-eval/alert-controls-rejected-result.json") |> Jason.decode!()

    delivered_at = DateTime.utc_now()

    Repo.update_all(from(t in Turn, where: t.id == ^claim.turn.id),
      set: [
        status: :settled,
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        next_attempt_at: nil,
        candidate: Jason.encode!(document),
        candidate_attempt: 1,
        candidate_sha256: digest(Jason.encode!(document)),
        validation_intent: %{"decision" => "accept"},
        validation_intent_fingerprint: String.duplicate("e", 64),
        continuation: %{"kind" => "complete"},
        validation_receipt: "fixture:accepted-recorded-response",
        result_ref: "fixture:recorded-response",
        accepted_at: delivered_at,
        delivery_document: document,
        delivery_ref: "fixture:recorded-response",
        delivery_fingerprint: CanonicalJSON.digest(document),
        external_receipt: %{"message_ref" => entry.source_item_ref},
        external_receipt_fingerprint: String.duplicate("d", 64),
        delivered_at: delivered_at,
        summary_error_code: "source_capacity"
      ]
    )

    before = Repo.get!(Turn, claim.turn.id)
    view = LearningActivity.project(%{})
    assert view.handover_failures.total == 1
    assert [failure] = view.handover_failures.items
    assert failure.turn_id == claim.turn.id
    assert failure.response_status == "Reply sent"
    assert failure.explanation =~ "source history exceeded"
    assert failure.request_path =~ "attempt=#{claim.turn.id}"
    html = render(%{})
    assert html =~ "Context not saved"
    assert html =~ "Reply sent"
    assert html =~ "The replies themselves were not affected"
    assert Repo.get!(Turn, claim.turn.id) == before
  end

  # Each pager on the Learning page built its links from nothing, so paging one list sent the
  # others back to their first page and dropped the outcome filter (2026-10-04 review).
  test "paging one list keeps where the others are and the outcome chosen" do
    activity =
      %{"outcome" => "updated"}
      |> LearningActivity.project()
      |> put_in([:attention, :page], 2)
      |> put_in([:attention, :pages], 3)
      |> put_in([:recent, :page], 2)
      |> put_in([:recent, :pages], 4)
      |> put_in([:handover_failures, :page], 2)
      |> put_in([:handover_failures, :pages], 3)
      |> put_in([:handover_failures, :total], 51)

    links =
      activity
      |> LearningPage.html([], String.duplicate("s", 32))
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("nav.pagination a")
      |> LazyHTML.attribute("href")
      |> Enum.map(&(URI.parse(&1).query |> URI.decode_query()))

    # The recent list's next page, and the handover list's, each keep the other two lists.
    assert %{
             "attention_page" => "2",
             "page" => "3",
             "handover_page" => "2",
             "outcome" => "updated"
           } in links

    assert %{
             "attention_page" => "2",
             "page" => "2",
             "handover_page" => "3",
             "outcome" => "updated"
           } in links
  end

  defp render(params) do
    params
    |> LearningActivity.project()
    |> LearningPage.html([], String.duplicate("s", 32))
    |> IO.iodata_to_binary()
  end

  defp page(batch), do: %{"batch" => batch} |> render() |> LazyHTML.from_fragment()

  # An action's confirmation page, as the real control plane answers it.
  defp confirmation(path, query \\ %{}) do
    Plug.Test.conn(:get, path <> query_string(query))
    |> Map.put(:host, "localhost")
    |> Router.call(router())
  end

  # Opens an action's confirmation, then confirms it the way its form does.
  defp confirm(path, query \\ %{}) do
    page = confirmation(path, query)
    assert page.status == 200, page.resp_body
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, page.resp_body)
    [_, action] = Regex.run(~r/<form[^>]* action="([^"]+)"/, page.resp_body)

    Plug.Test.conn(:post, unescape(action), URI.encode_query(%{"_token" => token}))
    |> Map.put(:host, "localhost")
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(router())
  end

  defp unescape(html), do: String.replace(html, "&amp;", "&")
  defp query_string(query) when query == %{}, do: ""
  defp query_string(query), do: "?" <> URI.encode_query(query)

  defp router do
    Router.init(%{
      csrf_secret: String.duplicate("s", 32),
      actions: Actions.callbacks(),
      observability: %{},
      projection: Projection.callbacks()
    })
  end

  # The card an attempt's link opens: the page its path names, at its anchor.
  defp timeline_card("/timeline/" <> rest) do
    [id, anchor] = String.split(rest, "#")
    {:ok, key} = EpisodeProjection.request_key(id)
    {:ok, snapshot} = EpisodeProjection.fetch(key)
    {:ok, timeline} = ModelRequests.timeline(key, %{})

    card =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: timeline,
        params: %{}
      )
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#" <> anchor)

    assert Enum.count(card) == 1, "#{rest} opens no card"
    card
  end

  defp squish(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp text(node, selector),
    do: node |> LazyHTML.query(selector) |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp inputs! do
    entries = Fixtures.inputs!()
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    Repo.update_all(Entry, set: [inserted_at: now, updated_at: now])
    entries
  end

  # A learned topic whose only message was deleted: Ryker no longer uses it,
  # and learning from its conversation stops on it until it is relearned.
  defp stale_topic! do
    [old, _current] = inputs!()

    proposal = %{
      "topic_key" => "checkout-readiness-history",
      "title" => "Checkout readiness history",
      "summary" =>
        "This message reports a historical checkout readiness alert; current health is unverified.",
      "topics" => ["checkout"],
      "anchors" => [],
      "target_ref" => nil,
      "expected_version" => 0
    }

    assert {:ok, :ok} =
             Repo.transaction(fn -> KnowledgeFixtures.record_topic(old, proposal, []) end)

    KnowledgeFixtures.revoke!(old)
    Repo.one!(ConversationKnowledge)
  end

  defp set_batch_status!(claimed, status) do
    fields = [:lease_ref, :lease_owner, :lease_expires_at]

    leases =
      if status == :running,
        do: Map.take(claimed, fields),
        else: Map.new(fields, &{&1, nil})

    claimed.id
    |> then(&Repo.get!(Batch, &1))
    |> Ecto.Changeset.change(Map.put(leases, :status, status))
    |> Repo.update!()
  end
end
