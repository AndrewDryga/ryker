defmodule Ryker.Delivery.PlatformActionCustodyTest do
  use Ryker.DataCase, async: true

  alias Ryker.Delivery.{PlatformActionCustody, Request}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.{Custody, DeliveryReceipt, Validator}

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

    [input_ref] = claim.episode.active_input_refs

    assert %{
             ^action_ref => %{
               "action" => "add",
               "action_kind" => "reaction",
               "continuation" => nil,
               "current_human_inputs" => [
                 %{
                   "input_ref" => ^input_ref,
                   "source_item_ref" => "1787832000.000100"
                 }
               ],
               "kind" => "platform_action",
               "source_item_ref" => "1787832000.000100",
               "status" => "delivered",
               "tool" => "set_slack_reaction"
             }
           } = PlatformActionCustody.validation_records(claim.episode.id)
  end

  test "validation records retain every active human input when one reaction cannot cover all" do
    claim = claim_with_two_human_inputs!()

    assert {:ok, %{action: action}} =
             PlatformActionCustody.enqueue(claim, reaction_attributes())

    [first_input_ref, second_input_ref] = claim.episode.active_input_refs

    assert %{
             "current_human_inputs" => [
               %{
                 "input_ref" => ^first_input_ref,
                 "source_item_ref" => "1787832000.000100"
               },
               %{"input_ref" => ^second_input_ref, "source_item_ref" => "1787832000.000200"}
             ]
           } = PlatformActionCustody.validation_records(claim.episode.id)[action.action_ref]
  end

  test "model action history contains only typed identity and status rather than retained payload" do
    # Derived-context review checked this sibling read path: adding request or
    # response text here would need the same producer-source custody as records.
    claim = claim!()
    assert {:ok, %{action: action}} = PlatformActionCustody.enqueue(claim, reaction_attributes())

    assert PlatformActionCustody.model_actions(claim.episode.id) == [
             %{
               "action_ref" => action.action_ref,
               "kind" => "reaction",
               "status" => "pending",
               "tool" => "set_slack_reaction"
             }
           ]
  end

  test "a delivered reaction removal cannot replace the reply to a current human input" do
    # The cost of accepting this is a human request ending with neither a reply nor even the
    # reaction that the final claims answered it, despite every host operation succeeding.
    claim = claim!()
    attributes = put_in(reaction_attributes(), [:document, "action"], "remove")
    assert {:ok, %{action: action}} = PlatformActionCustody.enqueue(claim, attributes)

    assert {:ok, %{action: claimed, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert claimed.id == action.id

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               action.action_ref,
               "slack",
               "slack:T123:C123",
               "1787832000.000100",
               "1787832000.000100"
             )

    assert {:ok, delivered} =
             PlatformActionCustody.confirm_delivery(action.action_ref, lease_ref, receipt)

    assert delivered.status == :delivered

    records = PlatformActionCustody.validation_records(claim.episode.id, claim.turn.id)

    candidate =
      Jason.encode!(%{
        "decision_reason" => "The delivered reaction fully acknowledges this social message.",
        "delivery" => "none",
        "message" => nil,
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => [action.action_ref],
          "state" => "complete"
        }
      })

    assert {:reject, violations} =
             Validator.validate(candidate, validation_context(records), @now)

    assert Enum.any?(violations, &String.contains?(&1, "Reaction removals"))
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
    assert {:ok, transition} = Episodes.apply(input(episode_id))
    pin_and_claim!(transition.episode)
  end

  defp claim_with_two_human_inputs! do
    episode_id = Ecto.UUID.generate()
    assert {:ok, first} = Episodes.apply(input(episode_id))

    assert {:ok, second} =
             Episodes.apply(
               input(episode_id,
                 actor_ref: "slack:user:U2",
                 native_input_id: "platform-action:input:second:#{episode_id}",
                 occurred_at: DateTime.add(@now, 1, :second),
                 payload: %{"source_item_ref" => "1787832000.000200"}
               )
             )

    [second_input_ref] = second.episode.queued_input_refs

    assert {:ok, transferred} =
             Episodes.apply(
               EpisodeFixtures.transfer_owner(%{
                 episode_key: first.episode.key,
                 expected_owner: %{kind: :turn, ref: first.episode.owner_ref},
                 new_owner: %{kind: :turn, ref: "platform-action:replacement:#{episode_id}"},
                 occurred_at: DateTime.add(@now, 2, :second),
                 required_input_ref: second_input_ref,
                 transfer_ref: "platform-action:transfer:#{episode_id}"
               })
             )

    pin_and_claim!(transferred.episode)
  end

  defp input(episode_id, overrides \\ []) do
    overrides = Map.new(overrides)

    EpisodeFixtures.admit_input(
      Map.merge(
        %{
          destination: %{
            conversation_ref: "slack:T123:C123",
            thread_ref: "1787832000.000100",
            transport: "slack"
          },
          episode_id: episode_id,
          episode_key: "platform-action:#{episode_id}",
          native_input_id: "platform-action:input:#{episode_id}",
          occurred_at: @now,
          payload: %{"source_item_ref" => "1787832000.000100"},
          turn_ref: "platform-action:turn:#{episode_id}"
        },
        overrides
      )
    )
  end

  defp pin_and_claim!(episode) do
    assert {:ok, _session} =
             Custody.pin_episode(episode.id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("platform-action-work", 60)
    assert claim.episode.id == episode.id
    claim
  end

  defp validation_context(records) do
    %{
      "artifact_delivery_supported" => true,
      "artifact_metadata" => [],
      "artifact_refs" => [],
      "execution_mode" => "live",
      "open_required_goals" => [],
      "records" => records,
      "slack_mentions" => nil,
      "visible_reply_required" => true,
      "workspace" => nil
    }
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
