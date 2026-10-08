defmodule Ryker.Emisar.ApprovalsTest do
  use Ryker.DataCase, async: false
  alias Ryker.ControlPlane.{FailureExplanation, FailureProjection, Pages, Projection}
  alias Ryker.{Credentials, IntegrationSetup}
  alias Ryker.Emisar.{Approval, ApprovalDispatcher, Approvals, Connections, RunState}
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Inspectors
  alias Ryker.Operator.Emisar, as: EmisarOperator
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Settings
  alias Ryker.Waits.{EventSubscription, EventSubscriptions, EventWaits}
  alias Ryker.Work.Custody

  @actor "control-plane:local"
  @policy_digest String.duplicate("a", 64)
  @connection_ref "production"
  @environment_ref "production"

  setup do
    configure_emisar!()
    :ok
  end

  defmodule UnusedAPI do
    @behaviour Ryker.Emisar.API

    @impl true
    def wait_for_run(_client, _run_id, _wait_seconds), do: {:error, :not_expected}
  end

  defmodule UnusedPresenter do
    def publish(_approval, _state, _presentation), do: {:error, :not_expected}
    def permanent?(_reason), do: false
  end

  # Emisar as it answers a replacement key (`Ryker.TestSupport.EmisarMCP`).
  defmodule SameAccountRequester do
    alias Ryker.TestSupport.EmisarMCP

    def request(client, :post, "/mcp", body, _headers) do
      {:ok, token} = client.token_provider.()
      EmisarMCP.answer(body, token)
    end
  end

  # The Timeline and Failures redraw when an approval watch is registered or
  # observed. Until 2026-10-08 no test held a watch to announcing itself.
  test "an approval watch registered and observed reaches the pages that show it" do
    :ok = Approvals.subscribe_approvals()
    approval_wait!("announce")
    %Approval{id: approval_id} = Inspectors.emisar_approval(@connection_ref, "apr-announce")
    assert_receive {:emisar_approval_updated, ^approval_id}

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok, %{status: :monitoring}} =
             Approvals.observe(
               @connection_ref,
               "apr-announce",
               lease_ref,
               run_state("announce", "running"),
               5
             )

    assert_receive {:emisar_approval_updated, ^approval_id}
  end

  test "registers the immutable approval atomically and claims it only after delivery starts the wait" do
    %{claim: claim, record: record} = approval_wait!("claim")
    record_id = record.id

    assert %Approval{
             action_id: "nomad.alloc_restart",
             record_id: ^record_id,
             remote_status: "pending_approval",
             request_id: "apr-claim",
             status: :monitoring
           } = Inspectors.emisar_approval(@connection_ref, "apr-claim")

    assert {:ok, %{approval: approval, lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert approval.episode_id == claim.episode.id
    assert approval.lease_owner == "approval-worker"

    assert {:ok, %{approval: observed, status: :monitoring}} =
             Approvals.observe(
               @connection_ref,
               "apr-claim",
               lease_ref,
               run_state("claim", "running"),
               5
             )

    assert observed.remote_status == "running"
    assert observed.failure_count == 0
    assert observed.lease_ref == nil
    assert %DateTime{} = observed.next_attempt_at
  end

  test "a terminal exact run resumes the same episode once without repeating the action" do
    %{claim: claim, record: record} = approval_wait!("terminal")

    # A person's reply never ends a wait only Emisar's decision may end.
    assert Records.user_resumable_wait?(record.ref, person_reply()) == false

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok,
            %{
              approval: %Approval{status: :resumed, remote_status: "success"},
              episode: resumed,
              record: %Record{status: :answered},
              status: :resumed
            }} =
             Approvals.observe(
               @connection_ref,
               "apr-terminal",
               lease_ref,
               run_state("terminal", "success"),
               5
             )

    assert resumed.id == claim.episode.id
    assert resumed.state == :working
    assert resumed.owner_kind == :turn
    assert resumed.owner_ref =~ "turn:emisar-approval:"

    assert Approvals.claim_next(@connection_ref, "second-worker", 60) == {:ok, nil}

    events = Inspectors.episode_events(claim.episode.key)

    assert Enum.map(events, & &1.kind) == [
             :input_admitted,
             :event_wait_started,
             :input_admitted,
             :wait_resumed
           ]

    terminal = Enum.find(events, &(&1.kind == :input_admitted and &1.sequence == 3))
    content = get_in(terminal.payload, ["payload", "content"])

    assert content["approval_request_id"] == "apr-terminal"
    assert content["required_next_operation"] == "wait_for_run"
    assert content["run_id"] == "run-terminal"
    assert content["status"] == "success"
    assert content["verification"] =~ "Never call run_action"
  end

  # 2026-10-08: tasks ran two Emisar actions that each needed approval. The
  # watcher only looked at the approval its task waited on, so the other was
  # never polled, and settling it could not have resumed the task, which
  # waited on its sibling. Every pending approval of a waiting task is
  # watched now, and the first to settle resumes the task.
  test "an approval that settles while its task waits on another approval resumes the task" do
    %{claim: claim, record: first} = registered!("sibling-first")

    assert {:ok, second} =
             Records.create(
               Records.token(claim.turn),
               "op-sibling-second",
               "emisar_approval",
               approval_payload("sibling-second")
             )

    assert {:ok, %{episode: %{owner_ref: owner_ref}}} = wait_on!(claim, first)
    assert owner_ref == first.ref

    leases =
      Map.new(["approval-worker-one", "approval-worker-two"], fn worker ->
        assert {:ok, %{approval: approval, lease_ref: lease_ref}} =
                 Approvals.claim_next(@connection_ref, worker, 60)

        {approval.request_id, lease_ref}
      end)

    assert Map.keys(leases) == ["apr-sibling-first", "apr-sibling-second"]

    assert {:ok,
            %{
              episode: resumed,
              record: %Record{status: :answered, ref: answered_ref},
              status: :resumed
            }} =
             Approvals.observe(
               @connection_ref,
               "apr-sibling-second",
               leases["apr-sibling-second"],
               run_state("sibling-second", "success"),
               5
             )

    assert answered_ref == second.ref
    assert resumed.state == :working

    # The sibling stays pending, for the task to wait on again.
    assert Repo.get!(Record, first.id).status == :open
  end

  # A task may ask a question while an approval it asked for is pending, and
  # the question owns the wait (`Ryker.Work.Validator`). Nothing watched the
  # approval while the question was open, so one that expired in the meantime
  # left the task holding a wait it could never take again. The outcome now
  # waits in the task's queue and reaches it with the answer.
  test "an approval that settles while its task waits on a question reaches the task with the answer" do
    %{claim: claim, record: approval} = registered!("beside-question")

    assert {:ok, question} =
             Records.create(Records.token(claim.turn), "question-beside", "input_request", %{
               "choices" => ["eu-west-1", "us-east-1"],
               "question" => "Which region should I scale while the restart waits?"
             })

    assert {:ok, %{episode: %{state: :waiting_for_input}}} =
             Episodes.apply(%Command.StartWait{
               deadline_at: nil,
               episode_key: claim.episode.key,
               expected_turn_ref: claim.turn.turn_ref,
               kind: :input,
               occurred_at: ~U[2026-08-29 12:00:01.000000Z],
               wait_ref: question.ref
             })

    assert {:ok, %{approval: %{request_id: "apr-beside-question"}, lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok, %{episode: waiting, record: %Record{status: :answered, ref: answered_ref}}} =
             Approvals.observe(
               @connection_ref,
               "apr-beside-question",
               lease_ref,
               run_state("beside-question", "cancelled"),
               5
             )

    assert answered_ref == approval.ref
    assert {waiting.state, waiting.owner_ref} == {:waiting_for_input, question.ref}
    assert [outcome_ref] = waiting.queued_input_refs

    answer =
      EpisodeFixtures.admit_input(%{
        episode_id: claim.episode.id,
        episode_key: claim.episode.key,
        native_input_id: "slack:event:Ev-region",
        occurred_at: ~U[2026-08-29 12:10:00.000000Z],
        payload: %{"text" => "eu-west-1"},
        turn_ref: "turn:answer-beside-question"
      })

    resume = %Command.ResumeWait{
      episode_key: claim.episode.key,
      expected_wait: %{kind: :input, ref: question.ref},
      occurred_at: ~U[2026-08-29 12:10:00.000000Z],
      resolution_ref: Command.dedupe_key(answer),
      turn_ref: "turn:answer-beside-question"
    }

    assert {:ok, {:ok, [_admitted, %{episode: resumed}]}} =
             Repo.transaction(fn -> Episodes.apply_batch_in_transaction([answer, resume]) end)

    assert resumed.state == :working

    assert Enum.sort(resumed.active_input_refs) ==
             Enum.sort([Command.dedupe_key(answer), outcome_ref])
  end

  # Approvals beside another wait are watched (above), but the Failures list
  # and its "Watch the approval again" button still asked whether each was
  # the one the task's wait named. One whose account stopped being watched
  # was not listed, and one Emisar refused could not be watched again.
  test "an approval beside another wait is listed when it stalls" do
    %{rider: rider} = beside_another_approval!("stalled-rider")

    assert {:ok, _snapshot} =
             IntegrationSetup.disable_emisar_monitoring(@connection_ref, "control-plane:local")

    assert %{stall: :monitoring_off} = failure("production/#{rider}")
  end

  test "an approval beside another wait can be watched again once Emisar refused it" do
    %{rider: rider} = beside_another_approval!("blocked-rider")

    lease_ref =
      Enum.find_value(1..2, fn attempt ->
        assert {:ok, %{approval: approval, lease_ref: lease_ref}} =
                 Approvals.claim_next(@connection_ref, "approval-worker-#{attempt}", 60)

        if approval.request_id == rider, do: lease_ref
      end)

    assert {:ok, %Approval{status: :blocked}} =
             Approvals.block(@connection_ref, rider, lease_ref, {:emisar_http_error, 403, "no"})

    assert %{action: :rearm} = failure("production/#{rider}")
    assert {:ok, %{status: :monitoring}} = EmisarOperator.rearm("production/#{rider}")
  end

  # The same tasks watched a Terraform run beside their approvals. A watch
  # keeps the episode's one subscription while a question owns the wait; an
  # approval owning it left the watch unsubscribed. Once subscribed, the sweep
  # took it for a wait its task had left and dismissed it: episode 01a11a2f's
  # watch went two minutes after its retry, 2026-10-08.
  test "a source watch beside a pending approval keeps its subscription and stays open" do
    %{claim: claim, record: approval} = registered!("beside-watch")
    watch = watch!(claim, "beside-watch")

    assert {:ok, %{episode: waiting}} = wait_on!(claim, approval)
    assert %EventSubscription{record_id: record_id, status: :active} = ensure!(waiting)
    assert record_id == watch.id

    assert {:ok, _count} = EventSubscriptions.reconcile()
    assert Repo.get!(Record, watch.id).status == :open
    assert Repo.get_by!(EventSubscription, record_id: watch.id).status == :active
  end

  # Episode 8e0de29c, 2026-10-08: a timer can own a task's wait beside its
  # approvals (`Ryker.Work.Validator`). An approval that settles resumes the
  # task through the timer, and the sweep then dismissed the timer, so the
  # task's next turn never saw it. It stays open, and a timer whose time came
  # meanwhile fires as soon as the task waits on it again.
  test "a timer an approval's outcome woke stays open and fires when its task waits on it again" do
    %{claim: claim, record: approval} = registered!("beside-timer")
    timer = timer!(claim, "beside-timer")

    assert {:ok, %{episode: waiting}} = wait_on!(claim, timer)
    assert %EventSubscription{status: :active} = ensure!(waiting)
    resumed = settle!("beside-timer", approval)

    assert {:ok, _count} = EventSubscriptions.reconcile()
    assert Repo.get!(Record, timer.id).status == :open

    assert %EventSubscription{status: :cancelled, last_observation: %{"kind" => "released"}} =
             Repo.get_by!(EventSubscription, record_id: timer.id)

    assert {:ok, %{episode: waiting}} = wait_again!(resumed, timer)
    assert %EventSubscription{status: :active, record_id: timer_id} = ensure!(waiting)
    assert timer_id == timer.id

    assert {:ok, %{record: %Record{status: :answered, ref: fired}}} = EventWaits.resume_due()
    assert fired == timer.ref
  end

  # A timer owning the wait needs the episode's one subscription, and a watch
  # beside it may hold it. Taking it failed on the index that keeps one per
  # episode; the watch gives it up, stays open, and takes it back once an
  # approval owns the wait again.
  test "a timer takes the subscription from a watch beside it, and the watch gets it back" do
    %{claim: claim, record: first} = registered!("watch-timer")
    watch = watch!(claim, "watch-timer")
    timer = timer!(claim, "watch-timer")

    assert {:ok, second} =
             Records.create(
               Records.token(claim.turn),
               "op-watch-timer-second",
               "emisar_approval",
               approval_payload("watch-timer-second")
             )

    assert {:ok, %{episode: waiting}} = wait_on!(claim, first)
    assert %EventSubscription{record_id: watch_id} = ensure!(waiting)
    assert watch_id == watch.id
    resumed = settle!("watch-timer", first)

    assert {:ok, %{episode: waiting}} = wait_again!(resumed, timer)
    assert %EventSubscription{record_id: timer_id, status: :active} = ensure!(waiting)
    assert timer_id == timer.id
    assert Repo.get!(Record, watch.id).status == :open
    assert Repo.get_by!(EventSubscription, record_id: watch.id).status == :cancelled

    assert {:ok, %{episode: resumed}} = EventWaits.resume_due()
    assert {:ok, %{episode: waiting}} = wait_again!(resumed, second)
    assert %EventSubscription{record_id: ^watch_id, status: :active} = ensure!(waiting)
  end

  test "identity mismatches block no episode transition and transient failures retain durable custody" do
    %{claim: claim} = approval_wait!("failure")

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    wrong = %{run_state("failure", "success") | action_id: "different.action"}

    assert Approvals.observe(@connection_ref, "apr-failure", lease_ref, wrong, 5) ==
             {:error, :emisar_approval_identity_mismatch}

    assert {:ok, deferred} =
             Approvals.defer(
               @connection_ref,
               "apr-failure",
               lease_ref,
               7,
               {:transport, :unavailable}
             )

    assert deferred.failure_count == 1
    assert deferred.last_error =~ "transport"
    assert deferred.lease_ref == nil
    assert %DateTime{} = deferred.next_attempt_at

    assert waiting = Inspectors.episode(claim.episode.key)
    assert waiting.state == :waiting_for_event

    assert Enum.map(Inspectors.episode_events(claim.episode.key), & &1.kind) == [
             :input_admitted,
             :event_wait_started
           ]
  end

  test "a blocked monitor is inspectable and can be rearmed without approving or repeating work" do
    %{claim: claim} = approval_wait!("operator")

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok, %Approval{status: :blocked}} =
             Approvals.block(
               @connection_ref,
               "apr-operator",
               lease_ref,
               {:emisar_http_error, 403, "forbidden"}
             )

    assert {:ok, blocked} = EmisarOperator.fetch("production/apr-operator")
    assert blocked.request_id == "apr-operator"
    assert blocked.run_id == "run-operator"
    assert blocked.last_error =~ "forbidden"

    assert {:ok, %{action: :rearm, ref: "production/apr-operator", status: :blocked}} =
             FailureProjection.emisar("production/apr-operator")

    assert {:ok, failures} = FailureProjection.list(%{})

    assert %{kind: "emisar", ref: "production/apr-operator"} =
             Enum.find(failures, &(&1.kind == "emisar"))

    assert {:ok, rearmed} = EmisarOperator.rearm("production/apr-operator")
    assert rearmed.status == :monitoring
    assert rearmed.failure_count == 0
    assert rearmed.last_error == nil

    assert {:ok, %{approval: claimed_again}} =
             Approvals.claim_next(@connection_ref, "approval-worker-after-fix", 60)

    assert claimed_again.request_id == "apr-operator"
    assert waiting = Inspectors.episode(claim.episode.key)
    assert waiting.state == :waiting_for_event

    assert EmisarOperator.rearm("production/apr-operator") ==
             {:error, :emisar_approval_not_blocked}

    assert EmisarOperator.fetch("production/missing") == {:error, :emisar_approval_not_found}
    assert EmisarOperator.failures(0) == {:error, {:invalid_emisar_approval_operator, :limit}}
  end

  # A stopped watch whose task was then closed could only stay blocked: "Watch
  # the approval again" was refused every time because nothing waited for it,
  # and the row sat on Failures for good under a button that could never work.
  test "an approval watch nothing waits for any more closes by itself, keeps its history and leaves Failures" do
    %{claim: claim} = approval_wait!("closed-task")

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok, %Approval{status: :blocked}} =
             Approvals.block(
               @connection_ref,
               "apr-closed-task",
               lease_ref,
               {:emisar_http_error, 403, "forbidden"}
             )

    assert %{kind: "emisar"} = failure("production/apr-closed-task")
    close_task!(claim.episode.key)

    # Nothing can continue from it, so it is not offered as a failure at all.
    assert failure("production/apr-closed-task") == nil
    assert FailureProjection.emisar("production/apr-closed-task") == :not_found
    refute failures_page() =~ "apr-closed-task"

    # The monitor closes it on its next idle pass, with the reason, and keeps it.
    assert ApprovalDispatcher.run_once(dispatcher()) == {:ok, {:closed, ["apr-closed-task"]}}

    closed = Inspectors.emisar_approval(@connection_ref, "apr-closed-task")
    assert closed.status == :closed
    assert closed.closed_reason == :wait_ended
    assert %DateTime{} = closed.closed_at
    assert closed.last_error =~ "403"
    assert {:ok, %{status: :closed}} = EmisarOperator.fetch("production/apr-closed-task")

    assert EmisarOperator.rearm("production/apr-closed-task") ==
             {:error, :emisar_approval_not_blocked}

    assert ApprovalDispatcher.run_once(dispatcher()) == {:ok, :idle}
  end

  test "a watch whose wait has not started yet is never closed as if nothing waited for it" do
    # The approval is registered with its turn, before the delivered result
    # starts the wait; only a closed task or an answered wait ends it.
    unstarted = registered_approval!("unstarted")

    assert ApprovalDispatcher.run_once(dispatcher("closer-unstarted")) == {:ok, :idle}
    assert Inspectors.emisar_approval(@connection_ref, unstarted).status == :monitoring
  end

  # Turning approval monitoring off, or losing the account's token, stopped
  # every approval a task was waiting for, and nothing said so anywhere: the
  # watch was not blocked, so Failures listed nothing while tasks waited for
  # good.
  test "an approval a task waits for is a failure while its account is not watched, until it is again" do
    approval_wait!("unwatched")
    assert failure("production/apr-unwatched") == nil

    assert {:ok, _snapshot} =
             IntegrationSetup.disable_emisar_monitoring(@connection_ref, "control-plane:local")

    row = failure("production/apr-unwatched")
    assert %{kind: "emisar", stall: :monitoring_off, action: nil, status: :monitoring} = row
    assert {:ok, %{stall: :monitoring_off}} = FailureProjection.emisar("production/apr-unwatched")

    explanation = FailureExplanation.explain(row)
    assert explanation.outlook == :fix_first
    assert %{link: "Open Emisar settings"} = settings_step(explanation)
    assert explanation.summary =~ "monitoring is off"
    # The fix is in Emisar's settings; the one thing to press here leaves it as it is.
    assert Enum.flat_map(explanation.options, &List.wrap(&1[:path])) ==
             ["/actions/emisar/production%2Fapr-unwatched/leave"]

    assert failures_page() =~ "/failures/emisar/production%2Fapr-unwatched"

    assert {:ok, _snapshot} =
             IntegrationSetup.enable_emisar_monitoring(@connection_ref, "control-plane:local")

    assert failure("production/apr-unwatched") == nil

    assert {:ok, %{approval: %{request_id: "apr-unwatched"}}} =
             Approvals.claim_next(@connection_ref, "approval-worker-watched-again", 60)
  end

  test "an approval a task waits for is a failure while its account has no token, until one is saved" do
    approval_wait!("tokenless")
    assert Credentials.delete(:emisar, @connection_ref, @actor) == :ok

    row = failure("production/apr-tokenless")
    assert %{stall: :token_unavailable, action: nil} = row

    explanation = FailureExplanation.explain(row)
    assert explanation.outlook == :fix_first
    assert settings_step(explanation)
    assert explanation.summary =~ "no usable Emisar token"

    assert {:ok, %{status: :rotated}} =
             IntegrationSetup.rotate_emisar(
               @connection_ref,
               "replacement-emisar-token-long-enough",
               "control-plane:local",
               requester: SameAccountRequester
             )

    assert failure("production/apr-tokenless") == nil
  end

  test "a token Ryker cannot read stops watching, and replacing it clears the failure" do
    approval_wait!("unreadable")

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok, _deferred} =
             Approvals.defer(
               @connection_ref,
               "apr-unreadable",
               lease_ref,
               300,
               {:delivery_credentials_unavailable, :credential_decryption_failed}
             )

    assert %{stall: :token_unavailable} = failure("production/apr-unreadable")

    assert {:ok, %{status: :rotated}} =
             IntegrationSetup.rotate_emisar(
               @connection_ref,
               "replacement-emisar-token-long-enough",
               "control-plane:local",
               requester: SameAccountRequester
             )

    assert failure("production/apr-unreadable") == nil

    # The next check goes out now rather than after the backoff it had reached.
    assert {:ok, %{approval: %{request_id: "apr-unreadable"}}} =
             Approvals.claim_next(@connection_ref, "approval-worker-after-token", 60)
  end

  # Emisar refusing the token blocks the watch, and the page said to replace
  # the token, then press "Watch the approval again" on every approval.
  test "an approval stopped by a refused token is watched again once the token is replaced" do
    approval_wait!("refused")

    assert {:ok, %{lease_ref: lease_ref}} =
             Approvals.claim_next(@connection_ref, "approval-worker", 60)

    assert {:ok, %Approval{status: :blocked}} =
             Approvals.block(
               @connection_ref,
               "apr-refused",
               lease_ref,
               {:emisar_http_error, 401, "unauthorized"}
             )

    row = failure("production/apr-refused")
    assert row.summary == "emisar_http_401"
    assert row |> FailureExplanation.explain() |> settings_step()

    assert {:ok, %{status: :rotated}} =
             IntegrationSetup.rotate_emisar(
               @connection_ref,
               "replacement-emisar-token-long-enough",
               "control-plane:local",
               requester: SameAccountRequester
             )

    assert failure("production/apr-refused") == nil
    assert Inspectors.emisar_approval(@connection_ref, "apr-refused").status == :monitoring

    assert {:ok, %{approval: %{request_id: "apr-refused"}}} =
             Approvals.claim_next(@connection_ref, "approval-worker-after-rotation", 60)
  end

  defp approval_wait!(suffix) do
    %{claim: claim, record: record} = registered!(suffix)
    assert {:ok, waiting} = wait_on!(claim, record)
    assert waiting.episode.state == :waiting_for_event
    %{claim: claim, record: record}
  end

  # A task waiting on one approval with a second one pending beside it; the
  # second is the rider.
  defp beside_another_approval!(suffix) do
    %{claim: claim, record: owner} = registered!("#{suffix}-owner")

    assert {:ok, _rider} =
             Records.create(
               Records.token(claim.turn),
               "op-#{suffix}",
               "emisar_approval",
               approval_payload(suffix)
             )

    assert {:ok, %{episode: %{owner_ref: owner_ref}}} = wait_on!(claim, owner)
    assert owner_ref == owner.ref
    %{claim: claim, rider: "apr-#{suffix}"}
  end

  defp watch!(claim, suffix) do
    assert {:ok, watch} =
             Records.create(Records.token(claim.turn), "watch-#{suffix}", "event_wait", %{
               "deadline_at" => nil,
               "event_matcher" => %{
                 "type" => "source_event",
                 "source_kind" => "slack",
                 "match" => %{"attachments" => [%{"title" => "Run #{suffix}"}]},
                 "poll_after" => nil,
                 "on_timeout" => nil
               },
               "kind" => "source_event",
               "verification" => "Read the run and say whether it finished."
             })

    watch
  end

  # A timer whose time has come, with the hard deadline `wait_on!/2` and
  # `wait_again!/2` start the wait with.
  defp timer!(claim, suffix) do
    assert {:ok, timer} =
             Records.create(Records.token(claim.turn), "check-#{suffix}", "event_wait", %{
               "deadline_at" => "2099-08-29T12:00:00Z",
               "event_matcher" => %{
                 "type" => "at",
                 "at" => "2026-08-29T12:00:00Z",
                 "on_timeout" => "Run the post-apply health check."
               },
               "kind" => "at",
               "verification" => "Run the post-apply health check."
             })

    timer
  end

  defp ensure!(episode) do
    assert {:ok, subscription} =
             Repo.transaction(fn ->
               case EventSubscriptions.ensure_in_transaction(episode) do
                 {:ok, value} -> value
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    subscription
  end

  # The approval `record` (request `apr-<suffix>`) succeeds, which resumes its
  # task; the resumed episode.
  defp settle!(suffix, record) do
    request_id = record.payload["request_id"]

    lease_ref =
      Enum.find_value(1..4, fn attempt ->
        case Approvals.claim_next(@connection_ref, "approval-worker-#{attempt}", 60) do
          {:ok, %{approval: %{request_id: ^request_id}, lease_ref: lease_ref}} -> lease_ref
          {:ok, _other} -> nil
        end
      end)

    assert {:ok, %{episode: resumed, status: :resumed}} =
             Approvals.observe(
               @connection_ref,
               request_id,
               lease_ref,
               run_state(suffix, "success"),
               5
             )

    assert resumed.state == :working
    resumed
  end

  # The resumed turn's silent result starts the episode's wait on `record`
  # again, as a turn's accepted result does.
  defp wait_again!(episode, record) do
    Episodes.apply(%Command.AcceptResult{
      decision_reason: "Waiting on #{record.ref} again.",
      delivery: :none,
      episode_key: episode.key,
      expected_turn_ref: episode.owner_ref,
      next_wait: %{deadline_at: ~U[2099-08-29 12:00:00.000000Z], kind: :event, ref: record.ref},
      occurred_at: ~U[2026-08-29 12:00:02.000000Z],
      result_ref: "result:#{episode.owner_ref}"
    })
  end

  # The claimed turn's delivered result starts the episode's wait on `record`.
  defp wait_on!(claim, record) do
    Episodes.apply(%Command.StartWait{
      deadline_at: ~U[2099-08-29 12:00:00.000000Z],
      episode_key: claim.episode.key,
      expected_turn_ref: claim.turn.turn_ref,
      kind: :event,
      occurred_at: ~U[2026-08-29 12:00:01.000000Z],
      wait_ref: record.ref
    })
  end

  # The approval as its turn records it, before the delivered result starts
  # the episode's wait for it.
  defp registered_approval!(suffix) do
    registered!(suffix)
    "apr-#{suffix}"
  end

  defp registered!(suffix) do
    now = ~U[2026-08-29 12:00:00.000000Z]

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "emisar-approval:#{suffix}",
        native_input_id: "source:#{suffix}",
        occurred_at: now,
        payload: %{"text" => "Perform the governed action."},
        turn_ref: "turn:#{suffix}"
      })

    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             WorkSessions.pin_episode(transition.episode.id, "test-policy", @policy_digest,
               environment_ref: @environment_ref
             )

    Episode
    |> Repo.get!(transition.episode.id)
    |> Ecto.Changeset.change(updated_at: ~U[2000-01-01 00:00:00.000000Z])
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("work:#{suffix}", 60)
    assert claim.episode.id == transition.episode.id

    assert Map.take(claim.session, [
             :emisar_connection_ref,
             :emisar_account_ref,
             :emisar_rpc_url
           ]) == %{
             emisar_connection_ref: @connection_ref,
             emisar_account_ref: "account-acme",
             emisar_rpc_url: "https://emisar.example/mcp"
           }

    assert {:ok, record} =
             Records.create(
               Records.token(claim.turn),
               "op-#{suffix}",
               "emisar_approval",
               approval_payload(suffix)
             )

    %{claim: claim, record: record}
  end

  defp close_task!(episode_key) do
    assert waiting = Inspectors.episode(episode_key)

    assert {:ok, _cancelled} =
             Episodes.apply(%Command.CancelEpisode{
               cancel_ref: "cancel:#{episode_key}",
               episode_key: episode_key,
               expected_owner: %{kind: waiting.owner_kind, ref: waiting.owner_ref},
               occurred_at: ~U[2026-08-29 12:05:00.000000Z],
               reason: "Closed by slack:user:U1 from the exact Slack work card."
             })
  end

  defp failure(ref) do
    assert {:ok, failures} = FailureProjection.list(%{})
    Enum.find(failures, &(&1.kind == "emisar" and &1.ref == ref))
  end

  # The step a failure page leads with when Emisar's settings are what to fix.
  defp settings_step(explanation),
    do: Enum.find(explanation.options, &(&1[:recommended] && &1[:href] == "/integrations/emisar"))

  defp failures_page do
    page = Pages.page(["failures"], %{}, %{projection: Projection.callbacks()})
    assert page.status == 200
    page.body
  end

  defp dispatcher(worker_ref \\ "approval-closer") do
    [
      api: UnusedAPI,
      client: :unused,
      connection_ref: @connection_ref,
      lease_seconds: 60,
      poll_seconds: 5,
      presentation: :unused,
      presenter: UnusedPresenter,
      retry_base_seconds: 2,
      retry_max_seconds: 60,
      wait_seconds: 20,
      worker_ref: worker_ref
    ]
  end

  defp approval_payload(suffix) do
    %{
      "action_id" => "nomad.alloc_restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-#{suffix}",
      "account_ref" => "account-acme",
      "connection_ref" => @connection_ref,
      "expires_at" => "2099-08-29T12:00:00.000000Z",
      "operation_id" => "op-#{suffix}",
      "pack_ref" => "nomad@1#sha256:abc",
      "request_id" => "apr-#{suffix}",
      "run_id" => "run-#{suffix}",
      "runner_ref" => "production-runner",
      "rpc_url" => "https://emisar.example/mcp",
      "status" => "pending_approval"
    }
  end

  defp configure_emisar! do
    {:ok, snapshot} = Settings.initialize("control-plane:local")

    {:ok, _credential} =
      Credentials.put(:emisar, @connection_ref, "emisar-token-long-enough", @actor)

    {:ok, snapshot} =
      Settings.put_emisar_connection(
        %{
          ref: @connection_ref,
          display_name: "Production approvals",
          rpc_url: "https://emisar.example/mcp",
          account_ref: "account-acme",
          account_label: "Acme production",
          enabled_for_new_work: true,
          monitoring_enabled: true,
          verified_at: ~U[2026-08-29 12:00:00.000000Z]
        },
        snapshot.installation.revision,
        "control-plane:local"
      )

    {:ok, _snapshot} =
      Settings.put_environment(
        %{
          ref: @environment_ref,
          display_name: "Production",
          emisar_connection_ref: @connection_ref
        },
        snapshot.installation.revision,
        "control-plane:local"
      )

    assert {:ok, %{connection_ref: @connection_ref}} =
             Connections.resolve(Settings.fetch!(), @environment_ref)
  end

  defp run_state(suffix, status) do
    %RunState{
      action_id: "nomad.alloc_restart",
      error_message: nil,
      operation_id: "op-#{suffix}",
      pack_ref: "nomad@1#sha256:abc",
      run_id: "run-#{suffix}",
      run_url: "https://emisar.example/app/acme/runs/run-#{suffix}",
      runner_ref: "production-runner",
      status: status
    }
  end

  defp person_reply do
    {:ok, input} =
      Ryker.Slack.Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Go ahead."},
        event_kind: :message,
        event_ref: "Ev-approval-reply",
        message_ref: "1787832000.000200",
        occurred_at: ~U[2026-08-28 12:00:00.000000Z],
        revision: 1,
        thread_ref: "1787832000.000100",
        workspace_ref: "TAABB028FCC2E"
      })

    input
  end
end
