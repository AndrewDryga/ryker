defmodule Responder.Delivery.PlatformActionCustodyTest do
  use Responder.DataCase, async: true

  alias Responder.Delivery.{PlatformActionCustody, Request}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Work.{Custody, DeliveryReceipt}

  @now ~U[2026-08-29 12:00:00.000000Z]

  test "one live Work turn freezes an exact platform action and exact retries reuse it" do
    claim = claim!()
    attributes = reaction_attributes()

    assert {:ok, %{action: first, status: :created}} =
             PlatformActionCustody.enqueue(claim, attributes)

    assert {:ok, %{action: duplicate, status: :duplicate}} =
             PlatformActionCustody.enqueue(claim, attributes)

    assert duplicate.id == first.id

    assert PlatformActionCustody.enqueue(
             claim,
             put_in(attributes, [:document, "emoji_name"], "heart")
           ) == {:error, :platform_action_slot_conflict}

    assert {:ok, %{action: claimed, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert {:ok,
            %Request{
              document: %{"action" => "add", "emoji_name" => "eyes"},
              ref: action_ref,
              source_item_ref: "1787832000.000100"
            }} = PlatformActionCustody.request(claimed)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               action_ref,
               "slack",
               "slack:T123:C123",
               "1787832000.000100",
               "1787832000.000100"
             )

    assert {:ok, delivered} =
             PlatformActionCustody.confirm_delivery(action_ref, lease_ref, receipt)

    assert delivered.status == :delivered
    assert delivered.external_receipt == receipt
    assert {:ok, same} = PlatformActionCustody.confirm_delivery(action_ref, lease_ref, receipt)
    assert same.id == delivered.id

    assert %{
             ^action_ref => %{
               "action_kind" => "reaction",
               "continuation" => nil,
               "kind" => "platform_action",
               "status" => "delivered",
               "tool" => "set_slack_reaction"
             }
           } = PlatformActionCustody.validation_records(claim.episode.id)
  end

  test "shadow work cannot create a platform side effect" do
    claim = claim!()

    Repo.query!(
      "UPDATE episode_kernel_episodes SET execution_mode = 'shadow' WHERE id = $1",
      [Ecto.UUID.dump!(claim.episode.id)]
    )

    assert PlatformActionCustody.enqueue(claim, reaction_attributes()) ==
             {:error, :platform_action_not_authorized}
  end

  test "an expired Work binding cannot create a platform side effect" do
    claim = claim!()

    Repo.query!(
      "UPDATE episode_work_turns SET lease_expires_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [
        Ecto.UUID.dump!(claim.turn.id)
      ]
    )

    assert PlatformActionCustody.enqueue(claim, reaction_attributes()) ==
             {:error, :platform_action_not_authorized}
  end

  defp claim! do
    episode_id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: "slack:T123:C123",
          thread_ref: "1787832000.000100",
          transport: "slack"
        },
        episode_id: episode_id,
        episode_key: "platform-action:#{episode_id}",
        native_input_id: "platform-action:input:#{episode_id}",
        occurred_at: @now,
        turn_ref: "platform-action:turn:#{episode_id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("platform-action-work", 60)
    claim
  end

  defp reaction_attributes do
    %{
      conversation_ref: "slack:T123:C123",
      document: %{"action" => "add", "emoji_name" => "eyes"},
      host_slot: "reaction",
      kind: :reaction,
      source_item_ref: "1787832000.000100",
      thread_ref: "1787832000.000100",
      tool: :set_slack_reaction,
      transport: "slack"
    }
  end
end
