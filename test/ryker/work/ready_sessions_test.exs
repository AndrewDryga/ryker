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

  # The tenant install, 2026-10-13: a Work create fetches every repository the environment mounts,
  # 17 there, and Coop took about 90 s for it, while a pass stops waiting for a create after a
  # minute. The session it left starting was retired once Coop had made it, and another started:
  # every ten minutes a create held the worker for 90 s, raced conversations' own creates, and no
  # session was ever ready for a first answer.
  test "a session Coop finishes creating after its pass stopped waiting is kept ready" do
    {:ok, fake} = FakeAPI.start_link([answer()], create_finishes_later: true)
    assert {:ok, %{started: 0}} = ReadyPool.keep(pool(fake, [pin(@digest)]))
    assert [%Session{ready_state: :starting}] = starting_sessions()

    FakeAPI.finish_creates(fake)
    assert {:ok, %{retired: 0}} = ReadyPool.keep(pool(fake, [pin(@digest)]))

    assert [%Session{ready_state: :ready, coop_session_id: coop_session_id}] = ready_sessions()
    assert is_binary(coop_session_id)
    assert starting_sessions() == []
    assert FakeAPI.state(fake).create_count == 1

    claim = start_conversation!("after-a-slow-create", @digest)
    assert claim.session.coop_session_id == coop_session_id
  end

  # The tenant install, 2026-10-13: a conversation's session closes 15 minutes after its answer,
  # and a follow-up after that waited four minutes for Coop to fetch the environment's 17
  # repositories again, although a session for the same pin stood ready. A conversation picked
  # up again takes it, as its next session.
  test "a conversation picked up again after its session's grace takes a session kept ready" do
    {:ok, fake} = FakeAPI.start_link([answer()])
    first = start_conversation!("picked-up-again", @digest)

    Repo.update_all(from(session in Session, where: session.id == ^first.session.id),
      set: [cleanup_status: :grace, discard_after: DateTime.add(Repo.now!(), -60, :second)]
    )

    assert {:ok, %{started: 1}} = ReadyPool.keep(pool(fake, [pin(@digest)]))
    assert [%Session{id: ready_id, coop_session_id: coop_session_id}] = ready_sessions()

    episode = Repo.get!(Episodes.Episode, first.episode.id)

    assert {:ok, {:ok, %Session{} = next}} =
             Repo.transaction(fn -> Custody.Sessions.current_session(episode) end)

    assert next.id == ready_id
    assert next.episode_id == episode.id
    assert next.generation == 2
    assert next.coop_session_id == coop_session_id
    assert ready_sessions() == []
    assert FakeAPI.state(fake).create_count == 1
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

  # The pool kept sessions ready only for the busiest pin, an environment's default repository,
  # and a conversation about another repository of the same environment created its own: its
  # first turn reached the worker after about 33 s instead of 4 s, for 17 of the 18 such
  # conversations on the pool's first day (2026-10-12). Every session of an environment mounts
  # all of its repositories and a conversation only reads them, so the session kept ready serves
  # it (Andrew: "any session should be able to serve any repo"), and the conversation keeps its own
  # repository for everything it recalls and records.
  test "a conversation about another repository of the environment answers on the session kept ready" do
    companion = %{
      "base_commit" => "41af103a96d71c93887fe2b4dc9eed2d75f8fcb7",
      "name" => "docs",
      "path" => "/coop/repositories/docs"
    }

    {:ok, fake} = FakeAPI.start_link([answer()], companions: [companion])
    platform = context(["docs"])
    assert {:ok, %{started: 1}} = ReadyPool.keep(pool(fake, [pin(@digest, platform)]))
    assert [ready] = ready_sessions()

    claim = start_conversation!("other-repository", @digest, platform, "docs")

    assert claim.session.id == ready.id
    assert claim.session.repository_ref == "docs"
    assert claim.session.repository_context == platform
    assert {:ok, %{status: :accepted, turn: turn}} = Executor.run(claim, executor(fake))
    assert get_in(turn.submission, ["context", "repository_ref"]) == "docs"
    assert get_in(turn.submission, ["context", "workspace", "primary", "name"]) == "repo:one"
    assert FakeAPI.state(fake).create_count == 1

    # The next conversation about either repository is kept ready for by the same pin.
    assert ReadySessions.recent_pins(DateTime.add(Repo.now!(), -3_600, :second)) ==
             [pin(@digest, platform)]
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
  # The tenant install, 2026-10-14: Coop takes about five minutes to create a Work session there.
  # The pool retired a pin's session at its hour and only then started the next, so each pin had
  # none for five minutes of every hour, and a first answer then waited for a whole create.
  test "a pin's next session starts before the hour, and the old one serves until then" do
    {:ok, fake} = FakeAPI.start_link([answer()], create_finishes_later: true)
    assert {:ok, %{started: 0}} = ReadyPool.keep(pool(fake, [pin(@digest)]))
    FakeAPI.finish_creates(fake)
    assert {:ok, %{opened: 1}} = ReadyPool.keep(pool(fake, [pin(@digest)]))
    assert [old] = ready_sessions()

    age!(old, 55 * 60)
    assert {:ok, %{retired: 0}} = ReadyPool.keep(pool(fake, [pin(@digest)]))
    assert [%Session{id: next_id}] = starting_sessions()
    assert next_id != old.id

    assert start_conversation!("while-the-next-starts", @digest).session.id == old.id

    FakeAPI.finish_creates(fake)
    assert {:ok, %{opened: 1, retired: 0}} = ReadyPool.keep(pool(fake, [pin(@digest)]))
    assert [%Session{id: ^next_id}] = ready_sessions()
    assert FakeAPI.state(fake).create_count == 2
  end

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
  # The tenant install, 2026-10-13: a pin counted for a day only. People there use Ryker now and
  # then, so the first conversation after a quiet day found nothing ready and waited for Coop to
  # fetch the environment's 17 repositories, four minutes and more, before its first answer.
  test "a pin a conversation used days ago is still kept ready, one past a week is not" do
    recent = start_conversation!("three-days-ago", @digest)
    stale = start_conversation!("nine-days-ago", @other_digest)
    now = Repo.now!()

    for {claim, days} <- [{recent, 3}, {stale, 9}] do
      Repo.update_all(from(session in Session, where: session.id == ^claim.session.id),
        set: [inserted_at: DateTime.add(now, -days * 86_400, :second)]
      )
    end

    assert ReadySessions.recent_pins() == [pin(@digest)]
  end

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
  defp start_conversation!(
         suffix,
         digest,
         repository_context \\ nil,
         repository_ref \\ "repo:one"
       ) do
    command = admit!(suffix)

    repository =
      if repository_context,
        do: [repository_ref: repository_ref, repository_context: repository_context],
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

  defp starting_sessions do
    Repo.all(
      from(session in Session,
        where: session.execution_kind == :work and session.ready_state == :starting
      )
    )
  end

  defp ready_sessions do
    Repo.all(
      from(session in Session,
        where: session.execution_kind == :work and session.ready_state == :ready,
        order_by: [asc: session.inserted_at, asc: session.id]
      )
    )
  end

  defp age!(%Session{id: id}, seconds) do
    {1, nil} =
      Repo.update_all(from(session in Session, where: session.id == ^id),
        set: [inserted_at: DateTime.add(Repo.now!(), -seconds, :second)]
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
