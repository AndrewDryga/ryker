defmodule Responder.Acceptance.LiveObserverTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Acceptance.Live
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Repo
  alias Responder.Slack.Input
  alias Responder.Work.{Custody, Turn}

  @now ~U[2026-08-30 15:00:00.000000Z]

  test "the live observer reports pending and blocked admission custody" do
    entry = record_input!("Ev-live-pending")
    assert Live.observe(entry.event_ref, []) == :pending

    assert {:ok, %{entry: claimed, lease_ref: lease_ref}} =
             Inbox.claim_next("live-observer", @now, 60)

    assert claimed.id == entry.id

    assert {:ok, _blocked} =
             Inbox.block(
               Inbox.ref(entry),
               lease_ref,
               "admission_uncertain",
               "The exact admission result could not be reconciled."
             )

    assert Live.observe(entry.event_ref, []) ==
             {:error, {:live_acceptance_admission_blocked, "admission_uncertain"}}
  end

  test "the live observer rejects terminal input custody without executable work" do
    decided = record_input!("Ev-live-decided-no-episode")

    decide_entry!(decided.id, nil, :ignore)

    assert Live.observe(decided.event_ref, []) ==
             {:error, :live_acceptance_input_created_no_episode}

    command = create_episode!("superseded-owner")
    superseded = record_input!("Ev-live-superseded")

    supersede_entry!(superseded.id, command.episode_id)

    assert Live.observe(superseded.event_ref, []) ==
             {:error, :live_acceptance_input_superseded}
  end

  test "the live observer follows exact new work from pending through a settled delivery" do
    command = create_episode!("settled")
    assert {:ok, claim} = Custody.claim_next("live-work-observer", 60)
    assert claim.episode.id == command.episode_id

    entry = record_input!("Ev-live-work")
    decide_entry!(entry.id, command.episode_id, :reply)

    assert Live.observe(entry.event_ref, []) == :pending
    assert Live.observe(entry.event_ref, [claim.turn.id]) == :pending

    {1, nil} =
      Repo.update_all(
        from(turn in Turn, where: turn.id == ^claim.turn.id),
        set: [
          status: :blocked,
          lease_ref: nil,
          lease_owner: nil,
          lease_expires_at: nil,
          next_attempt_at: nil,
          last_error_code: "work_protocol_error",
          last_error_detail: "The remote turn could not be reconciled."
        ]
      )

    assert Live.observe(entry.event_ref, []) ==
             {:error, {:live_acceptance_work_failed, :blocked, "work_protocol_error"}}

    settle_turn!(claim.turn.id)

    assert {:ok, snapshot} = Live.observe(entry.event_ref, [])
    assert snapshot.episode_id == command.episode_id
    assert snapshot.turn_id == claim.turn.id
    assert snapshot.delivery_document == %{"message" => "The acceptance work settled."}
    assert snapshot.external_receipt["thread_ref"] == "1788102000.100000"
  end

  defp record_input!(event_ref) do
    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Observe this acceptance input."},
               event_kind: :message,
               event_ref: event_ref,
               message_ref: "1788102000.#{System.unique_integer([:positive])}",
               occurred_at: @now,
               revision: 1,
               thread_ref: "1788102000.100000",
               workspace_ref: "T5F3F14E8DE3B"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp create_episode!(suffix) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "live:#{suffix}:#{Ecto.UUID.generate()}",
        native_input_id: "live:source:#{suffix}:#{Ecto.UUID.generate()}",
        occurred_at: @now,
        turn_ref: "live:turn:#{suffix}:#{Ecto.UUID.generate()}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only",
               String.duplicate("a", 64)
             )

    command
  end

  defp decide_entry!(entry_id, episode_id, action) do
    {1, nil} =
      Repo.update_all(
        from(entry in Responder.Ingress.Inbox.Entry, where: entry.id == ^entry_id),
        set: [
          status: :decided,
          decision_ref: "decision:#{entry_id}",
          decision_fingerprint: String.duplicate("d", 64),
          decision_action: action,
          decision_document: %{"action" => Atom.to_string(action)},
          episode_id: episode_id
        ]
      )
  end

  defp supersede_entry!(entry_id, episode_id) do
    {1, nil} =
      Repo.update_all(
        from(entry in Responder.Ingress.Inbox.Entry, where: entry.id == ^entry_id),
        set: [
          status: :superseded,
          decision_ref: "decision:#{entry_id}",
          decision_fingerprint: String.duplicate("s", 64),
          decision_action: :reply,
          decision_document: %{"action" => "reply"},
          episode_id: episode_id,
          last_error_code: "stale_input_revision",
          last_error_detail: "A newer source revision is already owned by this episode."
        ]
      )
  end

  defp settle_turn!(turn_id) do
    candidate_sha = String.duplicate("c", 64)

    receipt = %{
      "conversation_ref" => "slack:T5F3F14E8DE3B:C456",
      "delivery_ref" => "delivery:#{turn_id}",
      "message_ref" => "1788102000.200000",
      "thread_ref" => "1788102000.100000",
      "transport" => "slack"
    }

    {1, nil} =
      Repo.update_all(
        from(turn in Turn, where: turn.id == ^turn_id),
        set: [
          status: :settled,
          lease_ref: nil,
          lease_owner: nil,
          lease_expires_at: nil,
          next_attempt_at: nil,
          candidate: ~s({"message":"The acceptance work settled."}),
          candidate_sha256: candidate_sha,
          candidate_attempt: 1,
          validation_intent: %{"candidate_sha256" => candidate_sha, "verdict" => "accept"},
          validation_intent_fingerprint: String.duplicate("v", 64),
          validation_receipt: "validation:#{turn_id}",
          result_ref: "result:#{turn_id}",
          accepted_at: @now,
          continuation: %{"kind" => "complete"},
          delivery_ref: "delivery:#{turn_id}",
          delivery_document: %{"message" => "The acceptance work settled."},
          delivery_fingerprint: String.duplicate("f", 64),
          external_receipt: receipt,
          external_receipt_fingerprint: String.duplicate("e", 64),
          delivered_at: @now
        ]
      )
  end
end
