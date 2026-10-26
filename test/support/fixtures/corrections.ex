defmodule Ryker.Fixtures.Corrections do
  @moduledoc "Host custody around harvested correction wording, not a recorded model decision."
  alias Ryker.Admission.Decision
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Ingress
  alias Ryker.Inspectors
  alias Ryker.Repo
  alias Ryker.Slack
  alias Ryker.Work

  def correction!(options \\ []) do
    fixture = File.read!("testdata/learning/retained-rollout-correction.json") |> Jason.decode!()
    text = Keyword.get(options, :text, hd(fixture["corrections"])["text"])
    id = Ecto.UUID.generate()
    workspace = "TCORRECTION#{String.replace(id, "-", "") |> String.upcase()}"
    now = DateTime.utc_now()

    Repo.insert!(%Slack.ChannelMembership{
      workspace_ref: workspace,
      channel_ref: "C1",
      private: Keyword.get(options, :private, false),
      external_shared: false,
      generation: 1,
      status: :joined,
      joined_at: now
    })

    attributes = %{
      actor: %{kind: Keyword.get(options, :actor_kind, :user), ref: "UOPERATOR"},
      channel_ref: "C1",
      content: Keyword.get(options, :content, %{"text" => text}),
      event_kind: :message,
      event_ref: "correction:#{id}",
      message_ref: "1791926113.866679",
      occurred_at: now,
      revision: 1,
      thread_ref: "1791925599.563809",
      workspace_ref: workspace
    }

    {:ok, input} = Slack.Input.new(attributes)
    {:ok, %{entry: entry}} = Ingress.Inbox.record(input)

    {:ok, decision} =
      Decision.parse(%{
        "action" => "start_episode",
        "episode_ref" => nil,
        "messages" => nil,
        "reactions" => nil,
        "relation" => "unrelated",
        "repository" => nil,
        "repository_source" => nil,
        "reason" => "Correct this review.",
        "work_class" => "standard"
      })

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          actor_ref: entry.actor_ref,
          destination: %{
            transport: "slack",
            conversation_ref:
              Keyword.get(options, :episode_conversation, entry.destination_conversation_ref),
            thread_ref: entry.destination_thread_ref
          },
          episode_id: id,
          episode_key: "correction:#{id}",
          native_input_id: entry.native_input_id,
          occurred_at: now,
          payload: Ingress.Input.document(input),
          revision: entry.revision,
          turn_ref: "correction:#{id}"
        })
      )

    entry =
      Repo.update!(Ingress.Inbox.Entry.Changeset.decide(entry, decision, "decision:#{id}", id))

    {:ok, _} = WorkSessions.pin_episode(id, "correction", String.duplicate("a", 64))
    {:ok, claim} = Work.Custody.claim_next("correction:#{id}", 60, :work)
    Ryker.Fixtures.CompletionReview.attest!(claim)
    {:ok, submission} = Inspectors.submission(claim)

    {:ok, turn} =
      Work.Custody.freeze_submission(id, claim.turn.turn_ref, claim.lease_ref, submission,
        selected_input_refs: claim.episode.active_input_refs
      )

    claim = %{claim | turn: turn}
    [current] = submission["context"]["inputs"]["items"]

    %{
      claim: claim,
      entry: entry,
      attributes: attributes,
      binding: Map.put(claim, :state_token, Ryker.Records.token(turn)),
      arguments: %{
        "source_event_ref" => current["source_event_id"],
        "instruction" => text,
        "scope" => "conversation",
        "subject" => "Rollout review",
        "guidance_ref" => nil,
        "expected_revision" => nil,
        "assignment_ref" => nil,
        "requirements" => ["Report before/after versions and what changes will be deployed."]
      }
    }
  end

  def later!(correction, options \\ []) do
    claim = correction.claim

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.accept_result(%{
          episode_key: claim.episode.key,
          expected_turn_ref: claim.episode.owner_ref,
          delivery: :none,
          delivery_ref: nil,
          decision_reason: "Correction saved.",
          occurred_at: DateTime.utc_now(),
          result_ref: "saved:#{claim.episode.id}"
        })
      )

    id = Ecto.UUID.generate()
    fixture = File.read!("testdata/learning/retained-rollout-correction.json") |> Jason.decode!()
    payload = fixture["notification"]

    destination = %{
      transport: "slack",
      conversation_ref: claim.episode.destination_conversation_ref,
      thread_ref: "1792535721.651629"
    }

    attributes =
      Map.merge(correction.attributes, %{
        actor: %{kind: :bot, ref: "B0TENANTBT1"},
        content: payload["content"],
        event_ref: "later:#{id}",
        message_ref: "1792535721.651629",
        thread_ref: destination.thread_ref
      })

    {:ok, input} = Slack.Input.new(attributes)

    {:ok, %{entry: entry}} =
      Ingress.Inbox.record(input, execution_mode: Keyword.get(options, :execution_mode, :live))

    payload = Ingress.Input.document(input)

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          actor_ref: "slack:bot:B0TENANTBT1",
          destination: destination,
          episode_id: id,
          execution_mode: Keyword.get(options, :execution_mode, :live),
          episode_key: "later:#{id}",
          native_input_id: entry.native_input_id,
          occurred_at: DateTime.utc_now(),
          payload: payload,
          turn_ref: "later:#{id}"
        })
      )

    {:ok, decision} =
      Decision.parse(%{
        "action" => "start_episode",
        "episode_ref" => nil,
        "messages" => nil,
        "reactions" => nil,
        "relation" => "unrelated",
        "repository" => nil,
        "repository_source" => nil,
        "reason" => "Review the next plan.",
        "work_class" => "standard"
      })

    Repo.update!(Ingress.Inbox.Entry.Changeset.decide(entry, decision, "decision:#{id}", id))

    if assignment = Keyword.get(options, :assignment) do
      Repo.insert!(%Ryker.Behaviors.StandingAssignmentRun{
        assignment_id: assignment.id,
        episode_id: id,
        ref: "assignment-run:#{id}",
        source_input_ref: "later:#{id}",
        source_event_ref: "later:#{id}",
        outcome: :decided,
        decision_action: :start_episode,
        decision_ref: "later:#{id}"
      })
    end

    {:ok, _} = WorkSessions.pin_episode(id, "correction", String.duplicate("a", 64))
    {:ok, later} = Work.Custody.claim_next("later:#{id}", 60, :work)
    Ryker.Fixtures.CompletionReview.attest!(later)
    {:ok, submission} = Inspectors.submission(later)

    {:ok, turn} =
      Work.Custody.freeze_submission(id, later.turn.turn_ref, later.lease_ref, submission,
        selected_input_refs: later.episode.active_input_refs
      )

    Map.put(%{later | turn: turn}, :state_token, Ryker.Records.token(turn))
  end

  def assignment!(correction) do
    source = %{
      conversation_ref: correction.claim.episode.destination_conversation_ref,
      episode: correction.claim.episode,
      turn: correction.claim.turn
    }

    assignment =
      Ryker.Fixtures.SavedEntities.behavior!(
        source,
        :standing_assignment,
        %{
          "context_channel" => source.conversation_ref,
          "delivery_channel" => source.conversation_ref,
          "expires_at" => nil,
          "filter" => %{"bot_id" => "B-TERRAFORM"},
          "hold" => nil,
          "source_kind" => "slack",
          "task" => "Review deployment plans.",
          "repository" => nil,
          "title" => "Review deployments"
        },
        scope_ref: source.conversation_ref
      )

    decided_assignment!(correction.claim.episode.id, assignment)
    assignment
  end

  defp decided_assignment!(episode_id, assignment) do
    id = Ecto.UUID.generate()

    Repo.insert!(%Ryker.Behaviors.StandingAssignmentRun{
      assignment_id: assignment.id,
      episode_id: episode_id,
      ref: "assignment-run:#{id}",
      source_input_ref: "input:#{id}",
      source_event_ref: "event:#{id}",
      outcome: :decided,
      decision_action: :start_episode,
      decision_ref: "decision:#{id}"
    })
  end

  def accept!(binding, document) do
    id = binding.episode.id
    ref = binding.turn.turn_ref
    lease = binding.lease_ref

    {:ok, _} =
      Work.Custody.freeze_submission(id, ref, lease, binding.turn.submission,
        selected_input_refs: binding.episode.active_input_refs
      )

    {:ok, session} =
      Work.Custody.bind_session(
        id,
        ref,
        lease,
        binding.session.generation,
        binding.session.create_generation,
        "coop-session:#{id}"
      )

    {:ok, _} =
      Work.Custody.bind_turn(
        id,
        ref,
        lease,
        session.generation,
        binding.turn.submit_generation,
        "coop-turn:#{id}"
      )

    candidate = Jason.encode!(document)
    digest = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)
    {:ok, _} = Work.Custody.stage_candidate(id, ref, lease, nil, nil, candidate, digest, 1)
    Ryker.Fixtures.CompletionReview.approve!(binding, document)
    {:ok, result} = Work.Result.new(:reply, document)
    {:ok, _} = Work.Custody.prepare_validation(id, ref, lease, digest, 1, :accept, result)

    {:ok, accepted} =
      Work.Custody.accept_result(
        id,
        binding.episode.key,
        ref,
        lease,
        digest,
        1,
        "validation:#{id}"
      )

    accepted
  end

  def deliver!(binding, accepted) do
    {:ok, delivery} = Work.Custody.claim_next("delivery:#{binding.episode.id}", 60, :delivery)

    {:ok, receipt} =
      Work.DeliveryReceipt.new(
        accepted.turn.delivery_ref,
        binding.episode.destination_transport,
        binding.episode.destination_conversation_ref,
        binding.episode.destination_thread_ref,
        "1792535722.000001"
      )

    {:ok, settled} =
      Work.Custody.confirm_delivery(
        binding.episode.id,
        binding.episode.key,
        binding.turn.turn_ref,
        delivery.lease_ref,
        receipt
      )

    settled
  end
end
