defmodule Ryker.StateTools.TaskStartTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.{Corrections, TaskOffer}
  alias Ryker.Records.Record
  alias Ryker.Slack.{Renderer, TaskCard, TaskCardProjection}
  alias Ryker.StateTools.FixedTools
  alias Ryker.Work.Session

  # A direct request still needed a second human action before any work could
  # start (2026-10-30). The words are from the harvested engineering scenario;
  # the surrounding custody and tool arguments exercise the new host contract.
  test "a current member's request starts exactly one task without a button" do
    request = request!()
    assert {:ok, result} = call(request)
    assert result["status"] == "started"
    record = Repo.get_by!(Record, ref: result["record_ref"])
    assert record.status == :confirmed
    assert record.confirmation_ref == request.arguments["instruction_ref"]
    session = Repo.get_by!(Session, episode_id: record.confirmed_episode_id)
    assert session.repository_ref == "ryker"
    assert session.policy == "ryker-contributor"
    assert session.workspace_task["instruction_ref"] == record.confirmation_ref

    card = Repo.get_by!(TaskCard, record_id: record.id)
    assert card.thread_ref == request.binding.episode.destination_thread_ref
    assert {:ok, projection} = TaskCardProjection.build(card)
    assert {:ok, rendered} = Renderer.render(projection.document)
    refute Jason.encode!(rendered) =~ "ryker_start_engineering_task"

    assert {:ok, repeated} = call(request)
    assert repeated["record_ref"] == result["record_ref"]
    assert Repo.aggregate(TaskCard, :count) == 1
    assert Repo.aggregate(Session, :count) == 2
  end

  # The source acknowledgement can still be pending when a started task
  # finishes. Requiring its delivery receipt would silently strand checks.
  for rootless <- [false, true] do
    @rootless rootless
    test "a started task queues checks before acknowledgement with rootless=#{rootless}" do
      request = request!()
      assert {:ok, started} = call(request)
      task = Repo.get_by!(Record, ref: started["record_ref"])
      assert {:ok, claim} = Ryker.Work.Custody.claim_next("task-checks", 60)
      assert claim.episode.id == task.confirmed_episode_id

      # A webhook route can name a channel without a Slack source message.
      episode =
        if @rootless, do: %{claim.episode | destination_thread_ref: nil}, else: claim.episode

      session = claim.session |> Session.Changeset.bind("coop-task-checks") |> Repo.update!()

      assert {:ok, _offer} =
               Ryker.Records.create(
                 Ryker.Records.token(claim.turn),
                 "host:publication:ready",
                 "publication_offer",
                 %{"title" => task.payload["title"], "body" => task.payload["prompt"]}
               )

      completed = %{claim.turn | continuation: %{"kind" => "complete"}, accepted_at: Repo.now!()}

      assert Repo.transaction(fn ->
               Ryker.Publication.Custody.ensure_task_review_in_transaction(
                 episode,
                 session,
                 completed
               )
             end) == {:ok, :ok}

      publication = Repo.get_by!(Ryker.Publication.Publication, episode_id: claim.episode.id)
      assert publication.status == :review_pending
      assert publication.review_requested_by_actor_ref == task.confirmed_by_actor_ref
      assert publication.destination_thread_ref == episode.destination_thread_ref
      refute Repo.get!(Ryker.Work.Turn, task.turn_id).external_receipt
    end
  end

  test "a channel-routed webhook task owns its posted card thread without rewriting its origin" do
    {request, _assignment} =
      automated_request!(true, %{"source_kind" => "webhook", "filter" => %{}}, rootless: true)

    assert {:ok, started} = call(request)
    task = Repo.get_by!(Record, ref: started["record_ref"])
    episode = Repo.get!(Ryker.Episodes.Episode, task.confirmed_episode_id)
    assert is_nil(episode.destination_thread_ref)
    card = Repo.get_by!(TaskCard, record_id: task.id)
    assert is_nil(card.thread_ref)
    assert is_nil(card.message_ref)

    assert {:ok, claim} = Ryker.Work.Custody.claim_next("webhook-task", 60, :work)
    assert claim.episode.id == episode.id
    assert Ryker.Knowledge.KnowledgeSnapshot.expose(claim, []) == :ok
    assert {:ok, submission} = Ryker.Inspectors.submission(claim)
    claim = %{claim | turn: %{claim.turn | submission: submission}}

    pinned = Ryker.Fixtures.WorkerJob.pin!(claim.session)
    claim = %{claim | session: pinned}

    assert {:ok, _offer} =
             Ryker.Records.create(
               Ryker.Records.token(claim.turn),
               "host:publication:ready",
               "publication_offer",
               %{"title" => task.payload["title"], "body" => task.payload["prompt"]}
             )

    document = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "The requested work is ready.",
      "outcome" => %{"state" => "complete", "record_refs" => [], "artifact_refs" => []}
    }

    accepted = Corrections.accept!(claim, document)

    # Pending card deliveries stay out of the candidate pool: eight of them
    # must not hide unrelated ready work behind the claim scan's eight slots.
    refute episode.id in Repo.all(
             Ryker.Work.OwningTurn.Query.claimable_episode_ids(Repo.now!(), :delivery)
           )

    # The result survives a delayed Slack post without spending delivery attempts.
    assert Ryker.Work.Custody.claim_next("before-card", 60, :delivery) == {:ok, nil}
    assert Repo.get!(Ryker.Work.Turn, accepted.turn.id).delivery_attempt_count == 0
    # Review can run before Slack posts the card; only its notification waits.
    assert {:ok, review_claim} = Ryker.Publication.Custody.claim_next("before-card-review", 60)
    session = Repo.get!(Session, claim.session.id)

    review =
      Ryker.Fixtures.Publication.harvested_refusal()
      # Adapt the older transport envelope, preserving its actual review verdict.
      |> Map.drop(~w(patch_artifact_id patch_bytes patch_digest policy_digest))
      |> Map.put("candidate_retained", true)
      |> Map.put("session_id", session.coop_session_id)
      |> Map.put("job_digest", session.worker_job_digest)

    assert {:ok, frozen} =
             Ryker.Publication.Custody.freeze_review_revision(
               review_claim.publication.ref,
               review_claim.lease_ref,
               review["session_revision"]
             )

    assert {:ok, reviewed} =
             Ryker.Publication.Custody.store_review(
               frozen.ref,
               review_claim.lease_ref,
               frozen.review_generation,
               review,
               nil
             )

    assert reviewed.status == :review_ready
    assert Ryker.Publication.Custody.claim_next("before-card-notice", 60) == {:ok, nil}

    assert Repo.get!(Ryker.Publication.Publication, reviewed.id).attempt_count ==
             reviewed.attempt_count

    assert {:ok, leased_card} = Ryker.Slack.TaskCards.claim_next("root-card", 60, 60)
    root = "1792535722.000100"

    assert {:ok, _card} =
             Ryker.Slack.TaskCards.mark(
               leased_card.id,
               leased_card.lease_ref,
               String.duplicate("a", 64),
               1,
               root
             )

    assert {:ok, delivery} = Ryker.Work.Custody.claim_next("after-card", 60, :delivery)
    assert delivery.turn.delivery_target["thread_ref"] == root
    assert delivery.turn.delivery_document == accepted.turn.delivery_document
    assert delivery.turn.submission == accepted.turn.submission
    assert is_nil(Repo.get!(Ryker.Episodes.Episode, episode.id).destination_thread_ref)

    assert {:ok, publication_delivery} =
             Ryker.Publication.Custody.claim_next("after-card-notice", 60)

    assert {:ok, notice} =
             Ryker.Publication.Custody.delivery_request(publication_delivery.publication)

    assert {:ok, receipt} = Ryker.Slack.TaskCards.card_receipt(episode.id, notice)
    assert receipt["message_ref"] == root
    assert is_nil(receipt["thread_ref"])

    assert {:ok, _delivered} =
             Ryker.Publication.Custody.confirm_delivery(
               publication_delivery.publication.ref,
               publication_delivery.lease_ref,
               receipt
             )

    destination = %{
      transport: "slack",
      conversation_ref: episode.destination_conversation_ref,
      thread_ref: root
    }

    search =
      Ryker.Admission.CandidateSearch.search(%{
        scope: Ryker.Admission.CorrelationScope.for_destination(destination),
        transport: "slack",
        thread_ref: root,
        text: "Please continue.",
        identifiers: [],
        native_input_id: "slack-message:new-reply",
        execution_mode: :live,
        repository_ref: nil,
        work_scope: %{environment_ref: nil, emisar_connection_ref: nil},
        occurrences: [],
        candidate_limit: 20,
        history_cutoff: DateTime.add(Repo.now!(), -3600, :second),
        now: Repo.now!()
      })

    assert Enum.any?(search.selected, &(&1.episode.id == episode.id and &1.origin_in_thread))
  end

  test "approval of an existing proposal starts its exact saved scope without another task" do
    request = request!()
    assert {:ok, proposed} = call(put_in(request.arguments["start"], false))
    offer = Repo.get_by!(Record, ref: proposed["record_ref"])

    start = %{
      request
      | arguments:
          Map.merge(request.arguments, %{
            "offer_ref" => offer.ref,
            "prompt" => "A different brief must not replace the saved proposal."
          })
    }

    assert {:ok, result} = call(start)
    assert result["record_ref"] == offer.ref
    assert Repo.get!(Record, offer.id).payload == offer.payload
    assert Repo.aggregate(Record, :count) == 1
    assert Repo.aggregate(Session, :count) == 2
  end

  test "a proposal without a start instruction remains inert" do
    request = request!()

    assert {:ok, result} =
             call(%{request | arguments: Map.put(request.arguments, "start", false)})

    assert Repo.get_by!(Record, ref: result["record_ref"]).status == :open
    assert Repo.aggregate(Session, :count) == 1
  end

  test "one instruction cannot start different saved proposals for the same repository" do
    request = request!()

    offers =
      for ref <- ["input:first-proposal", "input:second-proposal"] do
        proposal = %{
          request
          | arguments: Map.merge(request.arguments, %{"start" => false, "instruction_ref" => ref})
        }

        assert {:ok, proposed} = call(proposal)
        proposed["record_ref"]
      end

    [first, second] = offers
    assert {:ok, started} = call(put_in(request.arguments["offer_ref"], first))
    assert {:ok, ^started} = call(request)

    assert {:error, "task_instruction_not_authorized:" <> _} =
             call(put_in(request.arguments["offer_ref"], second))

    assert Repo.aggregate(Session, :count) == 2
    assert Repo.get_by!(Record, ref: second).status == :open
  end

  test "bots, unrelated sources and denied members cannot start work" do
    request = request!(actor_kind: :bot)
    assert {:error, _} = call(request)
    refute Repo.exists?(Record)
  end

  test "the host must authorize the exact repository and current member" do
    request = request!()
    assert {:error, _} = call(request, fn _, _ -> {:error, :unauthorized} end)
    refute Repo.exists?(Record)
    assert Repo.aggregate(Session, :count) == 1
  end

  test "a reference from another request cannot authorize this task" do
    request = request!()
    request = put_in(request.arguments["instruction_ref"], Ecto.UUID.generate())
    assert {:error, _} = call(request)
    refute Repo.exists?(Record)
  end

  test "a granted standing assignment starts one task for its matching event" do
    {request, assignment} = automated_request!(true)
    assert {:ok, result} = call(request)
    record = Repo.get_by!(Record, ref: result["record_ref"])
    assert record.confirmed_by_actor_ref == "system:assignment:" <> assignment.ref
    assert record.payload["assignment_ref"] == assignment.ref
    assert {:ok, ^result} = call(request)
  end

  # Run lists are presentation windows, not authority. Later matching inputs
  # must not remove the exact grant of the input already frozen for Work.
  test "later runs cannot displace a frozen input's matching task grant" do
    {request, assignment} = automated_request!(true)

    [{run, _}] =
      Repo.all(
        Ryker.Behaviors.StandingAssignmentRun.Query.decided_for_episode(
          request.binding.episode.id
        )
      )

    for index <- 1..6 do
      Repo.insert!(%Ryker.Behaviors.StandingAssignmentRun{
        assignment_id: assignment.id,
        episode_id: run.episode_id,
        ref: "later-run:#{index}",
        source_input_ref: "later-input:#{index}",
        source_event_ref: "later-event:#{index}",
        outcome: :decided,
        decision_action: :continue_episode,
        decision_ref: "later-decision:#{index}",
        inserted_at: DateTime.add(run.inserted_at, index, :second)
      })
    end

    assert {:ok, %{"status" => "started"}} = call(request)
  end

  test "another input cannot borrow a rule grant by reusing its external event ID" do
    {request, _assignment} = automated_request!(true)

    [{run, _}] =
      Repo.all(
        Ryker.Behaviors.StandingAssignmentRun.Query.decided_for_episode(
          request.binding.episode.id
        )
      )

    run |> Ecto.Changeset.change(source_input_ref: "inbox:another-source") |> Repo.update!()
    assert {:error, "task_instruction_not_authorized:" <> _} = call(request)
  end

  for changed_trigger <- [
        %{"filter" => %{"bot_id" => "unmatched-bot"}},
        %{"source_kind" => "github", "filter" => %{}}
      ] do
    @changed_trigger changed_trigger
    test "a newly granted trigger must still match its earlier input: #{inspect(changed_trigger)}" do
      # Standing runs predate a later rule edit, but the frozen submission
      # sees the current grant. That grant must match this input itself.
      {request, _assignment} = automated_request!(true, @changed_trigger)
      assert {:error, "task_instruction_not_authorized:" <> _} = call(request)
    end
  end

  test "an old confirmed proposal cannot stand in for a new task start" do
    request = request!()
    assert {:ok, started} = call(request)
    record = Repo.get_by!(Record, ref: started["record_ref"])
    # A retained confirmed offer belongs to an earlier authorization, not
    # the current input. Keep its actual task and scope while arranging that state.
    record |> Ecto.Changeset.change(confirmation_ref: Ecto.UUID.generate()) |> Repo.update!()

    assert {:error, "task_instruction_not_authorized:" <> _} =
             call(put_in(request.arguments["offer_ref"], record.ref))

    assert Repo.aggregate(Session, :count) == 2
  end

  test "an existing read-only assignment never acquires permission to start tasks" do
    {request, _assignment} = automated_request!(false)
    assert {:error, "task_instruction_not_authorized:" <> _} = call(request)

    refute Repo.exists?(
             Ryker.Records.Record.Query.by_kind(Ryker.Records.Record.Query.all(), "task_offer")
           )
  end

  test "revoking an assignment while a start is being authorized prevents that start" do
    {request, assignment} = automated_request!(true)

    authorize = fn source, repository ->
      assignment |> Ecto.Changeset.change(status: :disabled) |> Repo.update!()
      authorize(source, repository)
    end

    assert {:error, "task_instruction_not_authorized:" <> _} = call(request, authorize)

    refute Repo.exists?(
             Ryker.Records.Record.Query.by_kind(Ryker.Records.Record.Query.all(), "task_offer")
           )
  end

  test "an edit withdrawing a request prevents a start from its old words" do
    request = request!()

    authorize = fn entry, repository ->
      attributes =
        Map.merge(request.source.attributes, %{
          content: %{"text" => "Do not make that change."},
          event_kind: :edit,
          event_ref: "edit:#{entry.id}",
          revision: 2
        })

      {:ok, input} = Ryker.Slack.Input.new(attributes)
      {:ok, _} = Ryker.Ingress.Inbox.record(input)
      authorize(entry, repository)
    end

    assert {:error, "task_instruction_not_authorized:" <> _} = call(request, authorize)
    refute Repo.exists?(Record)
  end

  defp automated_request!(granted, changed_trigger \\ %{}, options \\ []) do
    source = Corrections.correction!()
    assignment = Corrections.assignment!(source)

    payload =
      assignment.payload
      |> Map.merge(%{
        "start_tasks" => granted,
        "repository" => "ryker",
        "filter" => %{"bot_id" => "B0TENANTBT1"}
      })
      |> Map.merge(changed_trigger)

    assignment = assignment |> Ecto.Changeset.change(payload: payload) |> Repo.update!()
    later = Corrections.later!(source, Keyword.put(options, :assignment, assignment))
    context = later.turn.submission["context"]
    inputs = get_in(context, ["inputs", "items"]) || get_in(context, ["current_inputs", "items"])

    arguments =
      TaskOffer.payload(%{"instruction_ref" => hd(inputs)["source_event_id"]})
      |> Map.merge(%{"start" => true, "assignment_ref" => assignment.ref})

    {%{binding: later, arguments: arguments}, assignment}
  end

  defp request!(options \\ []) do
    scenario =
      Jason.decode!(File.read!("testdata/scenarios/rivals-engineering-task-offer/scenario.json"))

    text = hd(scenario["events"])["payload"]["text"]
    source = Corrections.correction!(Keyword.put(options, :text, text))

    arguments =
      TaskOffer.payload(%{
        "prompt" => text,
        "instruction_ref" => source.arguments["source_event_ref"]
      })

    %{binding: source.binding, arguments: Map.put(arguments, "start", true), source: source}
  end

  defp call(request, authorize \\ &authorize/2) do
    FixedTools.call("request_task", request.arguments,
      binding: request.binding,
      task_authorizer: authorize
    )
  end

  defp authorize(_binding, _entry) do
    {:ok,
     %{name: "ryker-contributor", digest: String.duplicate("b", 64), repository_ref: "ryker"}}
  end
end
