defmodule Responder.Slack.ThreadStatusProjectionTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Slack.ThreadStatusProjection
  alias Responder.Work.Session
  alias Responder.Work.Turn

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

    assert {:ok, [%{phase: :queued, status: "is queued..."}]} =
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
        MapSet.new(),
        "TF2975945C602"
      )

    assert [target] = targets
    assert target.phase == :admitting
    assert target.status == "is deciding how to respond..."

    assert [waiting] =
             ThreadStatusProjection.targets(
               [],
               [episode(key, :waiting_for_event, :event)],
               MapSet.new(),
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
               MapSet.new(),
               "TF2975945C602"
             )

    assert complete.phase == :clear
    assert complete.status == ""

    assert [blocked] =
             ThreadStatusProjection.targets(
               [entry(key, :blocked)],
               [],
               MapSet.new(),
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
    # still reports work, and a parked task never outranks a new message.
    Repo.update_all(Turn, set: [status: :pending])
    assert {:ok, [working]} = ThreadStatusProjection.snapshot("TF2975945C602")
    assert working.phase == :working
    assert working.status == "is working..."
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
             MapSet.new(),
             "TF2975945C602"
           ) == []
  end

  test "every durable lifecycle branch maps to one bounded semantic status" do
    key = %{conversation: "slack:TF2975945C602:C456", thread: "1787832000.000100"}
    retry_at = ~U[2026-09-04 07:01:00.000000Z]

    cases = [
      {[entry(key, :pending)], [], {:queued, "is queued..."}},
      {[entry(key, :pending, next_attempt_at: retry_at)], [],
       {:admission_retry, "is waiting to retry admission..."}},
      {[], [episode(key, :working, :delivery)], {:delivery, "is preparing the response..."}},
      {[], [episode(key, :waiting_for_input, :input)], {:waiting_for_input, ""}},
      {[], [episode(key, :cancelled, nil)], {:clear, ""}}
    ]

    Enum.each(cases, fn {entries, episodes, {phase, status}} ->
      assert [%{phase: ^phase, status: ^status}] =
               ThreadStatusProjection.targets(entries, episodes, MapSet.new(), "TF2975945C602")
    end)
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
        policy: "responder-work",
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
