defmodule Ryker.Work.ReadySessionsTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.Admission
  alias Ryker.Episodes
  alias Ryker.FakeRetentionCoopAPI, as: RetentionAPI
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Repo
  alias Ryker.Retention.Dispatcher, as: RetentionDispatcher
  alias Ryker.TestSupport.FakeWorkCoopAPI, as: FakeAPI
  alias Ryker.Work.{Custody, Executor, ReadyPool, ReadySessions, Session}

  @now ~U[2026-10-11 21:00:00.000000Z]
  @policy "work-read-only"
  @digest String.duplicate("a", 64)
  @other_digest String.duplicate("b", 64)

  # Measured on the live install, 2026-10-11, over 25 new conversations: Coop
  # took 18-55 s to create the Work session (create command 8-20 s, create
  # operation 10-35 s) before the first answer could start. A conversation
  # whose pin has a session kept ready must start on it, and Coop must not be
  # asked to create another.
  test "a new conversation's first answer runs on a session kept ready and sends no create" do
    {:ok, fake} = FakeAPI.start_link([answer()])
    assert {:ok, %{started: 1}} = ReadyPool.keep(pool(fake, [pin(@digest)]))
    assert [%Session{coop_session_id: coop_session_id} = ready] = ready_sessions()
    assert FakeAPI.state(fake).create_count == 1

    claim = start_conversation!("first-answer", @digest)

    assert claim.session.id == ready.id
    assert claim.session.coop_session_id == coop_session_id
    assert claim.session.ready_state == :claimed
    assert {:ok, %{status: :accepted}} = Executor.run(claim, executor(fake))

    assert FakeAPI.state(fake).create_count == 1
    assert ready_sessions() == []
    assert %Session{episode_id: episode_id, generation: 1} = Repo.get!(Session, ready.id)
    assert episode_id == claim.episode.id
  end

  # Every live pin names a repository and the environment's context around it, and a claim
  # compares each stored as canonical JSON. A context with one more read-only repository is
  # another environment's view of the work and must not be served the same session.
  test "a conversation takes the session kept ready for its exact repository context" do
    {:ok, fake} = FakeAPI.start_link([answer()])
    platform = context([])
    assert {:ok, %{started: 1}} = ReadyPool.keep(pool(fake, [pin(@digest, platform)]))
    assert [ready] = ready_sessions()

    other = start_conversation!("wider-context", @digest, context(["docs"]))
    refute other.session.id == ready.id

    claim = start_conversation!("same-context", @digest, platform)
    assert claim.session.id == ready.id
    assert claim.session.repository_source == %{"kind" => "default"}
  end

  # A session started under another policy digest froze another model ladder
  # and other permissions: answering on it would run the conversation with
  # what the settings no longer say. It is never claimed, and the pool retires
  # it once that pin is no longer kept.
  test "a session kept ready for another pin is never claimed and is retired" do
    {:ok, fake} = FakeAPI.start_link([answer()])
    assert {:ok, %{started: 1}} = ReadyPool.keep(pool(fake, [pin(@other_digest)]))
    assert [stale] = ready_sessions()

    claim = start_conversation!("other-pin", @digest)

    refute claim.session.id == stale.id
    assert claim.session.ready_state == nil
    assert claim.session.coop_session_id == nil
    assert Repo.get!(Session, stale.id).ready_state == :ready

    assert {:ok, %{retired: 1}} = ReadyPool.keep(pool(fake, [pin(@digest)]))
    assert Repo.get!(Session, stale.id).ready_state == :retired
  end

  # A task binds its workspace when Coop creates its session, and a session
  # kept ready was created without one: a task that took it would run with
  # no workspace task at all.
  test "a task never takes a session kept ready" do
    {:ok, fake} = FakeAPI.start_link([answer()])
    assert {:ok, %{started: 1}} = ReadyPool.keep(pool(fake, [pin(@digest)]))
    assert [ready] = ready_sessions()

    command = admit!("task")

    assert {:ok, session} = WorkSessions.pin_episode(command.episode_id, @policy, @digest)

    refute session.id == ready.id
    assert Repo.get!(Session, ready.id).ready_state == :ready
  end

  # Nothing ends an open Coop session nobody prompts: a session kept ready
  # past its age, or one the setting no longer keeps, must be closed and
  # removed on its worker, or each would hold a workspace there for good.
  test "cleanup closes a session kept ready once it is past its age" do
    {:ok, fake} = FakeAPI.start_link([answer()])
    assert {:ok, %{started: 1}} = ReadyPool.keep(pool(fake, [pin(@digest)]))
    assert [aged] = ready_sessions()
    on_worker = FakeAPI.state(fake).session
    age_past_maximum!(aged)

    assert start_conversation!("aged", @digest).session.id != aged.id

    assert {:ok, %{retired: 1}} = ReadyPool.keep(pool(fake, []))
    assert cleaned_up?(on_worker, aged)
  end

  # Routing's own pool retires every ready session it does not recognise. It
  # read the Work sessions kept ready as its own and would have retired each
  # one the moment it was started.
  test "routing's pool leaves Work sessions kept ready alone" do
    {:ok, fake} = FakeAPI.start_link([answer()])
    assert {:ok, %{started: 1}} = ReadyPool.keep(pool(fake, [pin(@digest)]))
    assert [ready] = ready_sessions()

    assert ReadySessions.unusable([pin(@digest)]) == []
    assert Admission.ReadySessions.unusable(%{name: "admission", digest: @digest}, 0) == []
    assert Repo.get!(Session, ready.id).ready_state == :ready
  end

  # Only a pin a new conversation used is kept, and only the most used ones.
  test "the pins kept are the ones new conversations used most" do
    for suffix <- ~w(one two) do
      start_conversation!("most-#{suffix}", @digest)
    end

    start_conversation!("least", @other_digest)

    command = admit!("not-a-conversation", "schedule:nightly:#{Ecto.UUID.generate()}")
    assert {:ok, _session} = WorkSessions.pin_episode(command.episode_id, @policy, @digest)

    since = DateTime.add(Repo.now!(), -3_600, :second)
    assert ReadySessions.recent_pins(since) == [pin(@digest), pin(@other_digest)]
  end

  defp pin(digest, repository_context \\ nil) do
    ReadySessions.pin(
      %{
        authority_digest: nil,
        environment_ref: nil,
        policy: @policy,
        policy_digest: digest,
        repository_context: repository_context,
        repository_ref: repository_context && "repo:one",
        repository_source: repository_context && %{"kind" => "default"}
      },
      nil
    )
  end

  defp context(read_only_repositories) do
    %{
      "context_ref" => "platform",
      "parallel_goal_limit" => 2,
      "primary_repository" => "repo:one",
      "read_only_repositories" => read_only_repositories
    }
  end

  defp pool(fake, pins) do
    [
      api: FakeAPI,
      client: fake,
      operation_polls: 2,
      pins: fn _target -> {:ok, pins} end,
      sleep: fn _milliseconds -> :ok end,
      target: length(pins)
    ]
  end

  defp executor(fake) do
    [
      api: FakeAPI,
      client: fake,
      lease_seconds: 60,
      max_block_ms: 1_000,
      max_polls: 20,
      monotonic_ms: fn -> 0 end,
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end

  # A message starts a conversation: admission pins its episode with
  # `ready: true`, and a Work worker claims its first turn.
  defp start_conversation!(suffix, digest, repository_context \\ nil) do
    command = admit!(suffix)

    repository =
      if repository_context,
        do: [repository_ref: "repo:one", repository_context: repository_context],
        else: []

    assert {:ok, _session} =
             WorkSessions.pin_episode(
               command.episode_id,
               @policy,
               digest,
               [ready: true] ++ repository
             )

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60, :work)
    assert claim.episode.id == command.episode_id
    claim
  end

  defp admit!(suffix, key \\ nil) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: key || "ingress-input:#{suffix}:#{id}",
        native_input_id: "slack-message:#{suffix}:#{id}",
        occurred_at: @now,
        payload: %{"text" => "What does the README say?"},
        turn_ref: "turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    command
  end

  defp answer do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "The README describes the install steps.",
      "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
    })
  end

  defp ready_sessions do
    Repo.all(
      from(session in Session,
        where: session.execution_kind == :work and session.ready_state == :ready,
        order_by: [asc: session.inserted_at, asc: session.id]
      )
    )
  end

  defp age_past_maximum!(%Session{id: id}) do
    {1, nil} =
      Repo.update_all(from(session in Session, where: session.id == ^id),
        set: [
          # Past the hour a session kept ready may wait.
          inserted_at: DateTime.add(Repo.now!(), -2 * 60 * 60, :second)
        ]
      )
  end

  # Cleanup closes and removes the retired session on the worker that holds it.
  defp cleaned_up?(on_worker, session) do
    {:ok, cleanup} = RetentionAPI.start_link(sessions: [on_worker])

    drained =
      Enum.reduce_while(1..20, :busy, fn attempt, :busy ->
        case retention(cleanup, attempt) do
          {:ok, :idle} -> {:halt, :idle}
          {:ok, {:executed, _execution}} -> {:cont, :busy}
          other -> flunk("cleanup stopped: #{inspect(other)}")
        end
      end)

    drained == :idle and Repo.get!(Session, session.id).cleanup_status == :discarded and
      RetentionAPI.remote_session(cleanup, session.coop_session_id)["state"] == "discarded"
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
      worker_ref: "work-ready-cleanup:#{attempt}"
    )
  end
end
