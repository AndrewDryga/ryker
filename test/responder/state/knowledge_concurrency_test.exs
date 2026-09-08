defmodule Responder.State.KnowledgeConcurrencyTest do
  use Responder.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Episodes.Episode
  alias Responder.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Responder.Fixtures.Learning, as: LearningFixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.RecallText
  alias Responder.Repo
  alias Responder.Slack.ChannelMembership

  alias Responder.State.{
    ConversationKnowledge,
    ConversationObservation,
    Knowledge,
    KnowledgeRevision,
    KnowledgeSource,
    Learning,
    LearningRun,
    LearningSources
  }

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}

  test "simultaneous differently named creates must reconsider the winner in the same scope" do
    # The replay produced one memory per message about the same subject. A
    # different proposed key cannot bypass matching while another create commits.
    # These are constructed host-contract results using retained alert text,
    # not a claim that either candidate was captured from a model.
    Sandbox.unboxed_run(Repo, fn ->
      [first_entry, second_entry] = entries = LearningFixtures.inputs!()
      assert {:ok, first_run} = Learning.prepare([first_entry.id], @policy)
      assert {:ok, second_run} = Learning.prepare([second_entry.id], @policy)
      assert first_run.knowledge == []
      assert second_run.knowledge == []
      parent = self()

      first =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            :ok = Knowledge.lock_scope_in_transaction(first_entry, first_entry.repository_ref)
            send(parent, {:create_locked, backend_pid()})

            receive do
              :commit_create ->
                LearningFixtures.accept(
                  first_run.id,
                  create_result(first_entry, "first-name"),
                  %{}
                )
            end
          end)
        end)

      assert_receive {:create_locked, first_backend}, 5000

      second =
        unboxed_task(fn ->
          send(parent, {:competing_create, backend_pid()})

          LearningFixtures.accept(
            second_run.id,
            create_result(second_entry, "different-name"),
            %{}
          )
        end)

      try do
        assert_receive {:competing_create, second_backend}, 5000
        await_blocked_by(second_backend, first_backend)
        send(first.pid, :commit_create)
        assert {:ok, {:ok, %{status: :applied}}} = Task.await(first)
        assert {:error, :learning_match_required} = Task.await(second)

        assert [head] = Knowledge.context(first_entry, first_entry.repository_ref)
        assert head["topic_key"] == "first-name"
        rejected = Repo.get!(LearningRun, second_run.id)
        assert rejected.status == :rejected
        assert rejected.match_refs == [head["source_ref"]]
        assert length(Knowledge.history(head["source_ref"])) == 1
        assert {:ok, retried} = Learning.prepare([second_entry.id], @policy)
        assert retried.knowledge == [head]
      after
        stop_tasks([first, second])
        cleanup_learning(entries)
      end
    end)
  end

  for count <- [8, 9] do
    test "#{count} known subjects sharing an anchor preserve the matching boundary" do
      # Generic anchors are not unique identities: one allocation may support
      # several topics. Structural cardinality setup repeats the retained alert,
      # without pretending these are distinct captured model judgments.
      Sandbox.unboxed_run(Repo, fn ->
        [first, second] = entries = LearningFixtures.inputs!()

        try do
          for n <- 1..unquote(count) do
            proposal = create_proposal(first, "known-subject-#{n}")

            assert {:ok, :ok} =
                     Repo.transaction(fn ->
                       KnowledgeFixtures.record_topic(
                         first,
                         Map.drop(proposal, ~w(action source_input_ids)),
                         []
                       )
                     end)
          end

          assert {:ok, run} = Learning.prepare([second.id], @policy)
          assert length(run.knowledge) == 8
          result = LearningFixtures.accept(run.id, create_result(second, "another-subject"), %{})

          if unquote(count) == 9 do
            assert {:error, :knowledge_match_ambiguous} = result
            assert Repo.get!(LearningRun, run.id).error_code == "knowledge_match_ambiguous"
            assert Repo.aggregate(ConversationKnowledge, :count) == 9
            assert Repo.aggregate(KnowledgeRevision, :count) == 9
          else
            # The model has seen all eight alternatives, so a distinct subject
            # is still permitted. The host must not make an anchor a unique key.
            assert {:ok, %{status: :applied}} = result
            assert Repo.aggregate(ConversationKnowledge, :count) == 9
            assert Repo.aggregate(KnowledgeRevision, :count) == 9
          end
        after
          cleanup_learning(entries)
        end
      end)
    end
  end

  defp create_result(entry, key),
    do:
      Jason.encode!(%{
        "updates" => [create_proposal(entry, key)],
        "reason" => "Host-contract matching boundary over a retained alert."
      })

  defp create_proposal(entry, key),
    do: %{
      "action" => "create",
      "source_input_ids" => [entry.id],
      "topic_key" => key,
      "title" => "Website HAProxy memory limit",
      "summary" => entry.content |> RecallText.from() |> String.slice(0, 1200),
      "topics" => ["website", "haproxy-edge", "Host OOM kills"],
      "anchors" => ["311e38f3-a17c-7d1b-1235-05c256ba3c39"],
      "target_ref" => nil,
      "expected_version" => 0
    }

  defp cleanup_learning(entries) do
    ids = Enum.map(entries, & &1.id)

    run_ids =
      Repo.all(
        from(r in LearningRun,
          where:
            fragment(
              "EXISTS (SELECT 1 FROM jsonb_array_elements(?::jsonb) i WHERE i->>'source_input_id' = ANY(?::text[]))",
              r.inputs,
              ^ids
            ),
          select: r.id
        )
      )

    Repo.delete_all(from(s in Responder.Work.Session, where: s.learning_run_id in ^run_ids))
    Repo.delete_all(from(r in LearningRun, where: r.id in ^run_ids))
    Repo.delete_all(from(k in ConversationKnowledge, where: k.source_input_id in ^ids))
    Repo.delete_all(from(o in ConversationObservation, where: o.source_input_id in ^ids))
    Repo.delete_all(from(e in Entry, where: e.id in ^ids))
    Repo.delete_all(from(e in Responder.Episodes.Event, where: e.episode_id in ^ids))
    Repo.delete_all(from(e in Episode, where: e.id in ^ids))
  end

  test "cross-channel updates serialize instead of deadlocking shared recall lock upgrades" do
    # Both classifiers were offered both public topics, then each updated its own.
    Sandbox.unboxed_run(Repo, fn ->
      workspace = "TKUPDATE#{System.unique_integer([:positive])}"

      destinations =
        Enum.map(["CA", "CB"], fn channel ->
          Repo.insert!(%ChannelMembership{
            id: Ecto.UUID.generate(),
            workspace_ref: workspace,
            channel_ref: channel,
            private: false,
            external_shared: false,
            generation: 1,
            status: :joined,
            joined_at: DateTime.utc_now()
          })

          %Episode{
            destination_transport: "slack",
            destination_conversation_ref: "slack:#{workspace}:#{channel}"
          }
        end)

      [{entry_a, item_a}, {entry_b, item_b}] =
        Enum.map(destinations, fn destination ->
          {entry, _} = KnowledgeFixtures.learn!(destination)
          item = Enum.find(Knowledge.context(destination, nil), & &1["can_update"])
          {entry, item}
        end)

      offered_a = Knowledge.context(entry_a, nil)
      offered_b = Knowledge.context(entry_b, nil)
      assert length(offered_a) == 2
      parent = self()

      first =
        unboxed_task(fn ->
          safely_update(fn ->
            :ok = Knowledge.reauthorize(entry_a, nil, offered_a)
            send(parent, {:first_locked, backend_pid()})

            receive do: (:update ->
                           Responder.Fixtures.Knowledge.record_topic(
                             entry_a,
                             proposal(item_a),
                             offered_a
                           ))
          end)
        end)

      assert_receive {:first_locked, first_backend}, 5000

      second =
        unboxed_task(fn ->
          safely_update(fn ->
            send(parent, {:second_started, backend_pid()})

            with :ok <- Knowledge.reauthorize(entry_b, nil, offered_b) do
              Responder.Fixtures.Knowledge.record_topic(entry_b, proposal(item_b), offered_b)
            end
          end)
        end)

      try do
        assert_receive {:second_started, second_backend}, 5000
        await_blocked_by(second_backend, first_backend)
        send(first.pid, :update)
        results = [Task.await(first), Task.await(second)]

        assert Enum.sort(results) ==
                 Enum.sort([{:ok, :ok}, {:ok, {:error, {:admission_rejected, :context_stale}}}])
      after
        stop_tasks([first, second])
        scope = "slack:#{workspace}"
        Repo.delete_all(from(k in ConversationKnowledge, where: k.workspace_ref == ^scope))
        Repo.delete_all(from(o in ConversationObservation, where: o.workspace_ref == ^scope))
        Repo.delete_all(from(m in ChannelMembership, where: m.workspace_ref == ^workspace))
      end
    end)
  end

  defp safely_update(function) do
    Repo.transaction(function)
  rescue
    error in Postgrex.Error -> {:crashed, error.postgres[:code]}
  end

  defp proposal(item),
    do:
      item
      |> Map.take(~w(topic_key title summary topics))
      |> Map.merge(%{
        "target_ref" => item["source_ref"],
        "anchors" => [],
        "expected_version" => item["version"]
      })

  for action <- [:edit, :delete], boundary <- [:recall, :reauthorize] do
    test "#{boundary} cannot reuse a source changed by #{action} while waiting for its row lock" do
      # A source-channel edit can race another channel's Work briefing/search.
      # READ COMMITTED must validate the locked source, not its pre-lock snapshot.
      Sandbox.unboxed_run(Repo, fn ->
        workspace = "TKNOWRACE#{System.unique_integer([:positive])}"
        now = DateTime.utc_now()

        for channel <- ["CSOURCE", "CTARGET"] do
          Repo.insert!(%ChannelMembership{
            id: Ecto.UUID.generate(),
            workspace_ref: workspace,
            channel_ref: channel,
            private: false,
            external_shared: false,
            generation: 1,
            status: :joined,
            joined_at: now
          })
        end

        id = Ecto.UUID.generate()

        note = %{
          "summary" =>
            "U03EPT4RP5M wants to keep `draft-ai-suggestions` and plans to look into it at an unspecified future time.",
          "topics" => ["draft-ai-suggestions"]
        }

        source =
          Repo.insert!(%ConversationObservation{
            id: id,
            identity_key: id,
            source_input_id: id,
            transport: "slack",
            workspace_ref: "slack:#{workspace}",
            conversation_ref: "slack:#{workspace}:CSOURCE",
            visibility: :public,
            source_message_ref: "1787832000.000100",
            source_result_ref: "recorded-result",
            source_fingerprint: String.duplicate("a", 64),
            actor_ref: "U03EPT4RP5M",
            execution_mode: :shadow,
            revision: 1,
            occurred_at: now,
            note: note
          })

        item =
          Repo.insert!(%ConversationKnowledge{
            id: Ecto.UUID.generate(),
            scope_key: id,
            topic_key: "draft-ai-suggestions",
            transport: "slack",
            workspace_ref: source.workspace_ref,
            conversation_ref: source.conversation_ref,
            visibility: :public,
            state: Map.put(note, "title", "Keep draft-ai-suggestions"),
            version: 1,
            source_generation: 1,
            source_dependencies: [],
            source_input_id: id,
            latest_source_at: now
          })

        [receipt] = LearningSources.for_source(source)

        Repo.insert!(%KnowledgeSource{
          knowledge_id: item.id,
          observation_id: id,
          generation: 1,
          receipt: receipt,
          receipt_fingerprint: Responder.CanonicalJSON.digest(receipt),
          direct_support_version: 1,
          source_revision: 1,
          source_fingerprint: source.source_fingerprint,
          source_note: note,
          retained_at: source.updated_at,
          introduced_version: 1
        })

        target = %{
          destination_transport: "slack",
          destination_conversation_ref: "slack:#{workspace}:CTARGET",
          destination_thread_ref: nil
        }

        frozen = Knowledge.context(target, nil)
        assert length(frozen) == 1
        parent = self()

        blocker =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              Repo.one!(
                from(o in ConversationObservation, where: o.id == ^id, lock: "FOR UPDATE")
              )

              send(parent, {:locked, backend_pid()})

              receive do
                :change_source ->
                  if unquote(action) == :delete,
                    do: Repo.delete_all(from(o in ConversationObservation, where: o.id == ^id)),
                    else:
                      Repo.update_all(from(o in ConversationObservation, where: o.id == ^id),
                        # An authenticated edit advances the raw revision fence.
                        # Clearing only a derived note is not a source edit.
                        set: [
                          note: nil,
                          revision: 2,
                          source_fingerprint: String.duplicate("b", 64)
                        ]
                      )
              end
            end)
          end)

        assert_receive {:locked, blocker_backend}, 5000

        reader =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              Repo.query!("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
              send(parent, {:reader, backend_pid()})

              if unquote(boundary) == :recall,
                do: Knowledge.context(target, nil),
                else: Knowledge.reauthorize(target, nil, frozen)
            end)
          end)

        try do
          assert_receive {:reader, reader_backend}, 5000
          await_blocked_by(reader_backend, blocker_backend)
          send(blocker.pid, :change_source)
          Task.await(blocker)

          expected =
            if unquote(boundary) == :recall,
              do: [],
              else: {:error, {:admission_rejected, :context_stale}}

          assert Task.await(reader) == {:ok, expected}
        after
          stop_tasks([blocker, reader])
          Repo.delete_all(from(k in ConversationKnowledge, where: k.id == ^item.id))
          Repo.delete_all(from(o in ConversationObservation, where: o.id == ^id))
          Repo.delete_all(from(m in ChannelMembership, where: m.workspace_ref == ^workspace))
        end
      end)
    end
  end
end
