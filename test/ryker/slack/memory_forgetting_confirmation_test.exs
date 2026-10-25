defmodule Ryker.Slack.MemoryForgettingConfirmationTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.MemoryConfirmations
  alias Ryker.Memories
  alias Ryker.Records.Record
  alias Ryker.Slack.{AppHome, AppHomeActions, AppHomeControls, AppHomeProjection, HomeEvent}
  alias Ryker.Slack.{HomeInteraction, Interaction, InteractionHandler}
  alias Ryker.Slack.{Operators, Renderer, ReplyRecords, SavedEntity}

  defmodule Directory do
    def user_allowed(_client, "U123", _workspace), do: {:ok, true}
  end

  defmodule ViewCapture do
    def publish_home(observer, _actor, view) do
      send(observer, {:memory_home_view, view})
      :ok
    end
  end

  # Native confirmations remained attached to a reusable memory ref. A review
  # edit let either retained Slack surface erase the replacement words.
  for surface <- [:message, :home], field <- ["subject", "value"] do
    test "a retained #{surface} control cannot erase a newer #{field}" do
      context = MemoryConfirmations.current!()
      control = control(context, unquote(surface))
      replacement = Map.put(context.original, unquote(field), context.replacement[unquote(field)])
      MemoryConfirmations.edit!(context, replacement)
      result = click(context, control, unquote(surface))
      memory = MemoryConfirmations.fetch!(context)

      assert memory.status == :active
      assert memory.subject == replacement["subject"]
      assert memory.payload["value"] == replacement["value"]
      assert {:ok, %{outcome: :invalid}} = result
    end
  end

  for surface <- [:message, :home] do
    test "a recognized #{surface} Forget with unbound content is refused without erasing memory" do
      context = MemoryConfirmations.current!()
      original_control = control(context, unquote(surface))

      for value <- [context.memory.ref, "wrong-kind:one", "memory-control:memory:one:invalid"] do
        control = Map.put(original_control, "value", value)
        result = click(context, control, unquote(surface))

        assert MemoryConfirmations.fetch!(context).status == :active
        assert {:ok, %{outcome: :invalid}} = result
        if unquote(surface) == :home, do: assert_received(:memory_home_refreshed)
      end
    end

    test "an unchanged #{surface} control forgets once and safely acknowledges a retry" do
      context = MemoryConfirmations.current!()
      control = control(context, unquote(surface))
      result = click(context, control, unquote(surface))
      memory = MemoryConfirmations.fetch!(context)

      assert memory.status == :deleted
      assert memory.payload == %{"forgotten_payload_sha256" => context.memory.payload_fingerprint}
      assert {:ok, %{outcome: :forgotten}} = result
      assert {:ok, %{outcome: :forgotten}} = click(context, control, unquote(surface))
      assert MemoryConfirmations.fetch!(context) == memory
    end
  end

  test "repainting an earlier saved offer uses current content and preserves its historical payload" do
    context = MemoryConfirmations.current!()
    record = Repo.get!(Record, context.memory.offer_record_id)

    confirmation = %{
      status: :confirmed,
      confirmed_at: context.memory.confirmed_at,
      confirmed_by_actor_ref: context.memory.confirmed_by_actor_ref,
      confirmation_ref: context.memory.confirmation_ref
    }

    record = record |> Record.Changeset.confirm_resource(confirmation) |> Repo.update!()
    before_edit = offer_control(context, record)
    MemoryConfirmations.edit!(context, context.replacement)
    after_edit = offer_control(context, record)

    refute before_edit["value"] == after_edit["value"]
    assert after_edit["confirm"]["text"]["text"] =~ context.replacement["subject"]
    assert Repo.get!(Record, record.id).payload == record.payload
    assert {:ok, %{outcome: :forgotten}} = click(context, after_edit, :message)
    assert MemoryConfirmations.fetch!(context).status == :deleted
  end

  defp offer_control(context, record) do
    documents = ReplyRecords.documents("slack", context.source.episode.id, [record])
    document = %{"message" => context.original["value"], "records" => documents}
    assert {:ok, message} = Renderer.render(document)
    find_control!(message, "ryker_forget_memory")
  end

  defp control(context, :message) do
    document = SavedEntity.document(context.memory, :saved)
    assert {:ok, message} = Renderer.render(%{"saved_entity" => document})
    find_control!(message, "ryker_forget_memory")
  end

  defp control(context, :home) do
    workspace = workspace(context)
    event = %HomeEvent{actor_ref: "U123", event_ref: "home:memory", workspace_ref: workspace}

    assert {:ok, %{outcome: :published}} =
             AppHome.handle(event, %{
               api: ViewCapture,
               client: self(),
               directory: Directory,
               operators: Operators.new(["U123"], false, workspace),
               projection: &AppHomeProjection.snapshot/3,
               shared_conversations: fn _client, _actor, _workspace ->
                 {:ok, MapSet.new(["C1"])}
               end
             })

    assert_received {:memory_home_view, view}
    find_control!(view, "ryker_home_forget_memory")
  end

  defp click(context, control, :message) do
    workspace = workspace(context)

    envelope =
      envelope(workspace, control, %{
        "channel_id" => "C1",
        "is_ephemeral" => false,
        "message_ts" => "1787832001.000200",
        "thread_ts" => "1.000001",
        "type" => "message"
      })

    assert {:ok, interaction} = Interaction.from_socket(envelope, workspace, Repo.now!())

    InteractionHandler.handle(interaction, %{
      client: self(),
      directory: Directory,
      operators: Operators.new(["U123"], false, workspace),
      forget_memory: fn ref, fingerprint, actor, conversation ->
        Memories.forget_in_conversation(
          ref,
          fingerprint,
          "slack:user:" <> actor,
          context.workspace_ref,
          conversation
        )
      end
    })
  end

  defp click(context, control, :home) do
    workspace = workspace(context)

    envelope =
      envelope(workspace, control, %{"type" => "view", "view_id" => "V123"})
      |> put_in(["payload", "view"], %{"id" => "V123", "type" => "home"})

    assert {:ok, interaction} = HomeInteraction.from_socket(envelope, workspace, Repo.now!())

    AppHomeControls.handle(interaction, %{
      authorize_resource: &AppHomeActions.authorize_resource(&1, Directory, self()),
      client: self(),
      directory: Directory,
      operators: Operators.new(["U123"], false, workspace),
      refresh_home: fn _event ->
        send(self(), :memory_home_refreshed)
        {:ok, %{outcome: :published}}
      end,
      forget_memory: fn ref, fingerprint, actor, _workspace ->
        Memories.forget_home(ref, fingerprint, "slack:user:" <> actor, context.workspace_ref)
      end
    })
  end

  defp envelope(workspace, control, container) do
    %{
      "envelope_id" => "memory-confirmation",
      "type" => "interactive",
      "payload" => %{
        "actions" => [Map.take(control, ~w(action_id type value))],
        "container" => container,
        "team" => %{"id" => workspace},
        "type" => "block_actions",
        "user" => %{"id" => "U123"}
      }
    }
  end

  defp find_control!(document, prefix) do
    controls = for block <- document["blocks"], element <- block["elements"] || [], do: element

    control =
      Enum.find(controls, fn control ->
        action = control["action_id"] || ""
        action == prefix or String.starts_with?(action, prefix <> "__i")
      end)

    assert %{"type" => "button"} = control
    control
  end

  defp workspace(context), do: String.replace_prefix(context.workspace_ref, "slack:", "")
end
