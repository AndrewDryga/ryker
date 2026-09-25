defmodule Ryker.ControlPlane.FailureProjectionTest do
  use Ryker.DataCase, async: true

  # Admission context reads under REPEATABLE READ; the fixture keeps its own
  # workspace so the conversation lock never waits on another suite.
  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission
  alias Ryker.Admission.Decision

  alias Ryker.CanonicalJSON

  alias Ryker.ControlPlane.{
    FailureExplanation,
    FailureProjection,
    FailuresPage,
    Pages,
    Projection,
    WorkingCopiesPage,
    WorkspaceProjection
  }

  alias Ryker.CoopFleet.ControlPlane, as: FleetControlPlane
  alias Ryker.CoopFleet.{Placement, WorkerLifecycle}

  alias Ryker.Delivery.ReactionCustody
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Learning.Batch, as: LearningBatch
  alias Ryker.Learning.FleetSession, as: LearningFleetSession
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.State.Learning
  alias Ryker.Work.{Cancellation, Custody, Session, Submission, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @sandbox String.duplicate("d", 64)

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
               "reaction" => %{"emoji_name" => "eyes"},
               "relation" => "unrelated",
               "repository_source" => nil,
               "reason" => "Acknowledge the source item without starting work.",
               "work_class" => nil
             })

    assert {:ok, _applied} = Admission.commit(context, decision, "decision:blocked-reaction")
    assert {:ok, claim} = ReactionCustody.claim_next("delivery:reaction:blocked", 60)

    assert {:ok, _blocked} =
             ReactionCustody.block(
               claim.reaction.delivery_ref,
               claim.lease_ref,
               "slack_reaction_rejected",
               "private reaction diagnostic"
             )

    assert {:ok, failures} = Projection.failures(%{})
    assert %{} = row = Enum.find(failures, &(&1.ref == claim.reaction.delivery_ref))
    assert row.kind == "delivery"
    assert row.destination == "slack:TBLOCKEDREACTION:C456 / 1787832000.000100"
    assert row.source == "slack:TBLOCKEDREACTION · Ev-blocked-reaction"
    refute inspect(row) =~ "private reaction diagnostic"
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

    assert {:ok, failures} = Projection.failures(%{})
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

    # Every retained worker session is read through the same outer join, so
    # the Learning page can offer this resume. The Working copies page lists
    # repository checkouts only, and a learning session holds none.
    assert %{action: :rearm, execution_kind: :learning} =
             workspace =
             Enum.find(WorkspaceProjection.list(%{}), &(&1.ref == session.external_ref))

    page =
      WorkingCopiesPage.html(%{
        rows: [workspace],
        storage: %{budget: %{}, preview: [], workers: []},
        now: nil
      })

    refute page =~ "Background learning"
    refute page =~ "/actions/retention/"
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

    assert {:ok, failures} = Projection.failures(%{})
    refute Enum.any?(failures, &(&1.kind == "learning"))

    # Its worker confirmed the stop and every start is used: nothing moves it now.
    run
    |> Ecto.Changeset.change(
      remote_stopped_at: DateTime.utc_now(),
      stop_receipt: %{"kind" => "terminal_turn", "state" => "failed"}
    )
    |> Repo.update!()

    batch |> Ecto.Changeset.change(error_code: "learning_retry_exhausted") |> Repo.update!()

    assert {:ok, failures} = Projection.failures(%{})
    assert %{kind: "learning", action: nil} = row = Enum.find(failures, &(&1.ref == batch.id))

    explained = FailureExplanation.explain(row)
    path = "/memory/learning?batch=#{batch.id}"
    assert explained.button == %{label: "Open its attempts", href: path}

    assert "Ryker is not learning from these messages; replies are unaffected." in explained.affects

    html = [row] |> FailuresPage.list() |> IO.iodata_to_binary()
    assert html =~ "Background learning"
    assert html =~ "Learning from a conversation stopped"

    assert {:ok, %{kind: "learning"} = exact} = FailureProjection.fetch("learning", batch.id)
    detail = exact |> FailuresPage.detail() |> IO.iodata_to_binary()
    assert detail =~ "Grant one more start"
    assert detail =~ path
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
      WorkspaceProjection.list(%{})
      |> Enum.find(&(&1.ref == session.external_ref))

    # The Learning page words this state; see memory_page_test.exs.
    assert workspace.learning_state == :retry_scheduled
    assert workspace.learning_retry_at == retry_at
  end

  # Andrew opened /failures on 2026-09-24 to two "Working-copy cleanup
  # stopped" cards over a big "Resume cleanup" button. Their worker had been
  # updated to a newer ryker-chat policy since the sessions started, and
  # placement refused to clean up a session under any version but its own. The
  # next day's fix sends cleanup to the worker that holds the session whatever
  # it runs, so these older blocks are exactly the ones a retry now resolves;
  # a page still saying "Retry won't help" would hide the one button that works.
  test "a cleanup its worker could not take back is offered as the retry that now works" do
    session = blocked_learning_cleanup!("coop_session_replacement_required")
    worker = place_on_worker!(session, %{session.policy => String.duplicate("c", 64)})
    encoded = URI.encode(session.external_ref, &URI.char_unreserved?/1)

    assert {:ok, failures} = Projection.failures(%{})

    assert %{worker: %{reporting: true, policy_current: false}} =
             Enum.find(failures, &(&1.ref == session.external_ref))

    row = failure_row("retention", encoded)
    assert LazyHTML.query(row, ".state-word") |> LazyHTML.text() == "Retry should work"
    assert LazyHTML.text(row) =~ "still holds this session"

    assert LazyHTML.query(row, "form") |> LazyHTML.attribute("action") == [
             "/actions/retention/#{encoded}/rearm"
           ]

    detail = page(["failures", "retention", encoded])
    assert detail.status == 200
    assert detail.body =~ "Should work"
    refute detail.body =~ "Will fail"

    # A worker removed from Ryker holds nothing Ryker can reach: the retry
    # records the session as unreachable instead of waiting on it.
    assert {:ok, %{status: :revoked}} = WorkerLifecycle.revoke(worker.id, "operator:test")

    row = failure_row("retention", encoded)
    assert LazyHTML.query(row, ".state-word") |> LazyHTML.text() == "Retry should work"
    assert LazyHTML.text(row) =~ "was removed from Ryker"
  end

  # Found reading Work cancellation on 2026-09-24: a stop whose worker stopped
  # reporting was deferred once a minute forever and listed nowhere, while its
  # task card read "stopping" and its request waited behind it. A stop still
  # unfinished after eight attempts is listed with what would let it finish,
  # and it leaves the page by itself once it does.
  test "a stop that cannot reach its worker is listed with what would let it finish" do
    work = stopping_turn!("unreported-stop")
    worker = place_on_worker!(work.session, %{work.session.policy => work.session.policy_digest})

    worker
    |> Ecto.Changeset.change(last_seen_at: DateTime.add(DateTime.utc_now(), -600, :second))
    |> Repo.update!()

    encoded = URI.encode(work.episode.key, &URI.char_unreserved?/1)

    assert {:ok, failures} = Projection.failures(%{})

    assert %{kind: "stopping", action: nil, worker: %{reporting: false}} =
             Enum.find(failures, &(&1.ref == work.episode.key and &1.kind == "stopping"))

    row = failure_row("stopping", encoded)
    assert LazyHTML.query(row, ".state-word") |> LazyHTML.text() == "Fix needed first"
    assert LazyHTML.text(row) =~ "#{worker.id} is not reporting"
    assert Enum.empty?(LazyHTML.query(row, "form[action^='/actions/']"))

    assert {:ok, %{kind: "stopping"}} = FailureProjection.fetch("stopping", work.episode.key)

    # The row's own page opens; a listed kind that answered 404 to its link
    # is how publications were unreachable in production.
    detail = page(["failures", "stopping", encoded])
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

    assert {:ok, failures} = Projection.failures(%{})
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
          {"The operator stopped the current run. Reply in the same thread to continue this work. Control: control:1.",
           "operator_stop"},
          # A run paused mid-flight for its incident room read as a stop with
          # no known cause, so the page could not tell a room that will come
          # back from one Slack deleted for good.
          {"destination_paused:incident-room:one:channel", "destination_paused"},
          {"a sentence with no code", nil}
        ] do
      assert FailureProjection.stop_code(%{blocked | last_error_detail: detail}) == code
    end

    # A stopped completion saves its own code, and that is the code.
    assert FailureProjection.stop_code(%Turn{last_error_code: "coop_unavailable"}) ==
             "coop_unavailable"
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
             Custody.pin_episode(id, "recorded-work-policy", String.duplicate("a", 64))

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
  defp place_on_worker!(session, policy_digests) do
    worker_id = "failures-worker-#{System.unique_integer([:positive])}"
    certificate = :crypto.hash(:sha256, worker_id) |> Base.encode16(case: :lower)
    assert {:ok, worker} = FleetControlPlane.authorize_worker(worker_id, "failures", certificate)
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
        policy_digests: policy_digests,
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

  defp failure_row(kind, encoded_ref) do
    page = page(["failures"])
    assert page.status == 200

    page.body
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("article.failure-row")
    |> Enum.find(fn article ->
      LazyHTML.query(article, ".entity-name a") |> LazyHTML.attribute("href") ==
        ["/failures/#{kind}/#{encoded_ref}"]
    end)
    |> tap(&assert(&1, "the #{kind} failure is not listed"))
  end
end
