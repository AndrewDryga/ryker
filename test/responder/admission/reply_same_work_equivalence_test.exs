defmodule Responder.Admission.ReplySameWorkEquivalenceTest do
  # ReplayTest uses this same harvested Slack identity. A sandbox holds locks
  # across receive/admit calls that commit separately in production; running the
  # two fixtures concurrently deadlocked their channel and conversation locks.
  # Keep the source unmodified and run this equivalence assertion serially.
  use Responder.DataCase, async: false

  @moduletag isolation: "REPEATABLE READ"

  alias Responder.Admission
  alias Responder.Admission.{Candidate, Context, Decision}
  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Ingress.Inbox.EntryChangeset
  alias Responder.Ingress.Input
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Work.{Custody, Session}

  @fixture_path "test/responder/admission/fixtures/human_thread_reply_reopens_episode.json"

  test "the harvested conversational same-work reply reopens the seed without replacing its pinned session" do
    fixture = @fixture_path |> File.read!() |> Jason.decode!()
    seed_input = slack_input!(fixture["seed"]["input"])
    current_input = slack_input!(fixture["input"])
    episode_id = Ecto.UUID.generate()
    episode_key = "harvested-human-thread:#{episode_id}"
    original_turn_ref = "harvested-turn:#{episode_id}"

    assert {:ok, _} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: Input.actor_ref(seed_input),
               destination: seed_input.destination,
               episode_id: episode_id,
               episode_key: episode_key,
               native_input_id: seed_input.native_input_id,
               occurred_at: seed_input.occurred_at,
               payload: Input.document(seed_input),
               revision: seed_input.revision,
               turn_ref: original_turn_ref
             })

    assert {:ok, _} =
             Episodes.apply(%Command.AcceptResult{
               decision_reason:
                 "The captured redirect investigation completed before the follow-up.",
               delivery: :none,
               delivery_ref: nil,
               episode_key: episode_key,
               expected_turn_ref: original_turn_ref,
               next_turn_ref: nil,
               occurred_at: DateTime.add(seed_input.occurred_at, 1, :second),
               result_ref: "harvested-result:#{episode_id}"
             })

    assert {:ok, seed} = Episodes.fetch_by_key(episode_key)

    assert {:ok, pinned} =
             Custody.pin_episode(
               seed.id,
               "standard-sol-medium",
               String.duplicate("a", 64)
             )

    entry =
      current_input
      |> EntryChangeset.insert(Ecto.UUID.generate(), :live, nil, %{
        audience: nil,
        bot_user_ref: nil
      })
      |> Repo.insert!()

    {:ok, now, 0} = DateTime.from_iso8601(fixture["now"])

    endpoint = %{
      occurred_at: seed_input.occurred_at,
      payload: %{"payload" => Input.document(seed_input)}
    }

    candidate =
      Candidate.new(%{
        allowed_relations:
          Candidate.allowed_relations(seed, %{
            continuation_window: fixture["continuation_window_seconds"],
            input_repository: nil,
            now: now,
            pinned_repository: nil,
            source_owner: false
          }),
        digest: nil,
        endpoints: %{first: endpoint, latest: endpoint},
        episode: seed,
        match: %{},
        same_thread: seed.destination_thread_ref == current_input.destination.thread_ref,
        source_owner: false
      })

    context = %Context{
      active_episode_fingerprint: Responder.CanonicalJSON.digest([]),
      built_at: now,
      candidates: [candidate],
      conversation_episode_count: 1,
      input: current_input,
      input_entry: entry
    }

    alternate = hd(fixture["accepted_alternatives"])

    assert {:ok, decision} =
             Decision.parse(Map.put(alternate, "episode_ref", candidate.ref))

    assert {:ok, result} =
             Admission.commit(context, decision, "harvested-human-thread-reply",
               work_policy: %{
                 digest: String.duplicate("b", 64),
                 name: "conversation-terra-medium",
                 repository_ref: nil
               }
             )

    assert result.entry.decision_action == :reply
    assert result.episode.id == seed.id
    assert result.episode.destination_transport == seed.destination_transport
    assert result.episode.destination_conversation_ref == seed.destination_conversation_ref
    assert result.episode.destination_thread_ref == seed.destination_thread_ref
    assert result.episode.linked_episode_id == seed.linked_episode_id
    assert result.episode.state == :working
    assert result.episode.owner_ref == "ingress-turn:#{entry.id}"
    assert length(result.episode.active_input_refs) == 1
    assert result.episode.queued_input_refs == []

    assert %Session{
             id: pinned_session_id,
             policy: "standard-sol-medium",
             policy_digest: pinned_digest
           } = Repo.get!(Session, pinned.id)

    assert pinned_session_id == pinned.id
    assert pinned_digest == String.duplicate("a", 64)
  end

  defp slack_input!(document) do
    {:ok, occurred_at, 0} = DateTime.from_iso8601(document["occurred_at"])

    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{
                 kind: String.to_existing_atom(document["actor"]["kind"]),
                 ref: document["actor"]["ref"]
               },
               channel_ref: document["channel_ref"],
               content: document["content"],
               event_kind: String.to_existing_atom(document["event_kind"]),
               event_ref: document["event_ref"],
               message_ref: document["message_ref"],
               occurred_at: occurred_at,
               revision: document["revision"],
               thread_ref: document["thread_ref"],
               workspace_ref: document["workspace_ref"]
             })

    input
  end
end
