defmodule Responder.ControlPlane.CardLabDeliveryTest do
  use Responder.DataCase, async: true

  alias Responder.ControlPlane.CardLab

  alias Responder.ControlPlane.{CardLabDelivery, CardLabPost}
  alias Responder.Slack.ChannelMembership

  defmodule FakeSlack do
    def find_card_specimen(agent, channel, ref, since) do
      Agent.update(agent, &Map.put(&1, :reconcile_since, since))
      delay = Agent.get(agent, &Map.get(&1, :delay, 0))
      if delay > 0, do: Process.sleep(delay)
      find_message(agent, channel, nil, ref)
    end

    def list_conversations(_agent, _document) do
      {:ok,
       %{
         "conversations" => [%{"channel_ref" => "C123", "name" => "responder-testing"}],
         "cursor" => nil
       }}
    end

    def conversation_info(agent, channel) do
      Agent.get(agent, fn state ->
        {:ok,
         %{
           "id" => channel,
           "name" => "responder-testing",
           "is_member" => true,
           "is_archived" => false,
           "is_ext_shared" => state.external_shared
         }}
      end)
    end

    def find_message(agent, _channel, _thread, ref) do
      Agent.get(agent, fn state ->
        case Map.get(state.messages, ref) do
          nil -> :not_found
          message -> {:ok, message}
        end
      end)
    end

    def post_card_specimen(agent, channel, thread, payload, ref) do
      Agent.get_and_update(agent, fn state ->
        reply = if state.lose_response, do: {:error, :timeout}, else: {:ok, "1788562304.000100"}

        {reply,
         %{
           state
           | posts: [{channel, thread, payload, ref} | state.posts],
             messages: Map.put(state.messages, ref, "1788562304.000100")
         }}
      end)
    end

    def update_card_specimen(agent, channel, message, payload, ref) do
      Agent.update(agent, &%{&1 | updates: [{channel, message, payload, ref} | &1.updates]})
    end
  end

  setup do
    now = DateTime.utc_now()

    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: "T123",
      channel_ref: "C123",
      status: :joined,
      generation: 1,
      private: false,
      external_shared: false,
      joined_at: now
    })

    {:ok, client} =
      Agent.start_link(fn ->
        %{messages: %{}, posts: [], updates: [], lose_response: false, external_shared: false}
      end)

    %{options: %{api: FakeSlack, client: client, workspace_ref: "T123"}, client: client}
  end

  test "explicit posting survives retries and transitions update the same Slack message",
       context do
    id = Ecto.UUID.generate()
    assert {:ok, post} = enqueue(id, context.options)
    assert post.status == :pending
    assert {:ok, duplicate} = enqueue(id, context.options)
    assert duplicate.id == post.id
    assert {:ok, delivered} = CardLabDelivery.run_once(context.options)
    assert delivered.status == :posted
    assert delivered.message_ref == "1788562304.000100"
    assert Agent.get(context.client, &Map.get(&1, :reconcile_since)) == post.inserted_at

    assert {:ok, updated} = CardLabDelivery.transition(post.id, "resolved", 1, context.options)
    assert updated.revision == 2
    assert {:ok, finished} = CardLabDelivery.run_once(context.options)
    assert finished.delivered_state_id == "resolved"
    assert {:ok, nil} = CardLabDelivery.run_once(context.options)

    assert %{posts: [_one], updates: [{"C123", "1788562304.000100", payload, _}]} =
             Agent.get(context.client, & &1)

    assert payload["text"] =~ "Resolved"
  end

  test "a channel name is resolved to an eligible immutable destination before confirmation",
       context do
    assert {:ok, target} =
             CardLabDelivery.describe_target("T123", "#responder-testing", context.options)

    assert target.channel_ref == "C123"
    assert target.channel_name == "responder-testing"

    assert {:error, _} =
             CardLabDelivery.describe_target("T123", "#not-a-channel", context.options)

    assert {:error, _} =
             CardLabDelivery.describe_target("T999", "#responder-testing", context.options)

    assert Agent.get(context.client, & &1.posts) == []
  end

  test "a lost post response reconciles its durable identity before attempting another post",
       context do
    Agent.update(context.client, &%{&1 | lose_response: true})
    assert {:ok, post} = enqueue(Ecto.UUID.generate(), context.options)
    assert {:ok, failed} = CardLabDelivery.run_once(context.options)
    assert failed.status == :pending
    assert failed.last_error != nil
    assert {:ok, _} = CardLabDelivery.retry(post.id, post.revision, context.options)
    assert {:ok, recovered} = CardLabDelivery.run_once(context.options)
    assert recovered.status == :posted
    assert length(Agent.get(context.client, & &1.posts)) == 1
  end

  test "a workspace mismatch or externally shared destination cannot receive specimens",
       context do
    assert {:error, :card_lab_destination_not_allowed} =
             CardLabDelivery.enqueue(
               "incident-room",
               "provisioning",
               "T999",
               "C123",
               Ecto.UUID.generate(),
               context.options
             )

    Agent.update(context.client, &%{&1 | external_shared: true})

    assert {:error, :card_lab_destination_not_allowed} =
             enqueue(Ecto.UUID.generate(), context.options)

    assert Repo.aggregate(CardLabPost, :count) == 0
    assert Agent.get(context.client, & &1.posts) == []
  end

  test "a request identity cannot be rebound and a stale transition cannot overwrite newer state",
       context do
    id = Ecto.UUID.generate()
    assert {:ok, post} = enqueue(id, context.options)

    assert {:error, :card_lab_request_conflict} =
             CardLabDelivery.enqueue(
               "incident-room",
               "resolved",
               "T123",
               "C123",
               id,
               context.options
             )

    assert {:ok, _} = CardLabDelivery.run_once(context.options)
    assert {:ok, _} = CardLabDelivery.transition(post.id, "resolved", 1, context.options)

    assert {:error, :card_lab_stale_revision} =
             CardLabDelivery.transition(post.id, "cancelled", 1, context.options)

    assert {:error, :card_lab_stale_revision} = CardLabDelivery.retry(post.id, 1, context.options)
  end

  test "App Home and modal payloads cannot be posted as chat messages", context do
    [card | _] = Enum.filter(CardLab.catalog(), &(&1.surface == :app_home))

    assert {:error, :card_lab_requires_native_surface} =
             CardLabDelivery.enqueue(
               card.id,
               hd(card.states).id,
               "T123",
               "C123",
               Ecto.UUID.generate(),
               context.options
             )

    assert Agent.get(context.client, & &1.posts) == []
  end

  test "an active delivery lease excludes retries and state changes without remote effects",
       context do
    {:ok, post} = enqueue(Ecto.UUID.generate(), context.options)

    post
    |> Ecto.Changeset.change(
      lease_ref: Ecto.UUID.generate(),
      lease_expires_at: DateTime.add(DateTime.utc_now(), 60)
    )
    |> Repo.update!()

    assert {:error, :card_lab_delivery_busy} =
             CardLabDelivery.transition(post.id, "resolved", 1, context.options)

    assert {:error, :card_lab_delivery_busy} =
             CardLabDelivery.retry(post.id, 1, context.options)

    assert {:ok, nil} = CardLabDelivery.run_once(context.options)
    assert Repo.get!(CardLabPost, post.id).state_id == "provisioning"
    assert Agent.get(context.client, & &1.posts) == []

    assert {:error, :card_lab_post_not_found} =
             CardLabDelivery.retry(Ecto.UUID.generate(), 1, context.options)
  end

  test "an expired eighth claim is stopped before it can monopolize the delivery worker",
       context do
    # Expired reconciliation leases previously bypassed the retry ceiling forever.
    {:ok, post} = enqueue(Ecto.UUID.generate(), context.options)

    post
    |> Ecto.Changeset.change(
      attempt_count: 8,
      lease_ref: Ecto.UUID.generate(),
      lease_expires_at: DateTime.add(DateTime.utc_now(), -1)
    )
    |> Repo.update!()

    assert {:ok, stopped} = CardLabDelivery.run_once(context.options)
    assert stopped.status == :blocked
    assert Agent.get(context.client, & &1.posts) == []
    assert {:ok, nil} = CardLabDelivery.run_once(context.options)
  end

  test "a slow delivery is interrupted within custody and retains a reconcilable request",
       context do
    {:ok, post} = enqueue(Ecto.UUID.generate(), context.options)
    Agent.update(context.client, &Map.put(&1, :delay, 200))

    assert {:ok, pending} =
             CardLabDelivery.run_once(Map.put(context.options, :delivery_timeout_ms, 30))

    assert pending.id == post.id
    assert pending.status == :pending
    assert pending.last_error != nil
    assert pending.lease_ref == nil
    assert Agent.get(context.client, & &1.posts) == []
  end

  defp enqueue(id, options),
    do: CardLabDelivery.enqueue("incident-room", "provisioning", "T123", "C123", id, options)
end
