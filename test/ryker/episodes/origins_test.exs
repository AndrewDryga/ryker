defmodule Ryker.Episodes.OriginsTest do
  use Ryker.DataCase, async: true

  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Origins}
  alias Ryker.Ingress.Input
  alias Ryker.Slack.Input, as: SlackInput

  @now ~U[2026-09-11 08:00:00.000000Z]

  test "an input keeps its own origin and reply target when it joins work whose home is elsewhere" do
    # Cross-conversation joins were impossible before this projection existed:
    # the kernel kept one destination per episode, so a message admitted into
    # work that started in another channel lost the thread its answer belongs to.
    root = slack_input!(channel_ref: "CDEVOPS", message_ref: "1787832000.000100")
    {:ok, home} = Episodes.apply(admit(root, episode_key: "routing:home"))

    reply =
      slack_input!(
        actor: %{kind: :user, ref: "UALICE"},
        channel_ref: "CALERTS",
        message_ref: "1787832010.000200",
        thread_ref: "1787832005.000100",
        occurred_at: DateTime.add(@now, 10, :second)
      )

    {:ok, _joined} =
      Episodes.apply(
        admit(reply, episode_key: "routing:home", destination: home.episode |> home_destination())
      )

    assert {:ok, episode} = Episodes.fetch_by_key("routing:home")
    assert episode.destination_conversation_ref == "slack:TROUTE:CDEVOPS"
    assert episode.destination_thread_ref == "1787832000.000100"

    assert [first, second] = Origins.for_episode(episode.id)

    assert %{
             conversation_ref: "slack:TROUTE:CDEVOPS",
             thread_ref: "1787832000.000100",
             origin_kind: :channel_root,
             root_ref: "1787832000.000100",
             actor_ref: "slack:app:A123",
             effective: true
           } = first

    assert %{
             conversation_ref: "slack:TROUTE:CALERTS",
             thread_ref: "1787832005.000100",
             origin_kind: :thread_reply,
             root_ref: "1787832005.000100",
             source_item_ref: "1787832010.000200",
             actor_ref: "slack:user:UALICE",
             effective: true
           } = second

    assert Origins.reply_target(second) == %{
             conversation_ref: "slack:TROUTE:CALERTS",
             thread_ref: "1787832005.000100",
             transport: "slack"
           }

    assert Origins.home(episode) == %{
             conversation_ref: "slack:TROUTE:CDEVOPS",
             thread_ref: "1787832000.000100",
             transport: "slack"
           }

    assert Origins.participating_conversations(episode.id) == [
             "slack:TROUTE:CALERTS",
             "slack:TROUTE:CDEVOPS"
           ]
  end

  test "a retried admission does not duplicate the origin row" do
    input = slack_input!(channel_ref: "CDEVOPS", message_ref: "1787832000.000100")
    command = admit(input, episode_key: "routing:retry")
    assert {:ok, %{status: :applied}} = Episodes.apply(command)
    assert {:ok, %{status: :duplicate}} = Episodes.apply(command)
    assert {:ok, episode} = Episodes.fetch_by_key("routing:retry")
    assert [_origin] = Origins.for_episode(episode.id)
  end

  test "non-threaded transports and custom payloads record a conversation origin without inventing a root" do
    {:ok, transition} =
      Episodes.apply(
        Ryker.Fixtures.Episodes.admit_input(%{
          destination: %{
            conversation_ref: "github:eval:repository:99",
            thread_ref: "github:eval:pull:42",
            transport: "github"
          },
          episode_key: "routing:github",
          payload: %{"task" => %{"repository" => "eval/app"}}
        })
      )

    assert [origin] = Origins.for_episode(transition.episode.id)
    assert origin.origin_kind == :conversation
    assert origin.root_ref == nil
    assert origin.conversation_ref == "github:eval:repository:99"
    assert origin.thread_ref == "github:eval:pull:42"
    assert origin.source_item_ref == nil
  end

  test "a Slack root and a thread reply are told apart from the retained identities alone" do
    root = slack_input!(channel_ref: "CDEVOPS", message_ref: "1787832000.000100")

    reply =
      slack_input!(
        channel_ref: "CDEVOPS",
        message_ref: "1787832001.000100",
        thread_ref: "1787832000.000100"
      )

    assert Origins.from_input_document(Input.document(root)).origin_kind == :channel_root
    assert Origins.from_input_document(Input.document(reply)).origin_kind == :thread_reply
    assert Origins.from_input_document(Input.document(reply)).root_ref == "1787832000.000100"
  end

  defp home_destination(episode) do
    %{
      conversation_ref: episode.destination_conversation_ref,
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }
  end

  defp admit(input, options) do
    %Command.AdmitInput{
      actor_ref: Input.actor_ref(input),
      destination: Keyword.get(options, :destination, input.destination),
      episode_id: Keyword.get(options, :episode_id, Ecto.UUID.generate()),
      episode_key: Keyword.fetch!(options, :episode_key),
      linked_episode_id: nil,
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      payload: Input.document(input),
      revision: input.revision,
      turn_ref: "turn:#{input.native_input_id}"
    }
  end

  defp slack_input!(overrides) do
    message_ref = Keyword.fetch!(overrides, :message_ref)

    {:ok, input} =
      SlackInput.new(%{
        actor: Keyword.get(overrides, :actor, %{kind: :app, ref: "A123"}),
        channel_ref: Keyword.fetch!(overrides, :channel_ref),
        content: Keyword.get(overrides, :content, %{"text" => "Database is unavailable"}),
        event_kind: :message,
        event_ref: "Ev-#{message_ref}",
        message_ref: message_ref,
        occurred_at: Keyword.get(overrides, :occurred_at, @now),
        revision: 1,
        thread_ref: Keyword.get(overrides, :thread_ref),
        workspace_ref: "TROUTE"
      })

    input
  end
end
