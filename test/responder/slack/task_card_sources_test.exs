defmodule Responder.Slack.TaskCardSourcesTest do
  use Responder.DataCase, async: false
  alias Responder.{Episodes, Repo}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Responder.Fixtures.Learning, as: LearningFixtures

  alias Responder.Slack.{
    InteractionAudit,
    InteractionRepaint,
    Renderer,
    TaskCard,
    TaskCardProjection,
    TaskCardWorker
  }

  alias Responder.State.{
    ConversationObservation,
    KnowledgeSnapshot,
    Observations,
    Record,
    Records
  }

  alias Responder.Work.{Custody, Session}

  @captured Jason.decode!(File.read!("testdata/learning/recorded-private-source-citation.json"))
  @conversation "slack:T01J1LW4DF1:C08MMETA3U3"

  defmodule API do
    def update_message(agent, _channel, _message, document, _ref) do
      {:ok, _rendered} = Renderer.render(document)
      Agent.update(agent, &(&1 ++ [document]))
      :ok
    end
  end

  for owner <- [:offer, :progress] do
    test "the Slack worker replaces withdrawn #{owner} text with a neutral card" do
      # Exact captured public citation text, with structural task/goal/progress
      # lifecycle. This is publication custody, not an invented model scenario.
      fixture = fixture!(unquote(owner))
      client = start_supervised!({Agent, fn -> [] end})
      options = options(client)
      assert {:ok, {:updated, _}} = TaskCardWorker.run_once(options)
      assert [before] = Agent.get(client, & &1)
      assert Jason.encode!(before) =~ @captured["arguments"]["observation"]

      KnowledgeFixtures.revoke!(fixture.source)
      card = Repo.get!(TaskCard, fixture.card.id)
      Repo.update!(Ecto.Changeset.change(card, card_checked_at: ~U[2000-01-01 00:00:00.000000Z]))
      assert {:ok, {:updated, _}} = TaskCardWorker.run_once(options)
      assert Agent.get(client, &length/1) == 2
      assert [^before, after_withdrawal] = Agent.get(client, & &1)
      assert_neutral(after_withdrawal)

      assert {:ok, audit} = TaskCardProjection.build(fixture.offer)
      assert Jason.encode!(audit.document) =~ @captured["arguments"]["observation"]
      assert Repo.get!(Record, fixture.offer.id).payload == fixture.offer.payload
    end
  end

  test "interaction repaint shares the withdrawn-source publication fence" do
    fixture = fixture!(:progress)
    KnowledgeFixtures.revoke!(fixture.source)
    client = start_supervised!({Agent, fn -> [] end})

    audit = %InteractionAudit{
      workspace_ref: fixture.card.workspace_ref,
      channel_ref: fixture.card.channel_ref,
      message_ref: fixture.card.message_ref,
      thread_ref: fixture.card.thread_ref
    }

    assert :ok = InteractionRepaint.repaint(audit, %{api: API, client: client})
    assert [document] = Agent.get(client, & &1)
    assert_neutral(document)
  end

  test "a withdrawn wait question is not copied into public action-needed text" do
    fixture = fixture!(:progress)

    assert {:ok, question} =
             Records.create(
               Records.token(fixture.task.turn),
               "captured-question",
               "input_request",
               %{
                 "question" => @captured["arguments"]["observation"],
                 "choices" => ["Review evidence"]
               }
             )

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: fixture.task.episode.key,
                 expected_turn_ref: fixture.task.episode.owner_ref,
                 wait_ref: question.ref
               })
             )

    assert {:ok, before} = TaskCardProjection.build(fixture.card)
    assert before.document["task_card"]["action_needed"] == @captured["arguments"]["observation"]
    KnowledgeFixtures.revoke!(fixture.source)
    assert {:ok, after_withdrawal} = TaskCardProjection.build(fixture.card)
    assert_neutral(after_withdrawal.document)
  end

  test "missing producer attestation is not authority to publish retained task text" do
    fixture = fixture!(:offer)

    fixture.producer.session
    |> Ecto.Changeset.change(source_exposure_count: nil, knowledge_exposure_count: nil)
    |> Repo.update!()

    assert {:ok, projection} = TaskCardProjection.build(fixture.card)
    assert_neutral(projection.document)
  end

  test "a task card cannot disclose its source to a different Slack destination" do
    fixture = fixture!(:offer)
    assert {:ok, projection} = TaskCardProjection.build(%{fixture.card | channel_ref: "COTHER"})
    assert_neutral(projection.document)
  end

  test "public blocked status does not echo raw dynamic error detail" do
    fixture = fixture!(:progress)

    fixture.task.turn
    |> Ecto.Changeset.change(
      status: :blocked,
      last_error_code: "work_execution_failed",
      last_error_detail: @captured["arguments"]["observation"],
      lease_ref: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      next_attempt_at: nil
    )
    |> Repo.update!()

    assert {:ok, projection} = TaskCardProjection.build(fixture.card)
    action = projection.document["task_card"]["action_needed"]
    refute action =~ @captured["arguments"]["observation"]
    assert action =~ "operator attention"
  end

  defp assert_neutral(document) do
    source_exposed? = Jason.encode!(document) =~ @captured["arguments"]["observation"]
    refute source_exposed?
    task = document["task_card"]
    assert task["title"] == "Engineering task"
    assert task["summary"] =~ "source context"
    assert task["request"] == nil
    # The stage list survives with every disposition withheld: an unreadable
    # source is unknown progress, not a task that never started.
    assert Enum.map(task["stages"], & &1["state"]) == List.duplicate("unknown", 7)
    assert Enum.all?(task["stages"], &(&1["subtasks"] == [] and is_nil(&1["detail"])))
    assert task["publication"] == nil
    assert task["controls"] -- ~w(stop close timeline) == []
    assert {:ok, _} = Renderer.render(document)
  end

  defp fixture!(owner) do
    raw =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> hd()

    source = LearningFixtures.retained_input!(raw, %{policy: "fixture", policy_digest: digest()})

    assert {:ok, :ok} =
             Repo.transaction(fn -> Observations.record_excerpt_in_transaction(source) end)

    document =
      source.id |> then(&Repo.get!(ConversationObservation, &1)) |> Observations.document()

    producer = claim!("task-source")
    task = claim!("task-work")

    assert :ok = KnowledgeSnapshot.expose(producer, if(owner == :offer, do: [document], else: []))
    assert :ok = KnowledgeSnapshot.expose(task, if(owner == :progress, do: [document], else: []))

    assert {:ok, offered} =
             Records.create(Records.token(producer.turn), "captured-task", "task_offer", %{
               "kind" => "engineering",
               "repository" => "blitz-infra",
               "title" => @captured["arguments"]["subject"],
               "prompt" => @captured["arguments"]["observation"]
             })

    offer =
      offered
      |> Ecto.Changeset.change(
        status: :confirmed,
        confirmed_episode_id: task.episode.id,
        confirmed_at: DateTime.utc_now(),
        confirmed_by_actor_ref: "slack:user:fixture",
        confirmation_ref: "captured-task-confirmation"
      )
      |> Repo.update!()

    assert {:ok, _} =
             Records.create(Records.token(task.turn), "captured-progress", "progress", %{
               "phase" => "working",
               "summary" => @captured["arguments"]["observation"]
             })

    goal =
      "priv/card_lab/legacy_task_records.json"
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["portal_goals", "goals"])
      |> hd()
      |> Map.take(~w(id requested_outcome completion_contract))
      |> Map.merge(%{
        "authority" => "read_only",
        "kind" => "check",
        "required" => false,
        "stage" => "self_review"
      })

    assert {:ok, _} = Records.create(Records.token(task.turn), "captured-goal", "goal", goal)

    card =
      Repo.insert!(%TaskCard{
        id: Ecto.UUID.generate(),
        record_id: offer.id,
        episode_id: task.episode.id,
        ref: "task-card:#{offer.id}",
        workspace_ref: "T01J1LW4DF1",
        channel_ref: "C08MMETA3U3",
        thread_ref: task.episode.destination_thread_ref,
        message_ref: "1787832001.000200"
      })

    %{
      source: source,
      producer: %{producer | session: Repo.get!(Session, producer.session.id)},
      task: task,
      offer: offer,
      card: card
    }
  end

  defp claim!(suffix) do
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "task-card-source:#{id}",
                 native_input_id: "source:#{id}",
                 turn_ref: "turn:#{id}",
                 payload: %{"text" => "Continue the investigation."},
                 destination: %{
                   transport: "slack",
                   conversation_ref: @conversation,
                   thread_ref: suffix
                 }
               })
             )

    assert {:ok, _} = Custody.pin_episode(id, "fixture", digest(), nil, "blitz-infra")
    assert {:ok, claim} = Custody.claim_next("worker:#{id}", 60, :work)
    claim
  end

  defp digest, do: String.duplicate("a", 64)

  defp options(client),
    do: %{
      api: API,
      client: client,
      worker_ref: "source-card",
      lease_seconds: 300,
      retry_base_seconds: 1,
      check_interval_seconds: 1
    }
end
