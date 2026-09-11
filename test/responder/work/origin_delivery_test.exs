defmodule Responder.Work.OriginDeliveryTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode}
  alias Responder.Ingress.Input
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Work.{Custody, Session, Turn}

  @now ~U[2026-09-11 12:00:00.000000Z]

  test "an answer returns to the thread its question was asked in, not to the episode's home" do
    # Combining evidence across conversations silently redirected every reply to
    # the episode's original channel, so a colleague who asked in their own
    # thread was answered somewhere they were not reading.
    episode = admit!("delivery:home", channel_ref: "CDEVOPS")

    question =
      join!(episode,
        channel_ref: "CENGINEERING",
        text: "Is the primary still unreachable?",
        thread_ref: "1789004000.000100"
      )

    turn = turn!(episode, [question])

    assert Custody.reply_target(episode, turn) == %{
             "conversation_ref" => "slack:TROUTE:CENGINEERING",
             "thread_ref" => "1789004000.000100",
             "transport" => "slack"
           }

    # Until an accepted result freezes that target, delivery still reads home.
    assert Custody.delivery_target(episode, turn)["conversation_ref"] ==
             "slack:TROUTE:CDEVOPS"
  end

  test "progress with no answering input keeps the episode's one home" do
    episode = admit!("delivery:progress", channel_ref: "CDEVOPS")

    {:ok, _transition} =
      Episodes.apply(%Command.AcceptResult{
        decision_reason: "Nothing needed an answer here.",
        delivery: :none,
        delivery_ref: nil,
        episode_key: episode.key,
        expected_turn_ref: "turn:#{episode.id}",
        next_turn_ref: nil,
        occurred_at: DateTime.add(@now, 5, :second),
        result_ref: "result:#{episode.id}"
      })

    {:ok, episode} = Episodes.fetch_by_key(episode.key)
    turn = turn!(episode, [])

    assert is_nil(Custody.reply_target(episode, turn))

    assert Custody.delivery_target(episode, turn) == %{
             "conversation_ref" => "slack:TROUTE:CDEVOPS",
             "thread_ref" => episode.destination_thread_ref,
             "transport" => "slack"
           }
  end

  test "an accepted answer keeps the target it was accepted with" do
    episode = admit!("delivery:accepted", channel_ref: "CDEVOPS")

    question =
      join!(episode,
        channel_ref: "CALERTS",
        text: "Can you confirm the failover finished?",
        thread_ref: "1789005000.000100"
      )

    turn =
      episode
      |> turn!([question])
      |> Ecto.Changeset.change(
        delivery_target: %{
          "conversation_ref" => "slack:TROUTE:CALERTS",
          "thread_ref" => "1789005000.000100",
          "transport" => "slack"
        }
      )
      |> Repo.update!()

    # A later input from somewhere else cannot move an answer that is already accepted.
    _later = join!(episode, channel_ref: "CENGINEERING", text: "Unrelated later note")

    assert Custody.delivery_target(episode, Repo.get!(Turn, turn.id)) == %{
             "conversation_ref" => "slack:TROUTE:CALERTS",
             "thread_ref" => "1789005000.000100",
             "transport" => "slack"
           }
  end

  defp admit!(key, options) do
    input = slack_input!(options)
    id = Ecto.UUID.generate()

    {:ok, transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(input),
        destination: input.destination,
        episode_id: id,
        episode_key: "#{key}:#{id}",
        linked_episode_id: nil,
        native_input_id: input.native_input_id,
        occurred_at: input.occurred_at,
        payload: Input.document(input),
        revision: 1,
        turn_ref: "turn:#{id}"
      })

    transition.episode
  end

  defp join!(%Episode{} = episode, options) do
    input = slack_input!(options)
    occurred_at = DateTime.add(@now, System.unique_integer([:positive, :monotonic]), :second)

    {:ok, transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(input),
        destination: %{
          conversation_ref: episode.destination_conversation_ref,
          thread_ref: episode.destination_thread_ref,
          transport: episode.destination_transport
        },
        episode_id: episode.id,
        episode_key: episode.key,
        linked_episode_id: nil,
        native_input_id: input.native_input_id,
        occurred_at: occurred_at,
        payload: Input.document(input),
        revision: 1,
        turn_ref: "turn:#{episode.id}"
      })

    Command.dedupe_key(%Command.AdmitInput{
      actor_ref: Input.actor_ref(input),
      destination: %{
        conversation_ref: episode.destination_conversation_ref,
        thread_ref: episode.destination_thread_ref,
        transport: episode.destination_transport
      },
      episode_id: transition.episode.id,
      episode_key: episode.key,
      linked_episode_id: nil,
      native_input_id: input.native_input_id,
      occurred_at: occurred_at,
      payload: Input.document(input),
      revision: 1,
      turn_ref: "turn:#{episode.id}"
    })
  end

  defp turn!(episode, selected_input_refs) do
    session =
      Repo.insert!(%Session{
        id: Ecto.UUID.generate(),
        episode_id: episode.id,
        execution_kind: :work,
        policy: "engineering",
        policy_digest: String.duplicate("a", 64),
        external_ref: "episode:#{episode.id}:session:#{System.unique_integer([:positive])}",
        generation: 1,
        create_generation: 1
      })

    Repo.insert!(%Turn{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      session_id: session.id,
      turn_ref: "work-turn:#{System.unique_integer([:positive])}",
      status: :pending,
      selected_input_refs: if(selected_input_refs == [], do: nil, else: selected_input_refs)
    })
  end

  defp slack_input!(options) do
    ts =
      Keyword.get(options, :thread_ref) ||
        "#{1_789_000_000 + System.unique_integer([:positive])}.000100"

    {:ok, input} =
      SlackInput.new(%{
        actor: Keyword.get(options, :actor, %{kind: :user, ref: "UALICE"}),
        channel_ref: Keyword.fetch!(options, :channel_ref),
        content: %{"text" => Keyword.get(options, :text, "Database is unavailable")},
        event_kind: :message,
        event_ref: "Ev-#{ts}-#{System.unique_integer([:positive])}",
        message_ref: "#{1_789_000_000 + System.unique_integer([:positive])}.000200",
        occurred_at: @now,
        revision: 1,
        thread_ref: Keyword.get(options, :thread_ref),
        workspace_ref: "TROUTE"
      })

    input
  end
end
