defmodule Ryker.Slack.ThreadStatusProjectionTest do
  use Ryker.DataCase, async: true

  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Slack.ThreadStatusProjection
  alias Ryker.Work.Activity
  alias Ryker.Work.Session
  alias Ryker.Work.Turn

  test "snapshot reconstructs a queued Slack status from durable Inbox state" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please investigate"},
               event_kind: :message,
               event_ref: "Ev-status-snapshot",
               message_ref: "1787832000.000100",
               occurred_at: ~U[2026-09-04 07:00:00.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "TF2975945C602"
             })

    assert {:ok, %{entry: _entry}} = Inbox.record(input)

    assert {:ok, [%{phase: :queued, status: "is queued…"}]} =
             ThreadStatusProjection.snapshot("TF2975945C602")

    assert ThreadStatusProjection.snapshot("") ==
             {:error, {:invalid_slack_thread_status, :workspace_ref}}
  end

  test "durable ingress and episode ownership become truthful native status phases" do
    key = %{conversation: "slack:TF2975945C602:C456", thread: "1787832000.000100"}

    targets =
      ThreadStatusProjection.targets(
        [
          entry(key, :decided),
          entry(key, :pending, lease_ref: "lease:admission")
        ],
        [episode(key, :working, :turn)],
        %{},
        "TF2975945C602"
      )

    assert [target] = targets
    assert target.phase == :admitting
    assert target.status == "is deciding how to respond…"

    assert [waiting] =
             ThreadStatusProjection.targets(
               [],
               [episode(key, :waiting_for_event, :event)],
               %{},
               "TF2975945C602"
             )

    assert waiting.phase == :waiting_for_event
    # A day-long Terraform wait kept refreshing Slack's working indicator every
    # 90 seconds after the work had settled. Waiting is not active work.
    assert waiting.status == ""

    assert [complete] =
             ThreadStatusProjection.targets(
               [],
               [episode(key, :complete, nil)],
               %{},
               "TF2975945C602"
             )

    assert complete.phase == :clear
    assert complete.status == ""

    assert [blocked] =
             ThreadStatusProjection.targets(
               [entry(key, :blocked)],
               [],
               %{},
               "TF2975945C602"
             )

    assert blocked.phase == :blocked
    assert blocked.status == ""
  end

  # `blocked-task-recovery.md`: "Update the same message, clear native working
  # status while parked". Blocking a turn deliberately leaves its episode in
  # `:working` — `Work.Cancellation.command/3` returns nil for a block, so no
  # episode transition is applied, and `Slack.WorkControlsTest`'s "a copied
  # control cannot stop work…" asserts exactly that. The thread therefore kept
  # refreshing "is working..." every 90 seconds for a task whose worker had
  # stopped and whose card already said an operator had to recover it. It is the
  # same defect as the day-long Terraform wait above, one state over, and it is
  # worse: a wait ends by itself, a parked task never does.
  test "a parked task stops telling its thread that work is still running" do
    episode = parked_episode!()

    assert {:ok, [parked]} = ThreadStatusProjection.snapshot("TF2975945C602")
    assert parked.phase == :blocked
    assert parked.status == ""
    assert parked.origin_kind == "episode"
    assert parked.origin_id == episode.id

    # The turn is what makes it parked, so an episode whose owner is working
    # still reports work (here a turn with nothing narrated yet), and a parked
    # task never outranks a new message.
    Repo.update_all(Turn, set: [status: :pending])
    assert {:ok, [working]} = ThreadStatusProjection.snapshot("TF2975945C602")
    assert working.phase == :working
    assert working.status == "is getting started…"
  end

  test "foreign workspaces shadow work and malformed destinations never spend Slack writes" do
    foreign = %{conversation: "slack:T999:C456", thread: "1787832000.000100"}
    malformed = %{conversation: "github:main:repository:1", thread: "issue:1"}
    local = %{conversation: "slack:TF2975945C602:C456", thread: "1787832000.000100"}

    assert ThreadStatusProjection.targets(
             [
               entry(foreign, :pending),
               entry(malformed, :pending),
               entry(local, :pending, execution_mode: :shadow),
               entry(local, :unknown)
             ],
             [
               episode(foreign, :working, :turn, execution_mode: :shadow),
               episode(local, :working, :turn, execution_mode: :shadow),
               episode(local, :unknown, nil)
             ],
             %{},
             "TF2975945C602"
           ) == []
  end

  test "every durable lifecycle branch maps to one bounded semantic status" do
    key = %{conversation: "slack:TF2975945C602:C456", thread: "1787832000.000100"}
    retry_at = ~U[2026-09-04 07:01:00.000000Z]

    cases = [
      {[entry(key, :pending)], [], {:queued, "is queued…"}},
      {[entry(key, :pending, next_attempt_at: retry_at)], [],
       {:admission_retry, "is waiting to try again…"}},
      {[], [episode(key, :working, :delivery)], {:delivery, "is posting the reply…"}},
      {[], [episode(key, :waiting_for_input, :input)], {:waiting_for_input, ""}},
      {[], [episode(key, :cancelled, nil)], {:clear, ""}}
    ]

    Enum.each(cases, fn {entries, episodes, {phase, status}} ->
      assert [%{phase: ^phase, status: ^status}] =
               ThreadStatusProjection.targets(entries, episodes, %{}, "TF2975945C602")
    end)
  end

  # Andrew, 2026-09-26: "can we somehow stream what ryker actually does in
  # there?" The thread said "is working..." for the whole of every run, a
  # one-line answer and a forty-minute investigation alike, so nobody in the
  # channel could tell a busy run from a stuck one. The line now follows the
  # activity the worker narrates for the turn that owns the work.
  test "the status line says what the running turn is doing, in the order it does it" do
    turn = running_turn!("TF2975945C602", "progress")

    steps = [
      nil,
      {"model.progress", %{"text" => "Checking what we know about this alert first."}},
      {"tool.started", state_tool("memory", "search_memory")},
      {"tool.completed", %{"status" => "completed", "tool_call_id" => "memory"}},
      {"model.thought", %{}},
      {"tool.started", %{"kind" => "read", "tool_call_id" => "read"}},
      {"tool.started", state_tool("final", "validate_final")}
    ]

    phrases =
      steps
      |> Enum.with_index()
      |> Enum.map(fn {step, sequence} ->
        with {type, payload} <- step, do: narrate!(turn, sequence, type, payload)
        assert {:ok, [target]} = ThreadStatusProjection.snapshot("TF2975945C602")
        assert target.phase == :working
        target.status
      end)

    # A finished tool keeps its words until the next one starts, so a run does
    # not flicker to "thinking" between every call.
    assert phrases == [
             "is getting started…",
             "is thinking…",
             "is searching what it knows…",
             "is searching what it knows…",
             "is searching what it knows…",
             "is reading the code…",
             "is writing the reply…"
           ]
  end

  # The worker narrates a tool with whatever it was called with: the command,
  # the file, the search text, the Emisar action the model chose, and older
  # builds put a title such as "Read file '/srv/app/.env'" on top. Everyone in
  # the channel sees the status line, including people who could never open
  # the episode, so it is a fixed phrase per kind of tool and nothing else.
  test "tool arguments, commands and titles never reach the status line" do
    secrets = ~w(xoxb-7461 hunter2 internal.example .env tfc.plan_summary datadog query_metrics
      Deploy lib/billing)

    calls = [
      {%{
         "input" => %{"command" => "curl -H 'Authorization: Bearer xoxb-7461' internal.example"},
         "kind" => "execute",
         "title" => "curl internal.example with xoxb-7461"
       }, "is running a command…"},
      {%{
         "content" => "DATABASE_PASSWORD=hunter2",
         "input" => %{"path" => "/srv/app/.env"},
         "kind" => "read",
         "title" => "Read file '/srv/app/.env'"
       }, "is reading the code…"},
      {%{
         "input" => %{
           "arguments" => %{"query" => "prod password hunter2"},
           "server" => "controller-tools",
           "tool" => "search_memory"
         },
         "kind" => "execute"
       }, "is searching what it knows…"},
      {%{
         "input" => %{
           "arguments" => %{"action_id" => "tfc.plan_summary", "reason" => "Deploy check"},
           "server" => "emisar",
           "tool" => "run_action"
         },
         "kind" => "execute"
       }, "is asking Emisar to run an action…"},
      {%{
         "input" => %{
           "arguments" => %{"query" => "Deploy errors"},
           "server" => "datadog",
           "tool" => "query_metrics"
         },
         "kind" => "execute",
         "title" => "datadog query_metrics"
       }, "is working…"},
      {%{"kind" => "other", "title" => "Apply patch to lib/billing"}, "is working…"}
    ]

    turn = running_turn!("TF2975945C602", "arguments")

    for {{payload, phrase}, index} <- Enum.with_index(calls, 1) do
      narrate!(turn, index, "tool.started", Map.put(payload, "tool_call_id", "call-#{index}"))
      assert {:ok, [%{status: status}]} = ThreadStatusProjection.snapshot("TF2975945C602")

      for secret <- secrets do
        refute status =~ secret, "#{inspect(secret)} reached the status line: #{status}"
      end

      assert status == phrase
    end
  end

  # One conversation keeps its episode and its worker session across
  # follow-ups. When someone adds a message while Ryker is writing, the new
  # turn replaces the old one, and the old turn's last step ("is writing the
  # reply…") is still the newest activity in the session. The new turn has
  # done nothing yet and must say so.
  test "a follow-up turn starts from getting started, not from the last answer's last step" do
    turn = running_turn!("TF2975945C602", "follow-up")
    narrate!(turn, 1, "tool.started", state_tool("final", "validate_final"))

    assert {:ok, [%{status: "is writing the reply…"}]} =
             ThreadStatusProjection.snapshot("TF2975945C602")

    Repo.update_all(Turn, set: [status: :superseded])

    Repo.insert!(%Turn{
      coop_turn_id: "remote-turn:#{Ecto.UUID.generate()}",
      episode_id: turn.episode.id,
      id: Ecto.UUID.generate(),
      session_id: turn.session.id,
      status: :pending,
      turn_ref: "turn:thread-status:follow-up:2"
    })

    Repo.update_all(Episode, set: [owner_ref: "turn:thread-status:follow-up:2"])

    assert {:ok, [%{phase: :working, status: "is getting started…"}]} =
             ThreadStatusProjection.snapshot("TF2975945C602")
  end

  # 2026-09-26, the thread whose quick replies were in question: the next
  # message's turn reacted and checked its reply by 17:18, then Coop reported it
  # running with nothing narrated for two hours and ten minutes, over 27 work
  # attempts, until it replied at 19:28. Its last step was "is writing the
  # reply…", and naming that for two hours claims work nobody was doing. The
  # longest pause between steps in every healthy run that day was 22 seconds.
  test "a turn that has gone quiet stops naming the step it did last" do
    turn = running_turn!("TF2975945C602", "quiet")
    now = DateTime.utc_now()

    narrate!(turn, 1, "tool.started", state_tool("final", "validate_final"), minutes_ago(now, 9))

    narrate!(
      turn,
      2,
      "tool.completed",
      %{"status" => "completed", "tool_call_id" => "final"},
      minutes_ago(now, 8)
    )

    assert {:ok, [%{phase: :working, status: "is working…"}]} =
             ThreadStatusProjection.snapshot("TF2975945C602")

    narrate!(turn, 3, "tool.started", %{"kind" => "read", "tool_call_id" => "read"}, now)

    assert {:ok, [%{phase: :working, status: "is reading the code…"}]} =
             ThreadStatusProjection.snapshot("TF2975945C602")
  end

  defp minutes_ago(now, minutes), do: DateTime.add(now, -minutes * 60, :second)

  defp state_tool(call, tool) do
    %{
      "input" => %{"server" => "controller-tools", "tool" => tool},
      "kind" => "execute",
      "tool_call_id" => call
    }
  end

  defp running_turn!(workspace_ref, suffix) do
    episode =
      Repo.insert!(%Episode{
        destination_conversation_ref: "slack:#{workspace_ref}:C456",
        destination_thread_ref: "1787832000.000100",
        destination_transport: "slack",
        execution_mode: :live,
        id: Ecto.UUID.generate(),
        key: "thread-status:#{suffix}",
        owner_kind: :turn,
        owner_ref: "turn:thread-status:#{suffix}",
        state: :working
      })

    session =
      Repo.insert!(%Session{
        coop_session_id: "remote-session:#{Ecto.UUID.generate()}",
        episode_id: episode.id,
        external_ref: "session:thread-status:#{suffix}",
        id: Ecto.UUID.generate(),
        policy: "ryker-work",
        policy_digest: String.duplicate("a", 64)
      })

    turn =
      Repo.insert!(%Turn{
        coop_turn_id: "remote-turn:#{Ecto.UUID.generate()}",
        episode_id: episode.id,
        id: Ecto.UUID.generate(),
        session_id: session.id,
        status: :pending,
        turn_ref: episode.owner_ref
      })

    %{episode: episode, session: session, turn: turn}
  end

  # Through the real ingest path, so the stored payload is exactly what
  # production keeps from the worker's narration.
  defp narrate!(
         %{session: session, turn: turn},
         sequence,
         type,
         payload,
         occurred_at \\ DateTime.utc_now()
       ) do
    assert {:ok, %{inserted: 1}} =
             Activity.ingest(session.id, [
               %{
                 "id" => "#{session.coop_session_id}:#{sequence}",
                 "occurred_at" => DateTime.to_iso8601(occurred_at),
                 "payload" => payload,
                 "sequence" => sequence,
                 "session_id" => session.coop_session_id,
                 "turn_id" => turn.coop_turn_id,
                 "type" => type,
                 "version" => 1
               }
             ])
  end

  defp parked_episode! do
    episode =
      Repo.insert!(%Episode{
        destination_conversation_ref: "slack:TF2975945C602:C456",
        destination_thread_ref: "1787832000.000100",
        destination_transport: "slack",
        execution_mode: :live,
        id: Ecto.UUID.generate(),
        key: "thread-status:parked",
        owner_kind: :turn,
        owner_ref: "turn:thread-status:parked",
        state: :working
      })

    session =
      Repo.insert!(%Session{
        episode_id: episode.id,
        external_ref: "session:thread-status:parked",
        id: Ecto.UUID.generate(),
        policy: "ryker-work",
        policy_digest: String.duplicate("a", 64)
      })

    Repo.insert!(%Turn{
      episode_id: episode.id,
      id: Ecto.UUID.generate(),
      session_id: session.id,
      status: :blocked,
      turn_ref: episode.owner_ref
    })

    episode
  end

  defp entry(destination, status, attributes \\ []) do
    struct!(
      Entry,
      Keyword.merge(
        [
          destination_conversation_ref: destination.conversation,
          destination_thread_ref: destination.thread,
          destination_transport: "slack",
          execution_mode: :live,
          lease_ref: nil,
          next_attempt_at: nil,
          source_kind: "slack",
          source_ref: "TF2975945C602",
          status: status
        ],
        attributes
      )
    )
  end

  defp episode(destination, state, owner_kind, attributes \\ []) do
    struct!(
      Episode,
      Keyword.merge(
        [
          destination_conversation_ref: destination.conversation,
          destination_thread_ref: destination.thread,
          destination_transport: "slack",
          execution_mode: :live,
          owner_kind: owner_kind,
          state: state
        ],
        attributes
      )
    )
  end
end
