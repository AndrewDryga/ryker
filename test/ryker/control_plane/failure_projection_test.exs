defmodule Ryker.ControlPlane.FailureProjectionTest do
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1]

  # Admission context reads under REPEATABLE READ; the fixture keeps its own
  # workspace so the conversation lock never waits on another suite.
  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query, only: [from: 2]
  alias Ryker.Admission
  alias Ryker.Admission.{Decision, ReadySessions}
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{Actions, ConversationMemory, FailureExplanation, FailureProjection}
  alias Ryker.ControlPlane.{FailuresPage, Pages, Projection, WorkspaceProjection}
  alias Ryker.CoopFleet.Placement
  alias Ryker.Delivery.RoutingResponseCustody
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Ingress.Inbox
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Learning
  alias Ryker.Learning.Batch, as: LearningBatch
  alias Ryker.Learning.FleetSession, as: LearningFleetSession
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Slack.{Interaction, InteractionAudits}
  alias Ryker.Work.{Cancellation, Custody, Session, Submission, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @sandbox String.duplicate("d", 64)

  test "revoked publication approval never promises an automatic retry" do
    row = %{
      kind: "publication",
      summary: "publication_authorization_revoked",
      source: "ryker",
      attempt_count: 1
    }

    explanation = FailureExplanation.explain(row)
    assert explanation.outlook == :fix_first
    assert explanation.summary =~ "could not authorize this publication"
    refute inspect(explanation) =~ "keeps retrying"
  end

  # Andrew, 2026-10-03, of a failure page: it "doesn't tell what was the issue, show an error". A
  # cause Ryker has no words for said "The Technical details keep its code" after Technical
  # details were gone; it now shows the saved code itself, and only ever a code.
  test "an error Ryker has no words for is shown by its saved code" do
    for kind <- ~w(admission publication retention) do
      row = %{kind: kind, summary: "contract_drift_v2", source: "ryker", attempt_count: 1}
      words = inspect(FailureExplanation.explain(row))
      cause = row |> FailureExplanation.explain() |> Map.fetch!(:cause) |> Enum.join(" ")
      assert cause =~ ~s(The saved error is "contract_drift_v2".), kind
      refute words =~ "Technical details", kind

      refute inspect(FailureExplanation.explain(%{row | summary: "#{kind} blocked"})) =~
               "saved error is",
             kind
    end
  end

  # A reaction is the one delivery that belongs to an input rather than an
  # episode. The failures page looked its conversation up through that input,
  # but the delivery row dropped the input id on the way in, so a blocked
  # reaction said "reaction delivery" with no destination to open.
  test "a blocked reaction delivery names the conversation it was reacting in" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please acknowledge this."},
               event_kind: :message,
               event_ref: "Ev-blocked-reaction",
               message_ref: "1787832001.000200",
               occurred_at: @now,
               revision: 1,
               thread_ref: "1787832000.000100",
               workspace_ref: "TBLOCKEDREACTION"
             })

    assert {:ok, %{entry: entry, status: :recorded}} = Inbox.record(input, execution_mode: :live)

    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               now: @now,
               continuation_window: 30 * 60,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8,
               lease_ref: nil
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "messages" => nil,
               "reactions" => ["eyes"],
               "relation" => "unrelated",
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "Acknowledge the source item without starting work.",
               "work_class" => nil
             })

    assert {:ok, _applied} = Admission.commit(context, decision, "decision:blocked-reaction")
    assert {:ok, claim} = RoutingResponseCustody.claim_next("delivery:reaction:blocked", 60)

    assert {:ok, _blocked} =
             RoutingResponseCustody.block(
               claim.response.delivery_ref,
               claim.lease_ref,
               "slack_reaction_rejected",
               "private reaction diagnostic"
             )

    assert {:ok, failures} = FailureProjection.list(%{})
    assert %{} = row = Enum.find(failures, &(&1.ref == claim.response.delivery_ref))
    assert row.kind == "delivery"
    assert row.destination == "slack:TBLOCKEDREACTION:C456 / 1787832000.000100"
    assert row.source == "slack:TBLOCKEDREACTION · Ev-blocked-reaction"
    refute inspect(row) =~ "private reaction diagnostic"
  end

  # A blocked reaction or quick reply holds back the later responses to the
  # same message, which never showed anywhere, and its page said nothing
  # waited on it (2026-10-04 review).
  test "a blocked response says the later responses to its message wait behind it" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please acknowledge this twice."},
               event_kind: :message,
               event_ref: "Ev-held-reaction",
               message_ref: "1787832001.000300",
               occurred_at: @now,
               revision: 1,
               thread_ref: "1787832000.000100",
               workspace_ref: "THELDREACTION"
             })

    assert {:ok, %{entry: entry, status: :recorded}} = Inbox.record(input, execution_mode: :live)

    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               now: @now,
               continuation_window: 30 * 60,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8,
               lease_ref: nil
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "messages" => nil,
               "reactions" => ["eyes", "white_check_mark"],
               "relation" => "unrelated",
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "Acknowledge the source item without starting work.",
               "work_class" => nil
             })

    assert {:ok, _applied} = Admission.commit(context, decision, "decision:held-reaction")
    assert {:ok, claim} = RoutingResponseCustody.claim_next("delivery:reaction:held", 60)

    assert {:ok, _blocked} =
             RoutingResponseCustody.block(
               claim.response.delivery_ref,
               claim.lease_ref,
               "slack_reaction_rejected",
               "reaction refused"
             )

    assert {:ok, failures} = FailureProjection.list(%{})
    assert %{held: 1} = row = Enum.find(failures, &(&1.ref == claim.response.delivery_ref))

    words = inspect(FailureExplanation.explain(row))
    assert words =~ "One later response to the same message waits behind it"
    refute words =~ "Nothing else waits on it."
  end

  # A routing session started ahead of time and retired unused never served a
  # message. When its cleanup stops, the page must not tell the reader that a
  # message was read or that a request is behind it: nobody is.
  test "a stuck cleanup of a routing session no message used says nobody is waiting on it" do
    id = Ecto.UUID.generate()
    now = Repo.now!()

    session =
      Repo.insert!(%Session{
        cleanup_status: :active,
        coop_session_id: "coop-ready-stuck-#{id}",
        execution_kind: :admission,
        external_ref: ReadySessions.external_ref(id),
        generation: 1,
        id: id,
        inserted_at: now,
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        ready_state: :retired,
        updated_at: now
      })

    assert {:ok, claim} = RetentionCustody.claim_next("cleanup:ready-stuck", 60)
    assert claim.session.id == session.id

    assert {:ok, _blocked} =
             RetentionCustody.block(
               session.id,
               claim.lease_ref,
               "coop_protocol_error",
               "close refused"
             )

    assert {:ok, row} = FailureProjection.fetch("retention", session.external_ref)
    explanation = FailureExplanation.explain(row)

    assert explanation.lede =~
             "Nobody is waiting on it: Ryker started it ahead of time and no message used it."

    assert hd(explanation.happened) =~ "When Ryker stopped keeping it ready"
    assert hd(explanation.affects) =~ "Nobody is waiting on it."

    detail = row |> FailuresPage.detail() |> IO.iodata_to_binary()
    refute detail =~ "the message was already read"
    refute detail =~ "request"
  end

  # A learning session has no episode, and every retention row here was read
  # through an inner join on one. On 2026-09-18 three learning cleanups sat
  # blocked in the metrics while this page said nothing needed attention, and
  # no operator could open one to retry it.
  test "a blocked learning cleanup is listed and can be opened for retry" do
    assert {:ok, run} =
             Learning.prepare(Enum.map(LearningFixtures.inputs!(), & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("a", 64)
             })

    assert {:ok, _session} = LearningFleetSession.ensure(run)
    remote_id = "coop-learning-blocked-#{System.unique_integer([:positive])}"
    assert {:ok, session} = LearningFleetSession.bind(run, remote_id)

    run
    |> Ecto.Changeset.change(
      remote_stopped_at: DateTime.utc_now(),
      stop_receipt: %{"kind" => "terminal_turn", "state" => "completed"}
    )
    |> Repo.update!()

    assert {:ok, claim} = RetentionCustody.claim_next("cleanup:learning-blocked", 60)
    assert claim.session.id == session.id

    assert {:ok, _blocked} =
             RetentionCustody.block(
               session.id,
               claim.lease_ref,
               "coop_protocol_error",
               "close refused"
             )

    assert {:ok, failures} = FailureProjection.list(%{})
    assert %{} = row = Enum.find(failures, &(&1.ref == session.external_ref))
    assert row.kind == "retention"
    assert row.action == :rearm

    html = [row] |> FailuresPage.list() |> IO.iodata_to_binary()
    assert html =~ "Background learning"
    assert html =~ "Closing a worker session stopped"

    assert {:ok, %{kind: "retention", action: :rearm} = exact} =
             FailureProjection.fetch("retention", session.external_ref)

    detail = exact |> FailuresPage.detail() |> IO.iodata_to_binary()
    assert detail =~ "/actions/retention/"
    refute detail =~ "/timeline/"

    # The Learning page reads learning sessions through an outer join, so it
    # can offer this resume. The Working copies page lists repository
    # checkouts only, and a learning session holds none.
    assert %{action: :rearm, execution_kind: :learning} =
             Enum.find(WorkspaceProjection.learning_sessions(), &(&1.ref == session.external_ref))

    copies = WorkspaceProjection.copies(%{})
    refute Enum.any?(copies.current ++ copies.removed.items, &(&1.ref == session.external_ref))
  end

  # Learning that only a person could restart was listed only on the Learning
  # page: a conversation that had stopped being learned said nothing here.
  # One still waiting on its worker moves on by itself and stays off the page.
  test "learning only a person can restart is listed, and learning that restarts itself is not" do
    assert {:ok, run} =
             Learning.prepare(Enum.map(LearningFixtures.inputs!(), & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("c", 64)
             })

    batch =
      Repo.insert!(%LearningBatch{
        id: Ecto.UUID.generate(),
        scope_key: "failures-learning-#{System.unique_integer([:positive])}",
        transport: "control_plane",
        conversation_ref: "control-plane:lab:failures-learning",
        execution_mode: :live,
        policy: "recorded-read-only-policy",
        policy_digest: String.duplicate("c", 64),
        status: :deferred,
        input_count: 2,
        start_count: 3,
        next_attempt_at: DateTime.add(DateTime.utc_now(), 3_600),
        error_code: "learning_remote_unresolved"
      })

    run =
      run
      |> Ecto.Changeset.change(
        batch_id: batch.id,
        started_at: DateTime.utc_now(),
        status: :rejected,
        error_code: "learning_remote_unresolved"
      )
      |> Repo.update!()

    assert {:ok, failures} = FailureProjection.list(%{})
    refute Enum.any?(failures, &(&1.kind == "learning"))

    # Its worker confirmed the stop and every start is used: nothing moves it now.
    run
    |> Ecto.Changeset.change(
      remote_stopped_at: DateTime.utc_now(),
      stop_receipt: %{"kind" => "terminal_turn", "state" => "failed"}
    )
    |> Repo.update!()

    batch |> Ecto.Changeset.change(error_code: "learning_retry_exhausted") |> Repo.update!()

    assert {:ok, failures} = FailureProjection.list(%{})
    assert %{kind: "learning", action: nil} = row = Enum.find(failures, &(&1.ref == batch.id))

    explained = FailureExplanation.explain(row)
    path = "/memory/learning?batch=#{batch.id}"
    assert %{href: ^path} = step = first_step(explained)
    assert (step[:link] || step.label) == "Open its attempts"

    assert "Only learning: replies are unaffected, and newer messages are learned as usual." in explained.affects

    html = [row] |> FailuresPage.list() |> IO.iodata_to_binary()
    assert html =~ "Background learning"
    assert html =~ "Learning from a conversation stopped"

    assert {:ok, %{kind: "learning"} = exact} = FailureProjection.fetch("learning", batch.id)
    detail = exact |> FailuresPage.detail() |> IO.iodata_to_binary()
    assert detail =~ "Grant one more start"
    assert detail =~ path
  end

  # A button update that stopped listed "Source U0BHTNFCW6S ·
  # ryker_start_engineering_task" in its technical details: the person who
  # pressed it only as a raw Slack ID (Andrew, 2026-09-26: always the name,
  # with a link to Slack).
  test "the person who pressed a button reads as a linked name in a stopped update's details" do
    click = %Interaction{
      action_id: "ryker_start_engineering_task",
      action_value: "record:task_offer:abc123",
      actor_ref: "U0BHTNFCW6S",
      channel_ref: "C456",
      event_ref: "interaction:pressed-by",
      message_ref: "1787832001.000200",
      occurred_at: ~U[2026-09-26 12:00:00.000000Z],
      thread_ref: "1787832000.000100",
      workspace_ref: "T0123456789"
    }

    assert {:ok, %{audit: audit}} = InteractionAudits.record(click, :confirmed)

    audit |> Ecto.Changeset.change(repaint_status: :blocked, attempt_count: 8) |> Repo.update!()

    assert {:ok, row} = FailureProjection.fetch("slack_interaction", click.event_ref)

    details =
      row
      |> FailuresPage.detail()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#failure-summary")

    assert details |> LazyHTML.query("a.kit-person") |> LazyHTML.text() == "Slack user"

    assert details |> LazyHTML.query("a.kit-person") |> LazyHTML.attribute("href") == [
             "https://slack.com/app_redirect?team=T0123456789&channel=U0BHTNFCW6S"
           ]

    refute LazyHTML.text(details) =~ "U0BHTNFCW6S"
  end

  test "learning stopped by a topic that lost its sources points to relearning it" do
    # QA, 2026-09-25, batch 96368bd7: a learned topic's own messages were gone,
    # so every attempt stopped on it, and Failures sent the reader to "Grant
    # one more start", which ran again and stopped the same way. Relearning the
    # topic from messages that still exist is the step that moves it.
    [old, _current] = LearningFixtures.inputs!()

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

    topic = Repo.one!(ConversationKnowledge)
    KnowledgeFixtures.revoke!(old)

    batch =
      Repo.insert!(%LearningBatch{
        id: Ecto.UUID.generate(),
        scope_key: "failures-stale-topic-#{System.unique_integer([:positive])}",
        transport: old.destination_transport,
        conversation_ref: old.destination_conversation_ref,
        repository_ref: old.repository_ref,
        execution_mode: old.execution_mode,
        policy: "recorded-read-only-policy",
        policy_digest: String.duplicate("c", 64),
        status: :deferred,
        input_count: 2,
        start_count: 2,
        start_limit: 2,
        error_code: "knowledge_target_unavailable"
      })

    assert {:ok, row} = FailureProjection.fetch("learning", batch.id)
    explained = FailureExplanation.explain(row)
    relearn = ConversationMemory.topic_path(topic.id) <> "#relearn"

    assert explained.outlook == :fix_first
    assert %{href: ^relearn} = step = first_step(explained)
    assert (step[:link] || step.label) == "Relearn the topic"

    detail = row |> FailuresPage.detail() |> IO.iodata_to_binary()
    assert detail =~ relearn
    refute detail =~ "Grant one more start"
  end

  test "an unresolved learning worker reports the scheduled retry instead of being in use" do
    assert {:ok, run} =
             Learning.prepare(Enum.map(LearningFixtures.inputs!(), & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("b", 64)
             })

    assert {:ok, session} = LearningFleetSession.ensure(run)
    retry_at = ~U[2026-08-28 13:00:00.000000Z]

    batch =
      Repo.insert!(%LearningBatch{
        id: Ecto.UUID.generate(),
        scope_key: "workspace-learning-retry-#{System.unique_integer([:positive])}",
        transport: "lab",
        conversation_ref: "conversation:workspace-learning-retry",
        execution_mode: :live,
        policy: "recorded-read-only-policy",
        policy_digest: String.duplicate("b", 64),
        status: :deferred,
        input_count: 1,
        next_attempt_at: retry_at,
        error_code: "learning_remote_unresolved"
      })

    run
    |> Ecto.Changeset.change(
      batch_id: batch.id,
      status: :rejected,
      reconcile_attempt_count: 4,
      error_code: "learning_remote_unresolved"
    )
    |> Repo.update!()

    workspace =
      Enum.find(WorkspaceProjection.learning_sessions(), &(&1.ref == session.external_ref))

    # The Learning page words this state; see memory_page_test.exs.
    assert workspace.learning_state == :retry_scheduled
    assert workspace.learning_retry_at == retry_at
  end

  test "a busy holder can save its existing result without a new runtime slot" do
    session = blocked_learning_cleanup!("coop_protocol_error") |> WorkerJob.pin!()
    worker = place_on_worker!(session)

    worker
    |> Ecto.Changeset.change(
      state: :busy,
      capacity: %{
        "session_slots_free" => 0,
        "turn_slots_free" => 0,
        "workspace_slots_free" => 0,
        "state" => "busy"
      }
    )
    |> Repo.update!()

    assert {:ok, %{worker: projected}} =
             FailureProjection.fetch("retention", session.external_ref)

    assert %{reporting: true, job_valid: true, setup_current: true, free_slot: false} = projected

    row = %{
      kind: "work",
      ref: "episode:one",
      episode_id: Ecto.UUID.generate(),
      episode_ref: "episode:one",
      action: :retry,
      attempt_count: 1,
      status: :blocked,
      summary: "coop_session_replacement_required",
      updated_at: nil,
      worker: projected,
      work_recovery: %{kind: :completion, action: :retry}
    }

    assert FailureExplanation.explain(row).outlook == :ready

    for changed <- [%{projected | job_valid: false}, %{projected | setup_current: false}] do
      explanation = FailureExplanation.explain(%{row | worker: changed})
      assert explanation.outlook == :stuck
      refute inspect(explanation) =~ "policy version"
    end
  end

  # Found reading Work cancellation on 2026-09-24: a stop whose worker stopped
  # reporting was deferred once a minute forever and listed nowhere, while its
  # task card read "stopping" and its request waited behind it. A stop still
  # unfinished after eight attempts is listed with what would let it finish,
  # and it leaves the page by itself once it does.
  test "a stop that cannot reach its worker is listed with what would let it finish" do
    work = stopping_turn!("unreported-stop")
    worker = place_on_worker!(work.session)

    worker
    |> Ecto.Changeset.change(last_seen_at: DateTime.add(DateTime.utc_now(), -600, :second))
    |> Repo.update!()

    address = work.episode.id

    assert {:ok, failures} = FailureProjection.list(%{})

    assert %{kind: "stopping", action: nil, worker: %{reporting: false}} =
             Enum.find(failures, &(&1.ref == work.episode.key and &1.kind == "stopping"))

    row = failure_row("stopping", address)
    assert LazyHTML.query(row, ".state-word") |> LazyHTML.text() == "Fix needed first"
    assert LazyHTML.text(row) =~ "#{worker.id} is not reporting"
    assert Enum.empty?(LazyHTML.query(row, "form[action^='/actions/']"))

    assert {:ok, %{kind: "stopping"}} = FailureProjection.fetch("stopping", work.episode.key)

    # The row's own page opens; a listed kind that answered 404 to its link
    # is how publications were unreachable in production.
    detail = page(["failures", "stopping", address])
    assert detail.status == 200
    assert detail.body =~ "Bring worker #{worker.id} back"

    # The worker answered: the run stopped, and the stop leaves the page.
    assert {:ok, claim} = Custody.claim_next("worker:unreported-stop:settle", 60, :work)
    assert claim.turn.id == work.turn.id

    assert {:ok, receipt} =
             Cancellation.terminal_receipt(
               work.session.coop_session_id,
               work.turn.coop_turn_id,
               "cancelled",
               nil,
               "closed",
               nil
             )

    assert {:ok, _settled} =
             Custody.settle_cancellation(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               claim.lease_ref,
               receipt
             )

    assert {:ok, failures} = FailureProjection.list(%{})
    refute Enum.any?(failures, &(&1.kind == "stopping"))
    assert FailureProjection.fetch("stopping", work.episode.key) == :not_found
  end

  # Every stopped task read "work_execution_blocked" on the Failures page: the
  # dispatcher saves its reason inside the detail, which must never be shown.
  test "a stopped task names the step it stopped on, never the saved term" do
    blocked = %Turn{last_error_code: "work_execution_blocked"}

    for {detail, code} <- [
          {~S|work_retry_exhausted: {:work_retry_exhausted, {:coop_unavailable, "private host"}}|,
           "work_retry_exhausted:coop_unavailable"},
          {~S|coop_worker_capacity_unavailable: {:coop_worker_capacity_unavailable, "8faf8d81"}|,
           "coop_worker_capacity_unavailable"},
          # A person's Stop saves its own code; its words alone name no stop.
          {"The operator stopped the current run. Reply in the same thread to continue this work.",
           nil},
          # A run paused mid-flight for its incident room read as a stop with
          # no known cause, so the page could not tell a room that will come
          # back from one Slack deleted for good.
          {"destination_paused:incident-room:one:channel", "destination_paused"},
          {"a sentence with no code", nil}
        ] do
      assert FailureProjection.stop_code(%{blocked | last_error_detail: detail}) == code
    end

    # A stopped completion saves its own code, and that is the code; so does
    # a person's Stop (`Cancellation.new_stop/2`).
    assert FailureProjection.stop_code(%Turn{last_error_code: "coop_unavailable"}) ==
             "coop_unavailable"

    assert FailureProjection.stop_code(%Turn{last_error_code: "operator_stop"}) == "operator_stop"
  end

  test "Slack's own refusal is named only from a closed list of its words" do
    assert FailureProjection.provider_error(
             inspect({:delivery_reconciliation_failed, {:slack_api_error, "not_in_channel"}})
           ) == "not_in_channel"

    assert FailureProjection.provider_error(inspect({:slack_api_error, "token_revoked"})) ==
             "token_revoked"

    # A word outside the list could be anything a provider put there.
    assert FailureProjection.provider_error(inspect({:slack_api_error, "some_private_word"})) ==
             nil

    assert FailureProjection.provider_error(nil) == nil
  end

  # Andrew, 2026-10-03, of a failure page whose other choice was "Leave it": "how do I hide the
  # alert if I want to leave it and not be annoyed by having a failure pending forever?" Leaving
  # one takes it off Failures, and off every count that reads the list, until it fails some other
  # way. It came back on Ryker's next automatic retry, which only moved its time: stopping runs,
  # publications and approval watches retry every minute (2026-10-04 review).
  test "a failure left as it is stays off Failures while it fails the same way" do
    session = blocked_learning_cleanup!("coop_protocol_error")
    ref = session.external_ref

    assert {:ok, %{left_at: nil, updated_at: changed_at}} =
             FailureProjection.fetch("retention", ref)

    assert listed?(ref)

    assert {:ok, _left} = Actions.callbacks().leave_failure.("retention", ref, nil)

    refute listed?(ref)

    # Its own page still opens, and has nothing left to leave.
    assert {:ok, %{left_at: %DateTime{}} = left} = FailureProjection.fetch("retention", ref)
    refute Enum.any?(FailureExplanation.explain(left).options, &(&1.label == "Leave it"))

    # Tried again, it failed the same way.
    Repo.update_all(from(saved in Session, where: saved.id == ^session.id),
      set: [updated_at: DateTime.add(changed_at, 1, :second)]
    )

    refute listed?(ref)

    Repo.update_all(from(saved in Session, where: saved.id == ^session.id),
      set: [
        cleanup_last_error_code: "coop_session_unavailable",
        updated_at: DateTime.add(changed_at, 2, :second)
      ]
    )

    assert listed?(ref)
    assert {:ok, %{left_at: nil}} = FailureProjection.fetch("retention", ref)
  end

  # Each kind was read a page deep before the ones people left were dropped, so a hundred and
  # one left failures of a kind hid an older open one on every page, in the weekly report and in
  # the status line (2026-10-04 review).
  test "failures people left never crowd an open one of the same kind off the list" do
    [open | newer] = Enum.map(1..102, &blocked_admission!/1)

    for entry <- newer do
      assert {:ok, _left} = Actions.callbacks().leave_failure.("admission", Inbox.ref(entry), nil)
    end

    assert {:ok, failures} = FailureProjection.list(%{})
    assert Enum.map(failures, & &1.ref) == [Inbox.ref(open)]
  end

  defp blocked_admission!(index) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Message #{index}"},
               event_kind: :message,
               event_ref: "Ev-crowded-#{index}",
               message_ref: "1787833000.#{String.pad_leading("#{index}", 6, "0")}",
               occurred_at: DateTime.add(@now, index, :second),
               revision: 1,
               thread_ref: nil,
               workspace_ref: "TCROWDEDFAILURES"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input, execution_mode: :live)
    assert {:ok, %{lease_ref: lease}} = Inbox.claim_next("crowded:#{index}", @now, 60)
    assert {:ok, _blocked} = Inbox.block(Inbox.ref(entry), lease, "blocked", "stopped")

    Repo.update_all(from(saved in Ryker.Ingress.Inbox.Entry, where: saved.id == ^entry.id),
      set: [updated_at: DateTime.add(@now, index, :second)]
    )

    entry
  end

  defp listed?(ref) do
    assert {:ok, failures} = FailureProjection.list(%{})
    Enum.any?(failures, &(&1.ref == ref))
  end

  # The step a failure's page leads with.
  defp first_step(explained), do: Enum.find(explained.options, & &1[:recommended])

  defp blocked_learning_cleanup!(code) do
    assert {:ok, run} =
             Learning.prepare(Enum.map(LearningFixtures.inputs!(), & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("a", 64)
             })

    assert {:ok, _session} = LearningFleetSession.ensure(run)
    remote_id = "coop-learning-replaced-#{System.unique_integer([:positive])}"
    assert {:ok, session} = LearningFleetSession.bind(run, remote_id)

    run
    |> Ecto.Changeset.change(
      remote_stopped_at: DateTime.utc_now(),
      stop_receipt: %{"kind" => "terminal_turn", "state" => "completed"}
    )
    |> Repo.update!()

    assert {:ok, claim} = RetentionCustody.claim_next("cleanup:#{code}", 60)
    assert claim.session.id == session.id
    assert {:ok, _blocked} = RetentionCustody.block(session.id, claim.lease_ref, code, "refused")
    Repo.get!(Session, session.id)
  end

  # A bound run someone asked to stop, which has not stopped after eight tries.
  defp stopping_turn!(suffix) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "failures-stop:#{suffix}:#{id}",
        native_input_id: "source:failures-stop:#{suffix}:#{id}",
        occurred_at: @now,
        turn_ref: "turn:failures-stop:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             WorkSessions.pin_episode(id, "recorded-work-policy", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60, :work)

    assert {:ok, submission} =
             Submission.new(
               %{"request" => suffix},
               "Handle the request.",
               %{"type" => "object"},
               "work-final-live-v3"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(id, command.turn_ref, claim.lease_ref, submission)

    assert {:ok, session} =
             Custody.bind_session(
               id,
               command.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-failures-stop:#{id}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               id,
               command.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-failures-stop-turn:#{id}"
             )

    assert {:ok, %{status: :pending}} =
             Custody.request_stop(
               id,
               claim.episode.key,
               command.turn_ref,
               "control:#{suffix}",
               "The operator stopped the current run."
             )

    # Structural fixture: the durable record eight failed stop attempts leave.
    turn =
      Turn
      |> Repo.get!(turn.id)
      |> Ecto.Changeset.change(
        cancel_attempt_count: 8,
        last_error_code: "coop_worker_capacity_unavailable",
        last_error_detail: inspect({:coop_worker_capacity_unavailable, session.id})
      )
      |> Repo.update!()

    %{episode: claim.episode, session: session, turn: turn}
  end

  # Structural fixture: the worker that held the session, reporting now, and
  # the placement that says so.
  defp place_on_worker!(session) do
    worker_id = "failures-worker-#{System.unique_integer([:positive])}"
    certificate = digest(worker_id)
    assert {:ok, worker} = CoopWorkers.authorize(worker_id, "failures", certificate)
    now = DateTime.utc_now()

    worker =
      worker
      |> Ecto.Changeset.change(
        capacity: %{
          "session_slots_free" => 1,
          "state" => "eligible",
          "turn_slots_free" => 1,
          "workspace_slots_free" => 1
        },
        clock_at: now,
        last_seen_at: now,
        protocol_version: "2",
        sandbox_digest: @sandbox,
        state: :eligible
      )
      |> Repo.update!()

    requirements = %{"sandbox_digest" => @sandbox, "workspace_ref" => "failures"}

    Repo.insert!(%Placement{
      episode_id: session.episode_id,
      generation: 1,
      id: Ecto.UUID.generate(),
      inserted_at: now,
      lease_expires_at: DateTime.add(now, -60, :second),
      lease_ref: "placement-lease:#{session.id}",
      requirements: requirements,
      requirements_fingerprint: CanonicalJSON.digest(requirements),
      session_id: session.id,
      state: :replaced,
      updated_at: now,
      worker_id: worker_id
    })

    worker
  end

  defp page(segments), do: Pages.page(segments, %{}, %{projection: Projection.callbacks()})

  defp failure_row(kind, address) do
    page = page(["failures"])
    assert page.status == 200

    page.body
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("article.failure-row")
    |> Enum.find(fn article ->
      LazyHTML.query(article, ".entity-name a") |> LazyHTML.attribute("href") ==
        ["/failures/#{kind}/#{address}"]
    end)
    |> tap(&assert(&1, "the #{kind} failure is not listed"))
  end
end
