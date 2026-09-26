defmodule Ryker.Admission.ReadySessionsTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission.{Executor, ReadyPool, ReadySessions, Runtime}
  alias Ryker.FakeRetentionCoopAPI, as: RetentionAPI
  alias Ryker.Ingress.Inbox
  alias Ryker.Repo
  alias Ryker.Retention.Dispatcher, as: RetentionDispatcher
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.TestSupport.FakeCoopAPI, as: FakeAPI
  alias Ryker.Work.Session

  @now ~U[2026-08-27 12:00:00.000000Z]
  @policy "admission-read-only"
  @digest String.duplicate("a", 64)
  @new_digest String.duplicate("b", 64)

  # Live install, 2026-09-26: routing a plain "hi" took 28.6 s end to end, and
  # 5.6 s of it was Coop creating the routing session before anything else
  # could start. A message that finds a session already started must go
  # straight to its turn; this holds that saving shut.
  test "a message is routed on a ready session without creating one" do
    {:ok, fake} = FakeAPI.start_link(replies(1))
    assert {:ok, %{started: 1}} = keep(fake, 1)
    assert [ready] = ready_sessions()

    entry = record_slack_input!("Ev-ready-routed", "C100")

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, claim!(entry)))

    assert execution.result.entry.decision_action == :reply
    assert execution.session_id == ready.coop_session_id

    state = FakeAPI.state(fake)
    assert routing_creates(state) == []
    assert state.turn_sessions == [ready.coop_session_id]
    assert state.closed_sessions == [ready.coop_session_id]

    assert %Session{
             ready_state: :claimed,
             admission_input_id: admission_input_id,
             generation: 1,
             cleanup_status: :plan_pending
           } = Repo.get!(Session, ready.id)

    assert admission_input_id == entry.id
    assert ready_sessions() == []
  end

  # Every ready session is shared by every channel and conversation, so the
  # one thing it must never do is carry two messages: the second would run in
  # a session that already holds the first one's conversation.
  test "two messages never share one ready session" do
    {:ok, fake} = FakeAPI.start_link(replies(3))
    assert {:ok, %{started: 2}} = keep(fake, 2)

    first = route!(fake, "Ev-ready-first", "C201")
    second = route!(fake, "Ev-ready-second", "C202")
    third = route!(fake, "Ev-ready-third", "C203")

    assert Enum.uniq([first.session_id, second.session_id, third.session_id]) ==
             [first.session_id, second.session_id, third.session_id]

    # The first two took one ready session each; the third found none left
    # and created its own exactly as routing always has.
    assert [first.session_id, second.session_id] == ["ready_1", "ready_2"]
    assert [_created] = routing_creates(FakeAPI.state(fake))

    claimed =
      Repo.all(
        from(session in Session,
          where: session.ready_state == :claimed,
          select: {session.coop_session_id, session.admission_input_id}
        )
      )

    assert Enum.sort(claimed) == [
             {"ready_1", first.result.entry.id},
             {"ready_2", second.result.entry.id}
           ]
  end

  # The setting is a promise about the next message, not the first one: a
  # pool that started its sessions once and never replaced what messages took
  # would leave every later message paying the full start again.
  test "the pool keeps as many sessions ready as the setting asks" do
    {:ok, fake} = FakeAPI.start_link(replies(1))

    assert {:ok, %{started: 2}} = keep(fake, 2)
    assert {:ok, %{started: 0, retired: 0}} = keep(fake, 2)
    assert length(ready_sessions()) == 2

    route!(fake, "Ev-ready-refill", "C300")
    assert length(ready_sessions()) == 1

    assert {:ok, %{started: 1}} = keep(fake, 2)
    assert Enum.map(ready_sessions(), & &1.coop_session_id) == ["ready_2", "ready_3"]
  end

  # 0 turns the feature off. Sessions started before the change must not stay
  # open on the worker, and routing must not depend on the pool to work.
  test "setting 0 closes the ready sessions and routing still works by creating one" do
    {:ok, fake} = FakeAPI.start_link(replies(1))
    assert {:ok, %{started: 2}} = keep(fake, 2)
    ready = ready_sessions()

    assert {:ok, %{started: 0, retired: 2}} = keep(fake, 0)
    assert ready_sessions() == []
    assert cleaned_up?(fake, ready)

    execution = route!(fake, "Ev-ready-off", "C400")
    assert execution.session_id == "remote_test"
    assert [_created] = routing_creates(FakeAPI.state(fake))
  end

  # A session started under an older routing model was pinned to that
  # model's policy, and one kept past its age is one the worker may no longer
  # hold as it did: routing a message on either would answer it with the
  # wrong model or fail it outright.
  test "an expired or policy-changed ready session is closed, not used" do
    {:ok, fake} = FakeAPI.start_link(replies(2))
    assert {:ok, %{started: 2}} = keep(fake, 2)
    [expired, fresh] = ready_sessions()
    age_past_maximum!(expired)

    # The oldest one is past its age: the message takes the younger one.
    assert route!(fake, "Ev-ready-aged", "C500").session_id == fresh.coop_session_id
    assert Repo.get!(Session, expired.id).ready_state == :ready

    assert {:ok, %{retired: 1, started: 2}} = keep(fake, 2)
    outdated = ready_sessions()

    # The routing model changed, and the policy's digest with it.
    FakeAPI.set_policy_digest(fake, @new_digest)
    assert route!(fake, "Ev-ready-policy", "C501", @new_digest).session_id == "remote_test"
    assert Enum.all?(outdated, &(Repo.get!(Session, &1.id).ready_state == :ready))

    assert {:ok, %{retired: 2, started: 2}} = keep(fake, 2, @new_digest)
    assert Enum.all?(ready_sessions(), &(&1.policy_digest == @new_digest))

    assert FakeAPI.state(fake).turn_sessions == [fresh.coop_session_id, "remote_test"]
    assert cleaned_up?(fake, [expired | outdated])
  end

  # A routing run can die after it claimed a ready session and before its
  # turn ran there. The session must never go back to the pool or to another
  # message, and the message's next run must not pick it up either: it is
  # closed, and the message is routed on a session of its own.
  test "a crash between claim and use never reuses the session" do
    {:ok, fake} = FakeAPI.start_link(replies(2))
    assert {:ok, %{started: 1}} = keep(fake, 1)
    [ready] = ready_sessions()

    stranded = record_slack_input!("Ev-ready-crash", "C600")
    lease_ref = claim!(stranded)
    # The run that claimed it died here, before using it.
    assert {:ok, %Session{id: id}, :claimed} = ReadySessions.claim(stranded, policy(@digest))
    assert id == ready.id

    assert {:ok, %{started: 1}} = keep(fake, 1)
    other = route!(fake, "Ev-ready-other", "C601")
    assert other.session_id == "ready_2"

    assert {:error, {:admission_generation_spent, {:ready_session_abandoned, "ready_1"}}} =
             Executor.run(Inbox.ref(stranded), executor_options(fake, lease_ref))

    assert FakeAPI.state(fake).closed_sessions |> Enum.member?("ready_1")

    assert {:ok, _deferred} =
             Inbox.defer_after_terminal(
               Inbox.ref(stranded),
               lease_ref,
               @now,
               0,
               "ready_session_abandoned",
               "the run that claimed it stopped"
             )

    retry_lease = claim!(stranded)

    assert {:ok, retried} =
             Executor.run(Inbox.ref(stranded), executor_options(fake, retry_lease))

    assert retried.result.entry.decision_action == :reply
    refute retried.session_id == "ready_1"
    refute "ready_1" in FakeAPI.state(fake).turn_sessions

    assert %Session{ready_state: :claimed, cleanup_status: :plan_pending, generation: 1} =
             Repo.get!(Session, ready.id)
  end

  # A run can stop after Coop accepted the answer and closed the session but
  # before the decision is saved; here its lease runs out at that moment. The
  # next run of the same message must read that finished turn back from the
  # closed session, as it does from a session it created, rather than pay for
  # the model a second time.
  test "a claimed session's finished turn is read back when the run stopped before saving" do
    {:ok, fake} = FakeAPI.start_link(replies(1), close_after_validation: true)
    assert {:ok, %{started: 1}} = keep(fake, 1)
    entry = record_slack_input!("Ev-ready-save-lost", "C700")
    later = DateTime.add(@now, 301, :second)
    stalled = fn -> if FakeAPI.state(fake).validations == [], do: @now, else: later end
    options = entry |> claim!() |> then(&executor_options(fake, &1)) |> Keyword.put(:now, stalled)

    assert {:error, :admission_attempt_lease_lost} = Executor.run(Inbox.ref(entry), options)
    assert FakeAPI.sessions(fake)["ready_1"]["state"] == "closed"

    assert {:ok, %{entry: %{id: id}, lease_ref: retry_lease}} =
             Inbox.claim_next("executor:test", later, 300)

    assert id == entry.id
    retry = fake |> executor_options(retry_lease) |> Keyword.put(:now, fn -> later end)

    assert {:ok, execution} = Executor.run(Inbox.ref(entry), retry)
    assert execution.result.entry.decision_action == :reply
    assert execution.session_id == "ready_1"
    assert FakeAPI.state(fake).submit_count == 1
  end

  # The pool runs a pass every second. A worker that cannot create sessions
  # would otherwise be asked every second for as long as it is down, leaving a
  # dead session record behind each time.
  test "a worker that cannot start routing sessions is asked again only after a growing wait" do
    {:ok, fake} = FakeAPI.start_link(replies(1), fail_create: true)

    assert {:ok, %{started: 0}} = keep(fake, 1)
    assert [failed] = pool_rows()
    assert %Session{ready_state: :retired, coop_session_id: nil} = failed
    assert length(FakeAPI.state(fake).create_keys) == 1

    # Within the first wait (5 s) nothing is asked.
    assert {:ok, %{started: 0}} = keep(fake, 1)
    assert length(FakeAPI.state(fake).create_keys) == 1

    wait_past!(6)
    assert {:ok, %{started: 0}} = keep(fake, 1)
    assert length(FakeAPI.state(fake).create_keys) == 2

    # The second failure in a row doubles the wait.
    wait_past!(6)
    assert {:ok, %{started: 0}} = keep(fake, 1)
    assert length(FakeAPI.state(fake).create_keys) == 2

    FakeAPI.allow_create(fake)
    wait_past!(11)
    assert {:ok, %{started: 1}} = keep(fake, 1)
    assert [%Session{coop_session_id: "ready_1"}] = ready_sessions()
  end

  defp pool_rows,
    do:
      Repo.all(
        from(session in Session,
          where: not is_nil(session.ready_state),
          order_by: [asc: session.inserted_at]
        )
      )

  # Moves every recorded start back in time, as if `seconds` had passed.
  defp wait_past!(seconds) do
    Repo.update_all(from(session in Session, where: not is_nil(session.ready_state)),
      set: [updated_at: DateTime.add(Repo.now!(), -seconds, :second)]
    )
  end

  defp route!(fake, event_ref, channel_ref, digest \\ @digest) do
    entry = record_slack_input!(event_ref, channel_ref)

    assert {:ok, execution} =
             Executor.run(Inbox.ref(entry), executor_options(fake, claim!(entry), digest))

    execution
  end

  defp keep(fake, target, digest \\ @digest) do
    ReadyPool.keep(
      api: FakeAPI,
      client: fake,
      policy: @policy,
      policy_digest: digest,
      target: target
    )
  end

  defp ready_sessions do
    Repo.all(
      from(session in Session,
        where: session.ready_state == :ready,
        order_by: [asc: session.inserted_at, asc: session.id]
      )
    )
  end

  defp routing_creates(state),
    do: Enum.filter(state.create_keys, &String.starts_with?(&1, "ryker:admission:create:"))

  defp age_past_maximum!(%Session{id: id}) do
    {1, nil} =
      Repo.update_all(from(session in Session, where: session.id == ^id),
        set: [inserted_at: DateTime.add(Repo.now!(), -31 * 60, :second)]
      )
  end

  # Cleanup closes and removes each retired session on the worker that holds
  # it, starting from what that Coop holds now.
  defp cleaned_up?(fake, sessions) do
    {:ok, cleanup} = RetentionAPI.start_link(sessions: Map.values(FakeAPI.sessions(fake)))

    drained =
      Enum.reduce_while(1..20, :busy, fn attempt, :busy ->
        case retention(cleanup, attempt) do
          {:ok, :idle} -> {:halt, :idle}
          {:ok, {:executed, _execution}} -> {:cont, :busy}
          other -> flunk("cleanup stopped: #{inspect(other)}")
        end
      end)

    drained == :idle and
      Enum.all?(sessions, fn session ->
        Repo.get!(Session, session.id).cleanup_status == :discarded and
          RetentionAPI.remote_session(cleanup, session.coop_session_id)["state"] == "discarded"
      end)
  end

  defp retention(client, attempt) do
    RetentionDispatcher.run_once(
      api: RetentionAPI,
      client: client,
      closed_session_grace_seconds: 900,
      lease_seconds: 60,
      max_attempts: 8,
      retained_recheck_seconds: 21_600,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "ready-cleanup:#{attempt}"
    )
  end

  defp claim!(entry) do
    assert {:ok, %{entry: claimed, lease_ref: lease_ref}} =
             Inbox.claim_next("executor:test", @now, 300)

    assert claimed.id == entry.id
    lease_ref
  end

  defp record_slack_input!(event_ref, channel_ref) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: channel_ref,
               content: %{"text" => "hi"},
               event_kind: :message,
               event_ref: event_ref,
               message_ref: "1787832001.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "TE5D7C8842D32"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp executor_options(fake, lease_ref, digest \\ @digest) do
    Enum.to_list(Runtime.execution_callbacks()) ++
      [
        api: FakeAPI,
        client: fake,
        lease_ref: lease_ref,
        max_polls: 10,
        now: fn -> @now end,
        policy: @policy,
        policy_digest: digest,
        poll_interval_ms: 0,
        renew_lease: fn -> :ok end,
        sleep: fn _milliseconds -> :ok end
      ]
  end

  defp policy(digest), do: %{name: @policy, digest: digest}

  # The fake names every turn turn_test, so two identical answers would share
  # one decision reference; each message gets its own words, as real turns
  # get their own ids.
  defp replies(count) do
    Enum.map(1..count, fn index ->
      Jason.encode!(%{
        "action" => "reply",
        "episode_ref" => nil,
        "reaction" => nil,
        "relation" => "unrelated",
        "repository_source" => nil,
        "reason" => "Message #{index} asks for a short answer.",
        "work_class" => "conversational"
      })
    end)
  end
end
