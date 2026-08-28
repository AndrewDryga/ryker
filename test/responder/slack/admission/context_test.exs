defmodule Responder.Slack.Admission.ContextTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Repo
  alias Responder.Slack.{Admission, Inbox, Input}
  alias Responder.Slack.Admission.{Context, Decision}

  @now ~U[2026-08-27 12:00:00.000000Z]
  @current_thread "1787832000.000100"

  test "offers generic same-work and history candidates without inspecting provider text" do
    current = record_input!(content: %{"text" => "A custom app changed state"})

    same_thread =
      create_episode!(
        key: "same-thread",
        thread_ref: @current_thread,
        content: %{"text" => "This could be any earlier human or app message"},
        complete: true,
        updated_at: DateTime.add(@now, -40 * 24 * 60 * 60)
      )

    recent_other_thread =
      create_episode!(
        key: "recent-other-thread",
        thread_ref: "1787831000.000001",
        content: %{"text" => "No provider-specific status words here"},
        complete: true,
        updated_at: DateTime.add(@now, -5 * 60)
      )

    expired_other_thread =
      create_episode!(
        key: "expired-other-thread",
        thread_ref: "1787830000.000001",
        content: %{"text" => "Related historical work"},
        complete: true,
        updated_at: DateTime.add(@now, -2 * 60 * 60)
      )

    other_channel =
      create_episode!(
        key: "other-channel",
        channel_ref: "C999",
        thread_ref: "1787833000.000001",
        content: %{"text" => "Must remain invisible to this admission decision"}
      )

    assert {:ok, context} = build_context(current)
    candidates = Map.new(context.candidates, &{&1.episode.id, &1})

    assert candidates[same_thread.id].allowed_relations == [:same_work, :history_only]
    assert candidates[same_thread.id].same_thread

    assert candidates[recent_other_thread.id].allowed_relations == [
             :same_work,
             :history_only
           ]

    assert candidates[expired_other_thread.id].allowed_relations == [:history_only]
    refute Map.has_key?(candidates, other_channel.id)

    model_context = Context.for_model(context)

    model_same_thread =
      Enum.find(
        model_context["candidates"],
        &(&1["episode_ref"] == candidates[same_thread.id].ref)
      )

    assert model_same_thread["state"] == "complete"
    encoded = Jason.encode!(model_context)

    refute encoded =~ same_thread.id
    refute encoded =~ same_thread.key
    refute encoded =~ recent_other_thread.destination_thread_ref
    assert encoded =~ "This could be any earlier human or app message"
  end

  test "active work remains a continuation candidate beyond the completed hold window" do
    current = record_input!()

    active =
      create_episode!(
        key: "still-active",
        thread_ref: "1787820000.000001",
        content: %{"text" => "Long-running work"},
        updated_at: DateTime.add(@now, -10 * 24 * 60 * 60)
      )

    assert {:ok, context} = build_context(current)
    candidate = Enum.find(context.candidates, &(&1.episode.id == active.id))

    assert candidate.allowed_relations == [:same_work, :history_only]
  end

  test "validates model choices only against the supplied opaque candidates" do
    current = record_input!()

    expired =
      create_episode!(
        key: "expired",
        thread_ref: "1787830000.000001",
        content: %{"text" => "Old completed work"},
        complete: true,
        updated_at: DateTime.add(@now, -2 * 60 * 60)
      )

    assert {:ok, context} = build_context(current)
    candidate = Enum.find(context.candidates, &(&1.episode.id == expired.id))

    assert {:ok, history_decision} =
             Decision.parse(%{
               "action" => "start_episode",
               "episode_ref" => candidate.ref,
               "reaction" => nil,
               "relation" => "history_only",
               "reason" => "The older work is useful history, but this is a new episode."
             })

    assert {:ok, %{candidate: ^candidate}} = Admission.validate(context, history_decision)

    assert {:ok, continuation} =
             Decision.parse(%{
               "action" => "continue_episode",
               "episode_ref" => candidate.ref,
               "reaction" => nil,
               "relation" => "same_work",
               "reason" => "Continue the old work."
             })

    assert {:error,
            {:admission_rejected, :relation_not_allowed,
             allowed: [:history_only], submitted: :same_work}} =
             Admission.validate(context, continuation)

    assert {:ok, unknown} =
             Decision.parse(%{
               "action" => "continue_episode",
               "episode_ref" => "candidate-not-offered",
               "reaction" => nil,
               "relation" => "same_work",
               "reason" => "Try an arbitrary reference."
             })

    assert {:error, {:admission_rejected, :unknown_candidate}} =
             Admission.validate(context, unknown)
  end

  test "refuses to build a second model context after an input is decided" do
    entry = record_input!()

    Repo.update_all(
      from(stored in Responder.Slack.Inbox.Entry, where: stored.id == ^entry.id),
      set: [
        decision_action: :ignore,
        decision_document: %{
          "action" => "ignore",
          "episode_ref" => nil,
          "reaction" => nil,
          "relation" => "unrelated",
          "reason" => "Exact duplicate."
        },
        decision_fingerprint: String.duplicate("a", 64),
        decision_ref: "decision-1",
        status: :decided
      ]
    )

    assert {:error, {:input_already_decided, "decision-1"}} = build_context(entry)
  end

  test "candidate history fetches only chronological first and latest inputs" do
    episode =
      create_episode!(
        key: "bounded-endpoints",
        thread_ref: "1787830000.000001",
        content: %{"text" => "chronological first"}
      )

    for index <- 1..25 do
      admit_followup!(episode, "middle #{index}", DateTime.add(@now, -1_000 + index, :second))
    end

    admit_followup!(episode, "chronological latest", DateTime.add(@now, 120, :second))
    admit_followup!(episode, "delayed but committed last", DateTime.add(@now, 60, :second))

    assert %{first: first, latest: latest} =
             Admission.input_event_endpoints([episode.id])[episode.id]

    assert first.payload["payload"]["content"]["text"] == "chronological first"
    assert latest.payload["payload"]["content"]["text"] == "chronological latest"
    assert map_size(Admission.input_event_endpoints([episode.id])[episode.id]) == 2
  end

  defp build_context(entry) do
    Admission.context(Inbox.ref(entry),
      now: @now,
      continuation_window: 30 * 60,
      history_window: 30 * 24 * 60 * 60,
      candidate_limit: 8
    )
  end

  defp record_input!(overrides \\ []) do
    input = input!(overrides)
    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp create_episode!(options) do
    channel_ref = Keyword.get(options, :channel_ref, "C456")
    thread_ref = Keyword.fetch!(options, :thread_ref)
    episode_id = Ecto.UUID.generate()
    episode_key = "admission-test:#{Keyword.fetch!(options, :key)}:#{episode_id}"

    source_input =
      input!(
        channel_ref: channel_ref,
        content: Keyword.fetch!(options, :content),
        event_ref: "Ev-#{episode_id}",
        message_ref: thread_ref,
        thread_ref: nil
      )

    command = %Command.AdmitInput{
      actor_ref: "slack:app:A123",
      destination: Input.destination(source_input),
      episode_id: episode_id,
      episode_key: episode_key,
      linked_episode_id: nil,
      native_input_id: Input.dedupe_key(source_input),
      occurred_at: DateTime.add(@now, -3 * 60 * 60),
      payload: Input.document(source_input),
      revision: 1,
      turn_ref: "turn-#{episode_id}"
    }

    assert {:ok, _transition} = Episodes.apply(command)

    if Keyword.get(options, :complete, false) do
      assert {:ok, _transition} =
               Episodes.apply(%Command.AcceptResult{
                 decision_reason: "No reply was useful for this fixture.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: episode_key,
                 expected_turn_ref: command.turn_ref,
                 next_turn_ref: nil,
                 occurred_at: DateTime.add(command.occurred_at, 1, :second),
                 result_ref: "result-#{episode_id}"
               })
    end

    case Keyword.fetch(options, :updated_at) do
      {:ok, updated_at} ->
        Repo.update_all(
          from(episode in Responder.Episodes.Episode, where: episode.id == ^episode_id),
          set: [updated_at: updated_at]
        )

      :error ->
        :ok
    end

    {:ok, episode} = Episodes.fetch_by_key(episode_key)
    episode
  end

  defp admit_followup!(episode, text, occurred_at) do
    input =
      input!(
        content: %{"text" => text},
        event_ref: "Ev-#{Ecto.UUID.generate()}",
        message_ref: "#{DateTime.to_unix(occurred_at, :microsecond) / 1_000_000}",
        occurred_at: occurred_at,
        thread_ref: episode.destination_thread_ref
      )

    assert {:ok, _transition} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: Input.actor_ref(input),
               destination: %{
                 conversation_ref: episode.destination_conversation_ref,
                 thread_ref: episode.destination_thread_ref,
                 transport: episode.destination_transport
               },
               episode_id: episode.id,
               episode_key: episode.key,
               linked_episode_id: episode.linked_episode_id,
               native_input_id: Input.message_key(input),
               occurred_at: occurred_at,
               payload: Input.document(input),
               revision: input.revision,
               turn_ref: "turn-#{Ecto.UUID.generate()}"
             })
  end

  defp input!(overrides) do
    attributes =
      Keyword.merge(
        [
          actor: %{kind: :app, ref: "A123"},
          channel_ref: "C456",
          content: %{"text" => "Current Slack input"},
          event_kind: :message,
          event_ref: "Ev-current-#{Ecto.UUID.generate()}",
          message_ref: @current_thread,
          occurred_at: @now,
          revision: 1,
          thread_ref: nil,
          workspace_ref: "T123"
        ],
        overrides
      )

    assert {:ok, input} = Input.new(attributes)
    input
  end
end
