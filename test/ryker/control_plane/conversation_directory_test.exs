defmodule Ryker.ControlPlane.ConversationDirectoryTest do
  @moduledoc """
  The Chat list's conversations, each with what it needs from the reader:
  something stopped, Ryker is at it, it waits for them or for an event, or
  it replied.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.ConversationProjection
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input
  alias Ryker.QueryWork
  alias Ryker.Work.{Session, Turn}

  test "each conversation says what it needs from the reader" do
    working = conversation()
    message!(working)

    stopped = conversation()
    stopped |> message!() |> stop!()

    {asking, episode} = with_episode!()
    wait!(episode, :input)

    {waiting, episode} = with_episode!()
    wait!(episode, :event, DateTime.add(DateTime.utc_now(), 3_600, :second))

    {stuck, episode} = with_episode!()
    blocked_turn!(episode)

    {at_it, _episode} = with_episode!()

    replied = conversation()
    replied |> message!() |> quick_reply!()

    states = Map.new(ConversationProjection.index(), &{&1.ref, &1.status})

    assert Map.take(states, [working, stopped, asking, waiting, stuck, at_it, replied]) == %{
             working => :working,
             stopped => :attention,
             asking => :waiting_for_you,
             waiting => :waiting,
             stuck => :attention,
             at_it => :working,
             replied => :replied
           }
  end

  # Each conversation's state was worked out from every message row of every
  # conversation listed, all read into the console to find one word each
  # (2026-10-04 review). The database answers one row a conversation.
  test "the list reads one state row a conversation, not every message" do
    for _conversation <- 1..2 do
      ref = conversation()
      for _message <- 1..12, do: message!(ref)
    end

    {[_, _], statements} = QueryWork.statements(&ConversationProjection.index/0)
    assert QueryWork.rows_returned(statements, "ingress_inbox_entries") <= 2 * 4
  end

  defp conversation, do: "control-plane:lab:" <> Ecto.UUID.generate()

  # A message sent in Chat, as ConversationLab records one.
  defp message!(conversation) do
    id = Ecto.UUID.generate()

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "local-operator"},
        content: %{"text" => "Is checkout healthy?"},
        destination: %{
          transport: "control_plane",
          conversation_ref: conversation,
          thread_ref: conversation
        },
        event_kind: :message,
        event_ref: "control-plane-event:" <> Ecto.UUID.generate(),
        native_input_id: "control-plane-message:" <> id,
        occurred_at: DateTime.utc_now(),
        occurred_at_source: :ingress,
        revision: 1,
        source: %{kind: "control_plane", ref: "local"},
        source_capabilities: %{
          "post_slack_message" => %{"destination_refs" => [conversation]},
          "react" => %{"emoji_names" => nil}
        },
        source_item_ref: "control-plane-item:" <> id
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  # Routing stopped on it and said why.
  defp stop!(entry) do
    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [status: :blocked, last_error_code: "admission_failed", last_error_detail: "Refused."]
    )
  end

  # Routing answered it in a line, without starting work.
  defp quick_reply!(entry) do
    decide!(entry, %{"action" => "quick_reply", "reason" => "Directory fixture."}, nil)
  end

  # A conversation whose message started work.
  defp with_episode! do
    ref = conversation()
    id = Ecto.UUID.generate()

    assert {:ok, %{episode: episode}} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "directory:" <> id,
                 native_input_id: "source:directory:" <> id,
                 turn_ref: "turn:directory:" <> id
               })
             )

    decide!(
      message!(ref),
      %{"action" => "continue_episode", "reason" => "Directory fixture."},
      episode.id
    )

    {ref, episode}
  end

  defp decide!(entry, decision, episode_id) do
    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: String.to_existing_atom(decision["action"]),
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "decision:#{entry.id}",
        episode_id: episode_id,
        status: :decided
      ]
    )
  end

  defp wait!(episode, kind, deadline \\ nil) do
    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 deadline_at: deadline,
                 episode_key: episode.key,
                 expected_turn_ref: episode.owner_ref,
                 kind: kind
               })
             )
  end

  defp blocked_turn!(episode) do
    session =
      Repo.insert!(%Session{
        id: Ecto.UUID.generate(),
        episode_id: episode.id,
        execution_kind: :work,
        policy: "engineering",
        policy_digest: String.duplicate("a", 64),
        external_ref: "episode:#{episode.id}:session:1",
        generation: 1,
        create_generation: 1
      })

    Repo.insert!(%Turn{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      session_id: session.id,
      turn_ref: "work-turn:" <> Ecto.UUID.generate(),
      status: :blocked
    })
  end
end
