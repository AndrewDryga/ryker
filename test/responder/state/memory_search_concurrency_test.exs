defmodule Responder.State.MemorySearchConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.{CanonicalJSON, Episodes, Repo}
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Slack.ChannelFence
  alias Responder.State.{Behavior, Behaviors, Memories, MemoryEntry, MemorySearch, Record}
  alias Responder.Work.{Custody, Session, Turn}

  @captured "testdata/learning/retained-draft-ai-suggestions-learning.json"
  @search_secret "memory-search-concurrency-host-secret"
  @search_arguments %{
    "query" => "draft-ai-suggestions",
    "scope" => "workspace",
    "kinds" => ["fact", "continuity"],
    "limit" => 10,
    "cursor" => nil,
    "after" => nil,
    "before" => nil,
    "time_basis" => "changed"
  }

  test "a mixed page owns its session and channel before it writes a memory row" do
    # The reverse order lets result acceptance (session first) or channel
    # deletion (fence first) wait on accounting while search waits on them.
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, fixture} = Repo.transaction(fn -> fixture!(:fact) end)
      parent = self()

      blocker =
        hold_lock(parent, fn ->
          Repo.one!(from(e in MemoryEntry, where: e.id == ^fixture.entry.id, lock: "FOR UPDATE"))
        end)

      try do
        assert_receive {:lock_held, blocker_backend}, 5_000
        reader = search_task(parent, fixture)

        try do
          assert_receive {:search_started, reader_backend}, 5_000
          await_blocked_by(reader_backend, blocker_backend)
          held = %{session: probe_session(fixture.session_id), channel: probe_channel(fixture)}
          send(blocker.pid, :release_lock)
          assert {:ok, :released} = Task.await(blocker)
          assert {:ok, %{"memories" => [_]}} = Task.await(reader)
          assert held == %{session: :busy, channel: :busy}
        after
          stop_tasks([reader])
        end
      after
        stop_tasks([blocker])
        cleanup(fixture)
      end
    end)
  end

  test "a channel-fence timeout returns an explicit search budget error without accounting" do
    # ChannelFence uses Repo.query/3, not query!/3. Its nested Postgrex error
    # must not become an empty lane followed by an aborted-transaction crash.
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, fixture} = Repo.transaction(fn -> fixture!(:fact) end)
      parent = self()

      blocker =
        hold_lock(parent, fn ->
          :ok = ChannelFence.authorize_in_transaction("slack", fixture.context.conversation_ref)
        end)

      try do
        assert_receive {:lock_held, blocker_backend}, 5_000
        reader = search_task(parent, fixture)

        try do
          assert_receive {:search_started, reader_backend}, 5_000
          await_blocked_by(reader_backend, blocker_backend)
          result = Task.await(reader, 8_000)
          send(blocker.pid, :release_lock)
          assert {:ok, :released} = Task.await(blocker)
          assert result == {:error, :memory_search_budget_exceeded}
          assert Repo.get!(MemoryEntry, fixture.entry.id).recall_count == 0
        after
          stop_tasks([reader])
        end
      after
        stop_tasks([blocker])
        cleanup(fixture)
      end
    end)
  end

  test "a busy session fails before search changes any recall accounting" do
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, fixture} = Repo.transaction(fn -> fixture!(:fact) end)
      parent = self()

      blocker =
        hold_lock(parent, fn ->
          Repo.one!(from(s in Session, where: s.id == ^fixture.session_id, lock: "FOR UPDATE"))
        end)

      try do
        assert_receive {:lock_held, _backend}, 5_000
        reader = search_task(parent, fixture)

        try do
          assert {:error, :memory_search_budget_exceeded} = Task.await(reader)
          assert Repo.get!(MemoryEntry, fixture.entry.id).recall_count == 0
        after
          stop_tasks([reader])
        end
      after
        send(blocker.pid, :release_lock)
        Task.await(blocker)
        cleanup(fixture)
      end
    end)
  end

  for changed <- [:expired_lease, :replaced_lease, :superseded_turn, :closed_session] do
    test "a binding with #{changed} cannot disclose or account a memory" do
      # Binding.resolve is a preflight read. Search must recheck the row after
      # obtaining its session lock because ownership may have changed meanwhile.
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, fixture} = Repo.transaction(fn -> fixture!(:fact) end)

        try do
          case unquote(changed) do
            :expired_lease ->
              Repo.update_all(from(t in Turn, where: t.id == ^fixture.turn_id),
                set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1)]
              )

            :replaced_lease ->
              Repo.update_all(from(t in Turn, where: t.id == ^fixture.turn_id),
                set: [lease_ref: Ecto.UUID.generate()]
              )

            :superseded_turn ->
              Repo.update_all(from(t in Turn, where: t.id == ^fixture.turn_id),
                set: [
                  status: :superseded,
                  lease_ref: nil,
                  lease_owner: nil,
                  lease_expires_at: nil
                ]
              )

            :closed_session ->
              Repo.update_all(from(s in Session, where: s.id == ^fixture.session_id),
                set: [cleanup_status: :close_pending]
              )
          end

          assert {:error, :state_tools_binding_not_authorized} =
                   MemorySearch.search(fixture.binding, @search_arguments, @search_secret)

          assert Repo.get!(MemoryEntry, fixture.entry.id).recall_count == 0
        after
          cleanup(fixture)
        end
      end)
    end
  end

  for {kind, readers, statuses} <- [
        {:fact, [:recall, :search], [:deleted]},
        {:guidance, [:recall, :search], [:disabled, :deleted]}
      ],
      reader <- readers,
      status <- statuses do
    test "#{kind} #{reader} cannot return or count a concurrently #{status} entry" do
      # A forgotten or disabled row was selected while still visible in MVCC,
      # then its accounting UPDATE waited for the revocation and returned the
      # pre-revocation prose. The model can therefore receive text an operator
      # already removed. Synchronize that exact window with PostgreSQL blockers,
      # not sleeps or a replacement retrieval implementation in the test.
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, fixture} = Repo.transaction(fn -> fixture!(unquote(kind)) end)

        try do
          documents =
            concurrent_revoke_and_read(fixture, unquote(kind), unquote(reader), unquote(status))

          saved = Repo.get!(fixture.schema, fixture.entry.id)

          assert %{
                   documents: [],
                   count: 0,
                   recalled_at: nil,
                   status: unquote(status)
                 } == %{
                   documents: documents,
                   count: Map.fetch!(saved, fixture.counter),
                   recalled_at: Map.fetch!(saved, fixture.recalled_at),
                   status: saved.status
                 }

          refute inspect(documents) =~ fixture.text
        after
          cleanup(fixture)
        end
      end)
    end
  end

  defp concurrent_revoke_and_read(fixture, kind, reader, status) do
    parent = self()

    revoker =
      unboxed_task(fn ->
        Repo.transaction(fn ->
          assert {:ok, revoked} = revoke(kind, fixture.entry, status)
          assert revoked.status == status
          send(parent, {:revoked_uncommitted, backend_pid()})

          receive do
            :commit_revocation -> :ok
          after
            5_000 -> flunk("revocation was never released")
          end
        end)
      end)

    try do
      assert_receive {:revoked_uncommitted, revoker_backend}, 5_000

      recall =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            send(parent, {:reader_started, backend_pid()})
            read(kind, reader, fixture.context)
          end)
        end)

      try do
        assert_receive {:reader_started, reader_backend}, 5_000
        await_blocked_by(reader_backend, revoker_backend)
        send(revoker.pid, :commit_revocation)
        assert {:ok, :ok} = Task.await(revoker)
        assert {:ok, documents} = Task.await(recall)
        documents
      after
        stop_tasks([recall])
      end
    after
      stop_tasks([revoker])
    end
  end

  defp hold_lock(parent, lock) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        lock.()
        send(parent, {:lock_held, backend_pid()})

        receive do
          :release_lock -> :released
        after
          10_000 -> flunk("test lock was never released")
        end
      end)
    end)
  end

  defp search_task(parent, fixture) do
    unboxed_task(fn ->
      send(parent, {:search_started, backend_pid()})

      try do
        MemorySearch.search(fixture.binding, @search_arguments, @search_secret)
      rescue
        error in Postgrex.Error -> {:raised, error.postgres[:code]}
      end
    end)
  end

  defp probe_session(id) do
    Repo.transaction(fn ->
      Repo.one!(from(s in Session, where: s.id == ^id, lock: "FOR UPDATE NOWAIT"))
      :free
    end)
    |> case do
      {:ok, state} -> state
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :lock_not_available,
        do: :busy,
        else: reraise(error, __STACKTRACE__)
  end

  defp probe_channel(fixture) do
    "slack:" <> workspace = fixture.context.workspace_ref
    key = "slack-configuration:#{workspace}:CSOURCE"

    assert {:ok, locked} =
             Repo.transaction(fn ->
               %{rows: [[locked]]} =
                 Repo.query!("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))", [key])

               locked
             end)

    if locked, do: :free, else: :busy
  end

  defp revoke(:fact, entry, :deleted), do: Memories.forget(entry.ref, entry.workspace_ref)

  defp revoke(:guidance, entry, status),
    do: Behaviors.set_status(entry.ref, status, entry.workspace_ref)

  defp read(:fact, :recall, context), do: Memories.recall(context)

  defp read(:fact, :search, context),
    do: Memories.search(context, "draft-ai-suggestions", "workspace", 10)

  defp read(:guidance, :recall, context), do: Behaviors.guidance(context)

  defp read(:guidance, :search, context),
    do: Behaviors.search_guidance(context, "draft-ai-suggestions", "workspace", 10)

  defp fixture!(kind) do
    # These are structural confirmed-store rows with real offer/turn/session/
    # episode foreign keys, not a claim that a human confirmed this historical
    # summary. The text is the unchanged captured public model result.
    captured = @captured |> File.read!() |> Jason.decode!()

    text =
      captured["result"]
      |> Jason.decode!()
      |> Map.fetch!("updates")
      |> hd()
      |> Map.fetch!("summary")

    id = Ecto.UUID.generate()
    workspace = "slack:TMEMRACE#{System.unique_integer([:positive])}"
    conversation = "#{workspace}:CSOURCE"
    now = DateTime.utc_now()
    confirmed_at = DateTime.add(now, -60)

    assert {:ok, %{episode: episode}} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "memory-revocation:#{id}",
                 native_input_id: "memory-revocation-input:#{id}",
                 turn_ref: "memory-revocation-turn:#{id}",
                 occurred_at: confirmed_at,
                 payload: captured["input"]["content"],
                 destination: %{
                   transport: "slack",
                   conversation_ref: conversation,
                   thread_ref: nil
                 }
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(episode.id, "structural-memory-race", String.duplicate("a", 64))

    turn =
      Repo.insert!(%Turn{
        id: Ecto.UUID.generate(),
        episode_id: episode.id,
        session_id: session.id,
        turn_ref: episode.owner_ref,
        status: :pending,
        lease_ref: Ecto.UUID.generate(),
        lease_owner: "structural-memory-search",
        lease_expires_at: DateTime.add(now, 300)
      })

    payload = %{
      "expires_in" => "30d",
      "repository" => nil,
      "scope" => "workspace",
      "subject" => "draft-ai-suggestions",
      "visibility" => "workspace"
    }

    {offer_kind, payload} =
      case kind do
        :fact ->
          {"memory_offer",
           Map.merge(payload, %{"kind" => "entity_relationship", "value" => text})}

        :guidance ->
          {"guidance_offer", Map.merge(payload, %{"summary" => text, "text" => text})}
      end

    offer =
      Repo.insert!(%Record{
        id: Ecto.UUID.generate(),
        episode_id: episode.id,
        turn_id: turn.id,
        ref: "record:#{offer_kind}:#{id}",
        operation_id: "memory-revocation-offer:#{id}",
        kind: offer_kind,
        status: :confirmed,
        payload: payload,
        payload_fingerprint: CanonicalJSON.digest(payload),
        confirmation_ref: "structural-confirmation:#{id}",
        confirmed_at: confirmed_at,
        confirmed_by_actor_ref: "slack:user:UCONFIRMER"
      })

    attributes = %{
      id: id,
      offer_record_id: offer.id,
      status: :active,
      workspace_ref: workspace,
      scope_kind: :workspace,
      scope_ref: workspace,
      confirmed_by_actor_ref: "slack:user:UCONFIRMER",
      confirmation_ref: "structural-confirmation:#{id}",
      confirmed_at: confirmed_at,
      source_transport: "slack",
      source_conversation_ref: conversation,
      source_thread_ref: nil,
      source_message_ref: "1788628764.248029",
      payload: payload,
      expires_at: DateTime.add(now, 3600),
      inserted_at: confirmed_at,
      updated_at: confirmed_at
    }

    {entry, counter, recalled_at} =
      case kind do
        :fact ->
          entry =
            Repo.insert!(
              struct!(
                MemoryEntry,
                Map.merge(attributes, %{
                  ref: "memory:#{id}",
                  kind: :entity_relationship,
                  subject: "draft-ai-suggestions",
                  visibility: :workspace,
                  payload_fingerprint: CanonicalJSON.digest(payload)
                })
              )
            )

          {entry, :recall_count, :last_recalled_at}

        :guidance ->
          entry =
            Repo.insert!(
              struct!(
                Behavior,
                Map.merge(attributes, %{
                  ref: "behavior:#{id}",
                  kind: :guidance,
                  identity_key: CanonicalJSON.digest(id)
                })
              )
            )

          {entry, :use_count, :last_used_at}
      end

    context = %{workspace_ref: workspace, conversation_ref: conversation, repository: nil}

    context =
      if kind == :guidance,
        do: Map.put(context, :operator_ref, "slack:user:UCONFIRMER"),
        else: context

    %{
      entry: entry,
      schema: entry.__struct__,
      counter: counter,
      recalled_at: recalled_at,
      text: text,
      context: context,
      episode_id: episode.id,
      session_id: session.id,
      turn_id: turn.id,
      offer_id: offer.id,
      binding: %{episode: episode, session: session, turn: turn}
    }
  end

  defp cleanup(fixture) do
    Repo.delete_all(from(e in fixture.schema, where: e.id == ^fixture.entry.id))
    Repo.delete_all(from(r in Record, where: r.id == ^fixture.offer_id))
    Repo.delete_all(from(t in Turn, where: t.id == ^fixture.turn_id))
    Repo.delete_all(from(s in Session, where: s.id == ^fixture.session_id))
    Repo.delete_all(from(e in Event, where: e.episode_id == ^fixture.episode_id))
    Repo.delete_all(from(e in Episode, where: e.id == ^fixture.episode_id))
  end
end
